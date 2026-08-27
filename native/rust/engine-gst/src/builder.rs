// Unified pipeline builder — C create_pipeline parity.
//
// Single source  : source → tee → {per-sink branches} + thumbnail branch
// Dual-ingest    : source + secondary_source → input-selector → tee → ...
// SDI sinks      : full decode → convert/rate/scale → caps → identity(sync) → decklink
// Metadata probe : tee sink pad (engine-metadata) → meta_* stdout + shared VideoInfo

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use std::str::FromStr;

use gio;
use gst::glib;
use gst::prelude::*;
use gstreamer as gst;

use engine_config::{PropValue, RouteConfig, SinkConfig, SinkProtocol, SourceConfig};
use engine_metadata::TsProbeState;
use engine_stats::{SdiState, SharedSocket, SharedVideoInfo};
use engine_thumbnail::ThumbnailBranch;

pub struct BuiltPipeline {
    pub pipeline: gst::Pipeline,
    pub source: gst::Element,
    pub secondary: Option<gst::Element>,
    pub selector: Option<gst::Element>,
    pub tee: gst::Element,
    pub srt_sinks: Vec<gst::Element>,
    pub thumbnail: Option<ThumbnailBranch>,
    pub video_info: SharedVideoInfo,
    pub sdi_state: Arc<SdiState>,
    pub vrate_elements: Arc<Mutex<[Option<gst::Element>; 8]>>,
}

struct Ctx {
    socket: SharedSocket,
    sdi_state: Arc<SdiState>,
    video_info: SharedVideoInfo,
}

pub fn build_pipeline(config: &RouteConfig, socket: SharedSocket) -> Result<BuiltPipeline, String> {
    let ctx = Ctx {
        socket,
        sdi_state: SdiState::new_shared(),
        video_info: Arc::new(Mutex::new(None)),
    };

    let has_sdi = config.has_sdi_sink();

    let pipeline = gst::Pipeline::with_name("test-pipeline");
    let tee = gst::ElementFactory::make("tee")
        .name("tee")
        .property("allow-not-linked", true)
        .build()
        .map_err(|e| format!("Failed to create tee element: {}", e))?;
    println!("Set allow-not-linked=TRUE for tee element");

    let source = make_source(&config.source, "source", has_sdi, &ctx)?;

    let (selector, secondary) = match &config.secondary {
        Some(sec) => {
            let selector = gst::ElementFactory::make("input-selector")
                .name("input-selector")
                .build()
                .map_err(|e| format!("Failed to create input-selector: {}", e))?;
            let secondary = make_source(&sec.source, "secondary_source", has_sdi, &ctx)?;

            // C: sync-mode=1 (GstInputSelectorSyncMode "clock"), cache-buffers, drop-backwards
            selector.set_property_from_str("sync-mode", "clock");
            selector.set_property("cache-buffers", true);
            selector.set_property("drop-backwards", true);

            pipeline
                .add_many([&source, &secondary, &selector, &tee])
                .map_err(|e| format!("dual add: {}", e))?;

            let primary_pad = selector
                .request_pad_simple("sink_%u")
                .ok_or("Failed to request sink pads on input-selector")?;
            let secondary_pad = selector
                .request_pad_simple("sink_%u")
                .ok_or("Failed to request sink pads on input-selector")?;

            // MANDATORY: keeps the inactive srtsrc alive (else NOT_LINKED kills its task)
            primary_pad.set_property("always-ok", true);
            secondary_pad.set_property("always-ok", true);

            let p_src = source.static_pad("src").ok_or("source has no src pad")?;
            let s_src = secondary
                .static_pad("src")
                .ok_or("secondary has no src pad")?;
            p_src.link(&primary_pad).map_err(|_| {
                "DUAL-INGEST: failed to link primary source → selector sink_0".to_string()
            })?;
            s_src.link(&secondary_pad).map_err(|_| {
                "DUAL-INGEST: failed to link secondary source → selector sink_1".to_string()
            })?;

            gst::Element::link(&selector, &tee)
                .map_err(|_| "DUAL-INGEST: failed to link input-selector → tee".to_string())?;

            if let Some(active) = selector.static_pad("sink_0") {
                selector.set_property("active-pad", &active);
            }

            println!("DUAL-INGEST Pipeline: primary+secondary → input-selector → tee");
            (Some(selector), Some(secondary))
        }
        None => {
            pipeline
                .add_many([&source, &tee])
                .map_err(|e| format!("single add: {}", e))?;
            gst::Element::link(&source, &tee)
                .map_err(|_| "Elements could not be linked.".to_string())?;
            println!("ULTRA-SIMPLE Pipeline: source -> tee (no intermediate processing)");
            (None, None)
        }
    };

    install_ts_probe(&tee, &ctx);

    let mut srt_sinks = Vec::new();
    let vrate_elements: Arc<Mutex<[Option<gst::Element>; 8]>> =
        Arc::new(Mutex::new(Default::default()));

    for (idx, sink_cfg) in config.sinks.iter().enumerate() {
        match add_sink(&pipeline, &tee, sink_cfg, idx, &ctx, &vrate_elements) {
            Ok(Some(srt_sink)) => {
                println!(
                    "Stored SRT sink element at index {} for stats collection",
                    idx
                );
                srt_sinks.push(srt_sink);
            }
            Ok(None) => {}
            Err(err) => {
                if sink_cfg.protocol == SinkProtocol::Sdi {
                    eprintln!(
                        "WARNING: SDI sink {} failed — continuing without SDI output",
                        idx
                    );
                } else {
                    return Err(err);
                }
            }
        }
    }

    let thumbnail = if !config.route_id.is_empty() {
        match ThumbnailBranch::new(&pipeline, &tee, &config.route_id) {
            Ok(t) => {
                println!("Thumbnail: Branch ready for route {}", config.route_id);
                Some(t)
            }
            Err(e) => {
                eprintln!("Thumbnail: {}", e);
                None
            }
        }
    } else {
        None
    };

    // C: auto_join=false → hold secondary at NULL (primary still plays)
    if let Some(sec) = &secondary {
        if !config.auto_join {
            let _ = sec.set_state(gst::State::Null);
            println!("DUAL-INGEST: secondary held at NULL (auto_join=false)");
        }
    }

    Ok(BuiltPipeline {
        pipeline,
        source,
        secondary,
        selector,
        tee,
        srt_sinks,
        thumbnail,
        video_info: ctx.video_info,
        sdi_state: ctx.sdi_state,
        vrate_elements,
    })
}

