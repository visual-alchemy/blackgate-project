// Unified pipeline builder — C create_pipeline parity.
//
// Single source  : source → tee → {per-sink branches} + thumbnail branch
// Dual-ingest    : source + secondary_source → input-selector → tee → ...
// Metadata probe : tee sink pad (engine-metadata) → meta_* stdout + shared VideoInfo

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use gio;
use gst::glib;
use gst::prelude::*;
use gstreamer as gst;

use engine_config::{PropValue, RouteConfig, SinkConfig, SinkProtocol, SourceConfig};
use engine_metadata::TsProbeState;
use engine_stats::{SharedSocket, SharedVideoInfo};
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
}

struct Ctx {
    socket: SharedSocket,
    video_info: SharedVideoInfo,
}

pub fn build_pipeline(config: &RouteConfig, socket: SharedSocket) -> Result<BuiltPipeline, String> {
    let ctx = Ctx {
        socket,
        video_info: Arc::new(Mutex::new(None)),
    };

    let pipeline = gst::Pipeline::with_name("test-pipeline");
    let tee = gst::ElementFactory::make("tee")
        .name("tee")
        .property("allow-not-linked", true)
        .build()
        .map_err(|e| format!("Failed to create tee element: {}", e))?;
    println!("Set allow-not-linked=TRUE for tee element");

    let source = make_source(&config.source, "source", &ctx)?;

    let (selector, secondary) = match &config.secondary {
        Some(sec) => {
            let selector = gst::ElementFactory::make("input-selector")
                .name("input-selector")
                .build()
                .map_err(|e| format!("Failed to create input-selector: {}", e))?;
            let secondary = make_source(&sec.source, "secondary_source", &ctx)?;

            // sync-mode=active-segment (0). The C oracle carries stale sync-mode=1
            // ("clock"), which blocks the primary pad waiting on an idle secondary and
            // stalls the srtsrc listener into SRT socket overflow + connection drop.
            // Blackgate-lite fixed this (8cca10e); match lite, not the oracle.
            // GstInputSelectorSyncMode: 0=active-segment, 1=clock (gst-inspect-1.0).
            selector.set_property_from_str("sync-mode", "active-segment");
            selector.set_property("cache-buffers", true);
            selector.set_property("drop-backwards", true);

            pipeline
                .add_many([&source, &secondary, &selector, &tee])
                .map_err(|e| format!("dual add: {}", e))?;

            // C lite 2055-2068: persist the logical selection across restarts by
            // selecting sink_1 when Elixir reports active_source="secondary".
            // Runtime-only — the element is still PLAYING from construction.
            let start_on_secondary = config.active_source.as_deref() == Some("secondary");

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

            if let Some(active) = selector.static_pad(if start_on_secondary {
                "sink_1"
            } else {
                "sink_0"
            }) {
                selector.set_property("active-pad", &active);
            }

            if start_on_secondary {
                println!("DUAL-INGEST: starting on secondary (persisted active_source)");
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

    for (idx, sink_cfg) in config.sinks.iter().enumerate() {
        match add_sink(&pipeline, &tee, sink_cfg) {
            Ok(Some(srt_sink)) => {
                println!(
                    "Stored SRT sink element at index {} for stats collection",
                    idx
                );
                srt_sinks.push(srt_sink);
            }
            Ok(None) => {}
            Err(err) => return Err(err),
        }
    }

    // BLACKGATE_NO_THUMBNAIL=1 skips the preview branch entirely. Kept as a
    // diagnostic switch (and for hosts that do not need previews): A/B runs with
    // and without the branch show the same SRT receive loss, so the preview is
    // not what stalls the source — do not "fix" receive loss by removing it.
    let thumbnails_enabled = std::env::var("BLACKGATE_NO_THUMBNAIL").is_err();
    let thumbnail = if preview_requested(config, thumbnails_enabled) {
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

    // C lite join_secondary/leave_secondary use locked-state, not set_state:
    // gst_element_set_locked_state + sync_state_with_parent so the source joins
    // the pipeline's state machine atomically. Plain set_state(NULL) also strips
    // the lock, so join-secondary could never restore the source — live bug.
    if let Some(sec) = &secondary {
        if !config.auto_join {
            sec.set_locked_state(true);
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
    })
}

// ── Sources ──────────────────────────────────────────────────────────────

fn make_source(cfg: &SourceConfig, name: &str, ctx: &Ctx) -> Result<gst::Element, String> {
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

    // Pure passthrough: no sink in this build carries its own clock, so the source
    // must not stamp buffers itself.
    src.set_property("do-timestamp", false);
    println!(
        "Set do-timestamp=FALSE for {} source element (pure passthrough)",
        name
    );

    if cfg.element_type == "srtsrc" {
        if std::env::var("BLACKGATE_DUMP_PROPS").is_ok() {
            dump_element_props(&src);
        }
        connect_caller_connecting(&src, name, ctx.socket.clone());
    }

    Ok(src)
}

/// Diagnostic dump of every effective property of an element as `PROP name=value`
/// lines, so the Rust engine's source setup can be diffed against the C engine's
/// (set `BLACKGATE_DUMP_PROPS=1`; blackgate-lite's `set_element_properties` prints the
/// same format). Kept because the C and Rust engines are meant to configure the same
/// GStreamer elements identically, and this is how that is verified.
fn dump_element_props(el: &gst::Element) {
    let mut lines: Vec<String> = el
        .list_properties()
        .iter()
        // Write-only properties (srtsrc's `passphrase`) panic on read.
        .filter(|pspec| pspec.flags().contains(gst::glib::ParamFlags::READABLE))
        .map(|pspec| {
            let name = pspec.name().to_string();
            let value = el.property_value(&name);
            let rendered = if let Ok(s) = value.get::<String>() {
                s
            } else if let Ok(b) = value.get::<bool>() {
                b.to_string()
            } else if let Ok(i) = value.get::<i32>() {
                i.to_string()
            } else if let Ok(u) = value.get::<u32>() {
                u.to_string()
            } else if let Ok(i) = value.get::<i64>() {
                i.to_string()
            } else if let Ok(u) = value.get::<u64>() {
                u.to_string()
            } else if let Ok(f) = value.get::<f64>() {
                f.to_string()
            } else {
                format!("{:?}", value)
            };
            format!("PROP {}={}", name, rendered)
        })
        .collect();
    lines.sort();
    for line in lines {
        println!("{}", line);
    }
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
                if pspec.value_type() == bool::static_type() {
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
    let t = pspec.value_type();
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
        // Same framing rule as the route_id record: terminated, so the node's handler can
        // buffer on newlines instead of guessing boundaries inside a TCP chunk.
        engine_stats::send_raw(&data.socket, b"stats_source_stream_id:");
        engine_stats::send_raw(&data.socket, CStr::from_ptr(stream_id).to_bytes());
        engine_stats::send_raw(&data.socket, b"\n");
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
) -> Result<Option<gst::Element>, String> {
    match cfg.protocol {
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
    // sync=FALSE, like the UDP sink below. A network sink must not pace itself on the pipeline clock: with
    // sync=TRUE the sink waits on the clock before handing each buffer to SRT, so a busy multi-destination
    // route drains late - measured at 15% egress loss on a link that pings clean, with GStreamer warning
    // "Pipeline construction is invalid, please add queues" from srtsink0. SRT schedules delivery itself
    // from the timestamps and the negotiated latency, so the sink does not need to.
    sink.set_property("sync", false);
    sink.set_property("wait-for-connection", false);
    println!("Configured SRT sink with async=FALSE, sync=FALSE, wait-for-connection=FALSE");

    let queue = make_queue2(SINK_QUEUE_BYTES, SINK_QUEUE_TIME_NS);

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

    // Same bounded decoupling buffer as the SRT sink branch: a UDP destination cannot
    // back-pressure, so a 50 MB ring buffer only bought RSS, never smoothness.
    let queue = make_queue2(SINK_QUEUE_BYTES, SINK_QUEUE_TIME_NS);

    pipeline
        .add_many([&queue, &sink])
        .map_err(|e| format!("add udp sink: {}", e))?;
    gst::Element::link_many([tee, &queue, &sink])
        .map_err(|_| "Could not link sink elements.".to_string())?;
    Ok(())
}

/// `queue2` for network sink branches. `max_bytes` / `max_time_ns` bound the branch's
/// decoupling buffer: a small queue absorbs scheduling jitter without letting a
/// destination that cannot keep up grow into tens of megabytes of RSS. The C engine has
/// no queue here at all, so this stays deliberately modest — the old 50 MB / 3 s ring
/// buffer cost ~47 MB of peak RSS on the udp-to-srt workload (70 MB vs 22.4 MB).
fn make_queue2(max_bytes: u32, max_time_ns: u64) -> gst::Element {
    gst::ElementFactory::make("queue2")
        .property("use-buffering", false)
        .property("max-size-buffers", 0u32)
        .property("max-size-bytes", max_bytes)
        .property("max-size-time", max_time_ns)
        .build()
        .expect("queue2 factory must exist")
}

/// Whether the preview/thumbnail branch belongs in this pipeline.
///
/// The C engine builds its thumbnail chain only when the config asks for one, so this must
/// not be inferred from `route_id` alone: a headless route or a benchmark run would
/// otherwise pay ~33 MB of H.264 decoder frame pool that the C run never allocates
/// (measured: 51.9 MB vs 19.3 MB peak RSS on the udp-to-srt config). `env_allows` carries
/// `BLACKGATE_NO_THUMBNAIL`; keeping it a parameter is what makes this testable.
fn preview_requested(config: &RouteConfig, env_allows: bool) -> bool {
    config.preview && !config.route_id.is_empty() && env_allows
}

/// Decoupling buffer for an SRT destination branch: enough to ride out scheduling
/// jitter, small enough that peak RSS stays in the C engine's range.
const SINK_QUEUE_BYTES: u32 = 2 * 1024 * 1024;
const SINK_QUEUE_TIME_NS: u64 = 500_000_000;
// Compile-time guard: a destination that cannot keep up must never grow tens of MB again.
// The old 50 MB / 3 s ring buffer cost ~47 MB of peak RSS on the udp-to-srt workload.
const _: () = assert!(SINK_QUEUE_BYTES <= 4 * 1024 * 1024);

#[cfg(test)]
mod tests {
    use super::*;

    // Regression: pspec.type_() is the param-spec CLASS type (e.g. GParamBoolean),
    // not the property value type. Dispatching on it made every bool prop fall
    // through to an i32 set and panic ("expected gboolean, got gint"), which
    // crash-looped real SRT routes carrying auto-reconnect/keep-listening.
    #[test]
    fn extra_props_dispatch_on_value_type() {
        gst::init().unwrap();
        let el = gst::ElementFactory::make("fakesink").build().unwrap();

        let mut props = std::collections::BTreeMap::new();
        props.insert("sync".to_string(), PropValue::Bool(false));
        props.insert("num-buffers".to_string(), PropValue::Int(3));

        apply_extra_props(&el, &props);

        assert!(!el.property::<bool>("sync"));
        assert_eq!(el.property::<i32>("num-buffers"), 3);
    }

    fn config_with(route_id: &str, preview: bool) -> RouteConfig {
        let json = format!(
            r#"{{"route_id":"{}","source":{{"type":"udpsrc","uri":"udp://127.0.0.1:5000"}},"sinks":[],"preview":{}}}"#,
            route_id, preview
        );
        RouteConfig::from_elixir_json(&json).expect("test config must parse")
    }

    // Regression: the branch used to be built whenever route_id was non-empty, so every
    // headless route and benchmark run paid ~33 MB of decoder frame pool the C engine
    // never allocates. It must follow the config, and the env override must still win.
    #[test]
    fn preview_branch_is_built_only_when_the_config_asks() {
        assert!(preview_requested(&config_with("route-1", true), true));
        assert!(!preview_requested(&config_with("route-1", false), true));
        assert!(!preview_requested(&config_with("route-1", true), false));
        assert!(!preview_requested(&config_with("", true), true));
    }

    // The old branch used a 50 MB / 3 s ring buffer. It was not the cause of the RSS
    // regression (the preview branch was), but the bound itself was never justified: a
    // UDP or SRT destination that cannot keep up must not be able to grow tens of MB.
    #[test]
    fn srt_sink_does_not_pace_on_the_pipeline_clock() {
        // sync=TRUE made the sink wait for the pipeline clock before handing each buffer to SRT. On a
        // multi-destination route that wait never resolved: the sink stopped draining, its branch queue
        // filled, the tee blocked and the source stalled - the feeding ffmpeg failed with
        // "Error muxing a packet: Input/output error" because the engine had stopped reading it.
        gst::init().unwrap();
        let pipeline = gst::Pipeline::new();
        let tee = gst::ElementFactory::make("tee").build().expect("tee");
        pipeline.add(&tee).expect("add tee");
        let cfg = SinkConfig {
            element_type: "srtsink".to_string(),
            protocol: SinkProtocol::Srt,
            uri: Some("srt://127.0.0.1:9?mode=listener".to_string()),
            host: None,
            port: None,
            latency_ms: 2000,
            mode: None,
            passphrase: None,
            streamid: None,
            extra_props: std::collections::BTreeMap::new(),
        };
        let sink = add_srt_sink(&pipeline, &tee, &cfg).expect("srt sink");
        assert!(
            !sink.property::<bool>("sync"),
            "the SRT sink must not wait on the pipeline clock (see the multi-destination stall)"
        );
        assert!(
            !sink.property::<bool>("async"),
            "the SRT sink stays async=FALSE: a live route must not wait for preroll"
        );
    }

    #[test]
    fn sink_queue_budget_stays_small() {
        gst::init().unwrap();
        let queue = make_queue2(SINK_QUEUE_BYTES, SINK_QUEUE_TIME_NS);
        assert_eq!(queue.property::<u32>("max-size-bytes"), 2 * 1024 * 1024);
        assert_eq!(queue.property::<u64>("max-size-time"), 500_000_000);
        assert_eq!(queue.property::<u32>("max-size-buffers"), 0);
    }
}