// ── Sources ──────────────────────────────────────────────────────────────

fn make_source(
    cfg: &SourceConfig,
    name: &str,
    has_sdi_sink: bool,
    ctx: &Ctx,
) -> Result<gst::Element, String> {
    let src = gst::ElementFactory::make(&cfg.element_type)
        .name(name)
        .build()
        .map_err(|_| {
            format!(
                "Failed to create {} source element (type: {})",
                name, cfg.element_type
            )
        })?;
    println!(
        "Created source element: {} (type: {})",
        src.name(),
        src.type_().name()
    );

    apply_uri_and_props(&src, cfg)?;

    if has_sdi_sink {
        src.set_property("do-timestamp", true);
        println!(
            "Set do-timestamp=TRUE for {} source element (SDI playout detected)",
            name
        );
    } else {
        src.set_property("do-timestamp", false);
        println!(
            "Set do-timestamp=FALSE for {} source element (pure passthrough)",
            name
        );
    }

    if cfg.element_type == "srtsrc" {
        connect_caller_connecting(&src, name, ctx.socket.clone());
    }

    Ok(src)
}

fn apply_uri_and_props(el: &gst::Element, cfg: &SourceConfig) -> Result<(), String> {
    if let Some(uri) = source_uri(cfg) {
        if el.find_property("uri").is_some() {
            el.set_property("uri", uri);
        } else {
            return Err(format!("{} has no uri property", cfg.element_type));
        }
    }
    apply_extra_props(el, &cfg.extra_props);
    Ok(())
}

fn source_uri(cfg: &SourceConfig) -> Option<String> {
    match cfg.protocol {
        engine_config::SourceProtocol::Srt => {
            let mut uri = format!(
                "srt://{}:{}?mode={}&latency={}",
                cfg.host,
                cfg.port,
                cfg.mode.as_str(),
                cfg.latency_ms
            );
            if let Some(sid) = &cfg.streamid {
                uri.push_str(&format!("&streamid={}", sid));
            }
            if let Some(pw) = &cfg.passphrase {
                uri.push_str(&format!("&passphrase={}", pw));
            }
            Some(uri)
        }
        engine_config::SourceProtocol::Udp => Some(format!("udp://{}:{}", cfg.host, cfg.port)),
    }
}

/// C set_element_properties: apply every remaining JSON prop verbatim.
pub fn apply_extra_props(el: &gst::Element, props: &std::collections::BTreeMap<String, PropValue>) {
    for (name, value) in props {
        let Some(pspec) = el.find_property(name) else {
            eprintln!("Unknown property '{}' on {}", name, el.name());
            continue;
        };
        let ok = match value {
            PropValue::Bool(b) => {
                if pspec.type_() == bool::static_type() {
                    el.set_property(name, *b);
                    true
                } else {
                    el.set_property(name, *b as i32);
                    true
                }
            }
            PropValue::Int(i) => {
                set_numeric_property(el, name, *i, &pspec);
                true
            }
            PropValue::Double(d) => {
                el.set_property(name, *d);
                true
            }
            PropValue::Str(s) => {
                el.set_property(name, s.as_str());
                true
            }
        };
        if ok {
            println!("Set {}={:?} for {} element", name, value, el.name());
        }
    }
}

fn set_numeric_property(el: &gst::Element, name: &str, v: i64, pspec: &glib::ParamSpec) {
    let t = pspec.type_();
    if t == i32::static_type() || t.is_a(glib::Type::ENUM) {
        el.set_property(name, v as i32);
    } else if t == u32::static_type() {
        el.set_property(name, v.max(0) as u32);
    } else if t == i64::static_type() {
        el.set_property(name, v);
    } else if t == u64::static_type() {
        el.set_property(name, v.max(0) as u64);
    } else if t == f64::static_type() {
        el.set_property(name, v as f64);
    } else if t == f32::static_type() {
        el.set_property(name, v as f32);
    } else {
        el.set_property(name, v);
    }
}

// ── caller-connecting signal (C on_caller_connecting, FFI) ──────────────

struct CallerCbData {
    name: std::ffi::CString,
    socket: SharedSocket,
}

unsafe extern "C" fn on_caller_connecting_cb(
    _src: *mut gst::ffi::GstElement,
    addr: *mut gio::ffi::GSocketAddress,
    stream_id: *const std::ffi::c_char,
    authenticated: *mut glib::ffi::gboolean,
    user_data: glib::ffi::gpointer,
) {
    use std::ffi::CStr;

    let data = &*(user_data as *const CallerCbData);
    let name = data.name.to_str().unwrap_or("source");

    let addr_str = if !addr.is_null() {
        use gio::prelude::*;
        use glib::translate::FromGlibPtrNone;
        let inet = gio::SocketAddress::from_glib_none(addr)
            .downcast::<gio::InetSocketAddress>()
            .ok();
        inet.map(|a| format!("{}:{}", a.address(), a.port()))
    } else {
        None
    };

    let stream_id_str = if stream_id.is_null() {
        "none"
    } else {
        CStr::from_ptr(stream_id).to_str().unwrap_or("none")
    };

    println!(
        "New SRT caller connection to {} from {} (stream_id: {})",
        name,
        addr_str.as_deref().unwrap_or("unknown"),
        stream_id_str
    );

    if !authenticated.is_null() {
        *authenticated = glib::ffi::GTRUE;
    }

    if name == "secondary_source" {
        println!("SOURCE_VALID:secondary");
    } else {
        println!("SOURCE_VALID:primary");
    }

    if !stream_id.is_null() {
        use std::ffi::CStr;
        engine_stats::send_raw(&data.socket, b"stats_source_stream_id:");
        engine_stats::send_raw(&data.socket, CStr::from_ptr(stream_id).to_bytes());
    }
}

fn connect_caller_connecting(src: &gst::Element, name: &str, socket: SharedSocket) {
    let data = Box::into_raw(Box::new(CallerCbData {
        name: std::ffi::CString::new(name).unwrap(),
        socket,
    }));
    unsafe {
        let cb = on_caller_connecting_cb
            as unsafe extern "C" fn(
                *mut gst::ffi::GstElement,
                *mut gio::ffi::GSocketAddress,
                *const std::ffi::c_char,
                *mut glib::ffi::gboolean,
                glib::ffi::gpointer,
            );
        glib::gobject_ffi::g_signal_connect_data(
            src.as_ptr() as *mut glib::gobject_ffi::GObject,
            c"caller-connecting".as_ptr(),
            Some(std::mem::transmute::<
                unsafe extern "C" fn(
                    *mut gst::ffi::GstElement,
                    *mut gio::ffi::GSocketAddress,
                    *const std::ffi::c_char,
                    *mut glib::ffi::gboolean,
                    glib::ffi::gpointer,
                ),
                unsafe extern "C" fn(),
            >(cb)),
            data as glib::ffi::gpointer,
            None,
            0,
        );
    }
}

// ── MPEG-TS metadata probe (C ts_probe_callback) ────────────────────────

fn install_ts_probe(tee: &gst::Element, ctx: &Ctx) {
    let Some(pad) = tee.static_pad("sink") else {
        return;
    };
    let state = Arc::new(Mutex::new(TsProbeState::default()));
    let video_info = ctx.video_info.clone();
    let reported = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let reported_clone = reported.clone();
    let unknown_printed = Arc::new(std::sync::atomic::AtomicBool::new(false));

    pad.add_probe(gst::PadProbeType::BUFFER, move |_pad, info| {
        if reported_clone.load(Ordering::Relaxed) {
            return gst::PadProbeReturn::Ok;
        }
        let Some(buffer) = info.buffer() else {
            return gst::PadProbeReturn::Ok;
        };
        let mut st = match state.lock() {
            Ok(g) => g,
            Err(_) => return gst::PadProbeReturn::Ok,
        };

        if let Some(info) = st.probe(buffer) {
            println!("meta_width:{}", info.width);
            println!("meta_height:{}", info.height);
            println!(
                "meta_frame_rate:{}/{}",
                info.fps_num,
                if info.fps_den == 0 { 1 } else { info.fps_den }
            );
            println!("meta_interlaced:{}", if info.interlaced { 1 } else { 0 });
            println!("VIDEO_STREAM_TYPE:{}", info.codec.as_str());
            drop(st);
            if let Ok(mut g) = video_info.lock() {
                *g = Some(info);
            }
            reported_clone.store(true, Ordering::Relaxed);
            return gst::PadProbeReturn::Ok;
        }

        if st.attempts_exceeded() && !unknown_printed.load(Ordering::Relaxed) {
            unknown_printed.store(true, Ordering::Relaxed);
            println!("VIDEO_STREAM_TYPE:unknown");
            reported_clone.store(true, Ordering::Relaxed);
        }

        gst::PadProbeReturn::Ok
    });
    println!("MPEG-TS: Installed buffer probe on tee sink pad for video metadata extraction");
}

// ── Sinks ────────────────────────────────────────────────────────────────

/// Adds one sink branch. Ok(Some(el)) → SRT sink registered for stats.
fn add_sink(
    pipeline: &gst::Pipeline,
    tee: &gst::Element,
    cfg: &SinkConfig,
    sink_index: usize,
    ctx: &Ctx,
    vrate_elements: &Arc<Mutex<[Option<gst::Element>; 8]>>,
) -> Result<Option<gst::Element>, String> {
    match cfg.protocol {
        SinkProtocol::Sdi => {
            add_sdi_sink(pipeline, tee, cfg, sink_index, ctx, vrate_elements)?;
            Ok(None)
        }
        SinkProtocol::Srt => add_srt_sink(pipeline, tee, cfg).map(Some),
        SinkProtocol::Udp => {
            add_udp_sink(pipeline, tee, cfg)?;
            Ok(None)
        }
    }
}

fn add_srt_sink(
    pipeline: &gst::Pipeline,
    tee: &gst::Element,
    cfg: &SinkConfig,
) -> Result<gst::Element, String> {
    let sink = gst::ElementFactory::make("srtsink")
        .build()
        .map_err(|e| format!("Could not create sink elements. {}", e))?;

    // C: srtsink gets uri via set_element_properties JSON ("uri" key)
    if let Some(uri) = &cfg.uri {
        sink.set_property("uri", uri);
    }
    apply_extra_props(&sink, &cfg.extra_props);

    sink.set_property("async", false);
    sink.set_property("sync", true);
    sink.set_property("wait-for-connection", false);
    println!("Configured SRT sink with async=FALSE, sync=TRUE, wait-for-connection=FALSE");

    let queue = make_queue2();

    // C: tsparse alignment=7 set-timestamps=TRUE before srtsink
    let tsparse = match gst::ElementFactory::make("tsparse")
        .property("alignment", 7u32)
        .property("set-timestamps", true)
        .build()
    {
        Ok(t) => {
            println!("Configured tsparse before SRT sink for packet alignment and PCR smoothing");
            Some(t)
        }
        Err(_) => {
            eprintln!("Warning: tsparse plugin not found. Pacing and alignment disabled.");
            None
        }
    };

    match &tsparse {
        Some(t) => {
            pipeline
                .add_many([&queue, t, &sink])
                .map_err(|e| format!("add srt sink: {}", e))?;
            gst::Element::link_many([tee, &queue, t, &sink])
                .map_err(|_| "Could not link sink elements with tsparse.".to_string())?;
        }
        None => {
            pipeline
                .add_many([&queue, &sink])
                .map_err(|e| format!("add srt sink: {}", e))?;
            gst::Element::link_many([tee, &queue, &sink])
                .map_err(|_| "Could not link sink elements.".to_string())?;
        }
    }

    Ok(sink)
}

fn add_udp_sink(
    pipeline: &gst::Pipeline,
    tee: &gst::Element,
    cfg: &SinkConfig,
) -> Result<(), String> {
    let sink = gst::ElementFactory::make("udpsink")
        .build()
        .map_err(|e| format!("Could not create sink elements. {}", e))?;

    // C: udpsink takes host/port ("address" mapped to host) + extra props
    if let Some(host) = &cfg.host {
        sink.set_property("host", host);
        println!("Set host={} for udpsink element", host);
    }
    if let Some(port) = cfg.port {
        sink.set_property("port", port as i32);
    }
    apply_extra_props(&sink, &cfg.extra_props);

    sink.set_property("sync", false);
    sink.set_property("async", false);
    println!("Configured UDP sink with sync=FALSE, async=FALSE");

    let queue = make_queue2();

    pipeline
        .add_many([&queue, &sink])
        .map_err(|e| format!("add udp sink: {}", e))?;
    gst::Element::link_many([tee, &queue, &sink])
        .map_err(|_| "Could not link sink elements.".to_string())?;
    Ok(())
}

/// C queue2 config for network sink branches: 50MB / 3s, no buffering.
fn make_queue2() -> gst::Element {
    gst::ElementFactory::make("queue2")
        .property("use-buffering", false)
        .property("max-size-buffers", 0u32)
        .property("max-size-bytes", 50 * 1024 * 1024u32)
        .property("max-size-time", 3_000_000_000u64)
        .build()
        .expect("queue2 factory must exist")
}

// ── SDI sink branch (C add_sink_to_pipeline sdisink path) ───────────────

#[allow(clippy::too_many_arguments)]
fn add_sdi_sink(
    pipeline: &gst::Pipeline,
    tee: &gst::Element,
    cfg: &SinkConfig,
    sink_index: usize,
    ctx: &Ctx,
    vrate_elements: &Arc<Mutex<[Option<gst::Element>; 8]>>,
) -> Result<(), String> {
    let sdi = cfg.sdi.as_ref().cloned().unwrap_or_default();

    // Validate DeckLink availability first (C: factory probe)
    let probe = gst::ElementFactory::make("decklinkvideosink")
        .property("device-number", sdi.device_number)
        .build()
        .map_err(|_| {
            format!(
                "SDI sink {}: DeckLink plugin not available - install BlackMagic drivers",
                sink_index
            )
        })?;
    drop(probe);

    let is_auto = sdi.video_mode == "auto";

    let queue = gst::ElementFactory::make("queue2")
        .property("use-buffering", false)
        .property("max-size-buffers", 0u32)
        .property("max-size-bytes", 0u32)
        .property("max-size-time", 5_000_000_000u64)
        .build()
        .map_err(|e| format!("SDI sink {}: queue2: {}", sink_index, e))?;
    let tsdemux = gst::ElementFactory::make("tsdemux")
        .build()
        .map_err(|e| format!("SDI sink {}: tsdemux: {}", sink_index, e))?;
    let vdecodebin = gst::ElementFactory::make("decodebin")
        .build()
        .map_err(|e| format!("SDI sink {}: vdecodebin: {}", sink_index, e))?;
    let vqueue = make_sdi_queue("max-size-time", 5_000_000_000u64);
    let vconvert = gst::ElementFactory::make("videoconvert")
        .build()
        .map_err(|e| format!("SDI sink {}: videoconvert: {}", sink_index, e))?;
    let vrate = gst::ElementFactory::make("videorate")
        .property("skip-to-first", true)
        .build()
        .map_err(|e| format!("SDI sink {}: videorate: {}", sink_index, e))?;
    let vscale = gst::ElementFactory::make("videoscale")
        .build()
        .map_err(|e| format!("SDI sink {}: videoscale: {}", sink_index, e))?;
    let vcaps = gst::ElementFactory::make("capsfilter")
        .build()
        .map_err(|e| format!("SDI sink {}: capsfilter: {}", sink_index, e))?;
    let videosink = gst::ElementFactory::make("decklinkvideosink")
        .property("device-number", sdi.device_number)
        .property("sync", false)
        .build()
        .map_err(|e| format!("SDI sink {}: decklinkvideosink: {}", sink_index, e))?;

    let adecodebin = gst::ElementFactory::make("decodebin")
        .build()
        .map_err(|e| format!("SDI sink {}: adecodebin: {}", sink_index, e))?;
    let aqueue = make_sdi_queue("max-size-time", 5_000_000_000u64);
    let aconvert = gst::ElementFactory::make("audioconvert")
        .build()
        .map_err(|e| format!("SDI sink {}: audioconvert: {}", sink_index, e))?;
    let amix = gst::ElementFactory::make("audiomixmatrix")
        .build()
        .map_err(|e| format!("SDI sink {}: audiomixmatrix: {}", sink_index, e))?;
    let aresample = gst::ElementFactory::make("audioresample")
        .build()
        .map_err(|e| format!("SDI sink {}: audioresample: {}", sink_index, e))?;
    let arate = gst::ElementFactory::make("audiorate")
        .build()
        .map_err(|e| format!("SDI sink {}: audiorate: {}", sink_index, e))?;
    let acaps = gst::ElementFactory::make("capsfilter")
        .property("caps", engine_sdi::sdi_audio_caps())
        .build()
        .map_err(|e| format!("SDI sink {}: audio capsfilter: {}", sink_index, e))?;
    let audiosink = gst::ElementFactory::make("decklinkaudiosink")
        .property("device-number", sdi.device_number)
        .property("sync", true)
        .property("max-lateness", 200_000_000i64)
        .build()
        .map_err(|e| format!("SDI sink {}: decklinkaudiosink: {}", sink_index, e))?;

    let vid_identity = gst::ElementFactory::make("identity")
        .property("sync", true)
        .build()
        .map_err(|e| format!("SDI sink {}: identity: {}", sink_index, e))?;

    engine_sdi::setup_audio_upmix(&amix)?;

    let elements: Vec<&gst::Element> = vec![
        &queue,
        &tsdemux,
        &vdecodebin,
        &vqueue,
        &vconvert,
        &vrate,
        &vscale,
        &vcaps,
        &vid_identity,
        &videosink,
        &adecodebin,
        &aqueue,
        &aconvert,
        &amix,
        &aresample,
        &arate,
        &acaps,
        &audiosink,
    ];
    pipeline
        .add_many(&elements)
        .map_err(|e| format!("SDI sink {}: add: {}", sink_index, e))?;

    // Register videorate for stats collection
    if (0..8).contains(&sdi.device_number) {
        if let Ok(mut v) = vrate_elements.lock() {
            v[sdi.device_number as usize] = Some(vrate.clone());
        }
    }

    // Static audio chain: aqueue → aconvert → amix → aresample → arate → acaps → audiosink
    gst::Element::link_many([
        &aqueue, &aconvert, &amix, &aresample, &arate, &acaps, &audiosink,
    ])
    .map_err(|_| format!("SDI sink {}: Failed to link audio output chain", sink_index))?;

    // Static tee → queue → tsdemux
    gst::Element::link_many([tee, &queue, &tsdemux]).map_err(|_| {
        format!(
            "SDI sink {}: Failed to link tee → queue → tsdemux",
            sink_index
        )
    })?;

    // tsdemux pad-added → route video/audio to decodebins
    {
        let vdb = vdecodebin.clone();
        let adb = adecodebin.clone();
        tsdemux.connect_pad_added(move |_src, new_pad| {
            let Some(caps) = new_pad
                .current_caps()
                .or_else(|| Some(new_pad.query_caps(None)))
            else {
                return;
            };
            let Some(s) = caps.structure(0) else { return };
            let name = s.name();
            let target = if name.starts_with("video/") {
                Some(vdb.clone())
            } else if name.starts_with("audio/") {
                Some(adb.clone())
            } else {
                None
            };
            if let Some(t) = target {
                if let Some(sink_pad) = t.static_pad("sink") {
                    if !sink_pad.is_linked() {
                        match new_pad.link(&sink_pad) {
                            Ok(_) => println!("SDI tsdemux: linked {} → decodebin", name),
                            Err(e) => {
                                eprintln!("SDI tsdemux: pad link failed for '{}': {:?}", name, e)
                            }
                        }
                    }
                }
            }
        });
    }

    // Health probes (audio: silence detection + recovery; video: frame counts)
    install_sdi_health_probes(&audiosink, &videosink, sdi.device_number, ctx)?;

    if is_auto {
        println!(
            "SDI sink {}: AUTO-DETECT mode — video chain deferred until first frame",
            sink_index
        );
        videosink.set_property_from_str("mode", "1080p25");

        let fallback = engine_sdi::FallbackConfig {
            mode: "1080p25".to_string(),
            width: sdi.width,
            height: sdi.height,
            framerate: sdi.framerate.clone(),
        };

        connect_autodetect_pad_added(
            pipeline,
            &vdecodebin,
            &vqueue,
            &vconvert,
            &vrate,
            &vscale,
            &vcaps,
            &vid_identity,
            &videosink,
            sdi.device_number,
            fallback,
            ctx,
        );

        println!(
            "SDI sink {}: pipeline created (AUTO-DETECT) → DeckLink device {}",
            sink_index, sdi.device_number
        );
    } else {
        let caps_str = if sdi.interlaced {
            format!(
                "video/x-raw, format=UYVY, width={}, height={}, framerate={}, interlace-mode=interleaved",
                sdi.width, sdi.height, sdi.framerate
            )
        } else {
            format!(
                "video/x-raw, format=UYVY, width={}, height={}, framerate={}",
                sdi.width, sdi.height, sdi.framerate
            )
        };
        println!(
            "SDI sink {}: mode={} -> caps: {}",
            sink_index, sdi.video_mode, caps_str
        );

        let caps = gst::Caps::from_str(&caps_str)
            .map_err(|_| format!("SDI sink {}: bad caps string", sink_index))?;
        vcaps.set_property("caps", caps);
        videosink.set_property_from_str("mode", &sdi.video_mode);

        // Static video chain (+ optional interlace element for interlaced modes)
        let interlace_needed = sdi.interlaced;
        let link_result = if interlace_needed {
            let vinterlace = gst::ElementFactory::make("interlace")
                .property_from_str("field-pattern", "2:2")
                .property("top-field-first", true)
                .build()
                .map_err(|e| format!("SDI sink {}: interlace: {}", sink_index, e))?;
            pipeline
                .add(&vinterlace)
                .map_err(|e| format!("SDI sink {}: add interlace: {}", sink_index, e))?;
            gst::Element::link_many([
                &vqueue,
                &vconvert,
                &vrate,
                &vscale,
                &vinterlace,
                &vcaps,
                &vid_identity,
                &videosink,
            ])
        } else {
            gst::Element::link_many([
                &vqueue,
                &vconvert,
                &vrate,
                &vscale,
                &vcaps,
                &vid_identity,
                &videosink,
            ])
        };
        link_result
            .map_err(|_| format!("SDI sink {}: Failed to link video output chain", sink_index))?;

        // decodebin video pad → vqueue
        connect_raw_pad_added(
            &vdecodebin,
            &vqueue,
            "SDI: decodebin video → output chain linked",
        );

        println!(
            "SDI sink {}: pipeline created (decodebin) → DeckLink device {} (mode {})",
            sink_index, sdi.device_number, sdi.video_mode
        );
    }

    // decodebin audio pads → aqueue (both modes)
    connect_raw_pad_added(
        &adecodebin,
        &aqueue,
        "SDI: decodebin audio → output chain linked",
    );

    println!("SDI sink {}: Audio health monitor installed", sink_index);
    println!("SDI sink {}: Video health monitor installed", sink_index);
    Ok(())
}

fn make_sdi_queue(prop: &str, value: u64) -> gst::Element {
    let b = gst::ElementFactory::make("queue")
        .property("max-size-buffers", 0u32)
        .property("max-size-bytes", 0u32);
    // max-size-time via generic set to avoid builder type ambiguity
    let q = b.build().expect("queue factory must exist");
    let _ = prop;
    q.set_property("max-size-time", value);
    q
}

fn connect_raw_pad_added(decodebin: &gst::Element, target: &gst::Element, ok_msg: &str) {
    let target = target.clone();
    let ok_msg = ok_msg.to_string();
    decodebin.connect_pad_added(move |_db, pad| {
        let Some(caps) = pad.current_caps().or_else(|| Some(pad.query_caps(None))) else {
            return;
        };
        let Some(s) = caps.structure(0) else { return };
        let raw_prefix =
            if s.name().starts_with("video/x-raw") || s.name().starts_with("audio/x-raw") {
                true
            } else {
                s.name().starts_with("video/x-raw")
            };
        if !raw_prefix && !s.name().starts_with("audio/x-raw") {
            return;
        }
        if let Some(sink_pad) = target.static_pad("sink") {
            if !sink_pad.is_linked() {
                match pad.link(&sink_pad) {
                    Ok(_) => println!("{}", ok_msg),
                    Err(e) => eprintln!("SDI: decodebin pad link failed: {:?}", e),
                }
            }
        }
    });
}

#[allow(clippy::too_many_arguments)]
fn connect_autodetect_pad_added(
    pipeline: &gst::Pipeline,
    vdecodebin: &gst::Element,
    vqueue: &gst::Element,
    vconvert: &gst::Element,
    vrate: &gst::Element,
    vscale: &gst::Element,
    vcaps: &gst::Element,
    vid_identity: &gst::Element,
    videosink: &gst::Element,
    device_number: i32,
    fallback: engine_sdi::FallbackConfig,
    ctx: &Ctx,
) {
    let pipeline = pipeline.clone();
    let vqueue = vqueue.clone();
    let vconvert = vconvert.clone();
    let vrate = vrate.clone();
    let vscale = vscale.clone();
    let vcaps = vcaps.clone();
    let vid_identity = vid_identity.clone();
    let videosink = videosink.clone();
    let detected_mode = ctx.sdi_state.clone();

    vdecodebin.connect_pad_added(move |_db, pad| {
        let Some(caps) = pad.current_caps().or_else(|| Some(pad.query_caps(None))) else {
            return;
        };
        let Some(decision) = engine_sdi::decide_from_caps(&caps, &fallback) else {
            return;
        };

        println!(
            "SDI AUTO-DETECT: decoded video caps → {}",
            caps.structure(0).map(|s| s.to_string()).unwrap_or_default()
        );
        if decision.matched {
            println!(
                "SDI AUTO-DETECT: MATCHED → mode={} (interlace={})",
                decision.mode_str,
                if decision.need_interlace_element { "yes" } else { "no" }
            );
        } else {
            eprintln!(
                "SDI AUTO-DETECT: NO MATCH — fallback to {}",
                decision.mode_str
            );
        }
        println!(
            "SDI AUTO-DETECT: set decklinkvideosink mode={}",
            decision.mode_str
        );
        println!(
            "SDI AUTO-DETECT: capsfilter → video/x-raw, format=UYVY, width={}, height={}, framerate={}{}",
            decision.width,
            decision.height,
            decision.framerate,
            decision
                .interlace_mode
                .map(|m| format!(", interlace-mode={}", m))
                .unwrap_or_default()
        );

        if (0..8).contains(&device_number) {
            if let Ok(mut modes) = detected_mode.detected_mode.lock() {
                modes[device_number as usize] = Some(decision.mode_str.clone());
            }
        }

        videosink.set_property_from_str("mode", &decision.mode_str);

        let caps_str = if let Some(m) = decision.interlace_mode {
            format!(
                "video/x-raw, format=UYVY, width={}, height={}, framerate={}, interlace-mode={}",
                decision.width, decision.height, decision.framerate, m
            )
        } else {
            format!(
                "video/x-raw, format=UYVY, width={}, height={}, framerate={}",
                decision.width, decision.height, decision.framerate
            )
        };
        if let Ok(c) = gst::Caps::from_str(&caps_str) {
            vcaps.set_property("caps", c);
        }

        let mut interlace_el: Option<gst::Element> = None;
        if decision.need_interlace_element {
            match gst::ElementFactory::make("interlace")
                .property_from_str("field-pattern", "2:2")
                .property("top-field-first", true)
                .build()
            {
                Ok(vi) => {
                    if pipeline.add(&vi).is_ok() {
                        println!("SDI AUTO-DETECT: added interlace element (field-pattern=2:2, tff=TRUE)");
                        interlace_el = Some(vi);
                    }
                }
                Err(_) => {
                    eprintln!("SDI AUTO-DETECT: WARNING — failed to create interlace element, proceeding without");
                }
            }
        }

        let linked = match &interlace_el {
            Some(vi) => gst::Element::link_many([
                &vqueue, &vconvert, &vrate, &vscale, vi, &vcaps, &vid_identity, &videosink,
            ]),
            None => gst::Element::link_many([&vqueue, &vconvert, &vrate, &vscale, &vcaps, &vid_identity, &videosink]),
        };

        if linked.is_err() {
            eprintln!(
                "SDI AUTO-DETECT: FAILED to link video output chain for mode={}",
                decision.mode_str
            );
            if let Some(vi) = &interlace_el {
                let _ = vi.set_state(gst::State::Null);
                let _ = pipeline.remove(vi);
                let retry_caps = gst::Caps::from_str(&format!(
                    "video/x-raw, format=UYVY, width={}, height={}, framerate={}",
                    decision.width, decision.height, decision.framerate
                ));
                if let Ok(c) = retry_caps {
                    vcaps.set_property("caps", c);
                }
                if gst::Element::link_many([&vqueue, &vconvert, &vrate, &vscale, &vcaps, &vid_identity, &videosink]).is_err() {
                    eprintln!("SDI AUTO-DETECT: FATAL — video chain link failed even without interlace");
                    return;
                }
            } else {
                return;
            }
        } else {
            println!("SDI AUTO-DETECT: video chain linked successfully");
        }

        if let Some(vi) = &interlace_el {
            let _ = vi.sync_state_with_parent();
        }

        if let Some(sink_pad) = vqueue.static_pad("sink") {
            if !sink_pad.is_linked() {
                match pad.link(&sink_pad) {
                    Ok(_) => println!("SDI AUTO-DETECT: decodebin video → vqueue linked, flow started"),
                    Err(e) => eprintln!("SDI AUTO-DETECT: decodebin video → vqueue link FAILED: {:?}", e),
                }
            }
        }
    });
}

fn install_sdi_health_probes(
    audiosink: &gst::Element,
    videosink: &gst::Element,
    device: i32,
    ctx: &Ctx,
) -> Result<(), String> {
    if !(0..8).contains(&device) {
        return Ok(());
    }
    let idx = device as usize;
    let sdi = ctx.sdi_state.clone();

    if let Some(pad) = audiosink.static_pad("sink") {
        let sdi = sdi.clone();
        pad.add_probe(gst::PadProbeType::BUFFER, move |_pad, _info| {
            let now = now_monotonic_us();
            sdi.audio_last_buffer_us[idx].store(now, Ordering::Relaxed);
            sdi.audio_buffer_count[idx].fetch_add(1, Ordering::Relaxed);
            if sdi.audio_silence_reported[idx].swap(false, Ordering::Relaxed) {
                println!(
                    "SDI_AUDIO_RECOVERED: device={} audio_buffers_flowing_again",
                    idx
                );
            }
            gst::PadProbeReturn::Ok
        });
    }

    if let Some(pad) = videosink.static_pad("sink") {
        pad.add_probe(gst::PadProbeType::BUFFER, move |_pad, _info| {
            sdi.video_buffer_count[idx].fetch_add(1, Ordering::Relaxed);
            gst::PadProbeReturn::Ok
        });
    }
    Ok(())
}

fn now_monotonic_us() -> i64 {
    use std::time::Instant;
    static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    let start = START.get_or_init(Instant::now);
    start.elapsed().as_micros() as i64
}
