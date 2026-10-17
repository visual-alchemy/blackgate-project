// Runtime stats collection — ported from native/src/stats_serialize.c
//
// Wire contract (C parity, consumed by unix_sock_handler.ex + route_health.ex):
//   1s loop → primary JSON {"source":"primary",...}+"\n"
//            → secondary JSON {"source":"secondary",...}+"\n" (dual-ingest only)
//            → per SRT sink: "stats_sink:"+JSON+"\n"
// Keys MUST match C exactly: total-bytes-received, packets-received-lost, ...

use gst::glib;
use gst::prelude::*;
use gstreamer as gst;
use serde::Serialize;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// Counts `apply_source_stats_structure` calls so `BLACKGATE_DUMP_STATS` prints once.
static STATS_DUMP_COUNT: AtomicU64 = AtomicU64::new(0);
use std::thread;
use std::time::Duration;

use engine_metadata::VideoInfo;

/// C: #define SDI_AUDIO_HEALTH_INTERVAL_SEC 10 (pipeline_state.h)
pub const SDI_AUDIO_HEALTH_INTERVAL_SEC: f64 = 10.0;

pub static IO_BYTES: AtomicU64 = AtomicU64::new(0);

// ── Shared pipeline state (C globals parity) ─────────────────────────────

/// Per-device SDI health/counter state — mirrors the C global arrays.
#[derive(Default)]
pub struct SdiState {
    pub audio_last_buffer_us: [AtomicI64; 8],
    pub audio_buffer_count: [AtomicI64; 8],
    pub audio_silence_reported: [AtomicBool; 8],
    pub video_buffer_count: [AtomicI64; 8],
    pub detected_mode: Mutex<[Option<String>; 8]>,
}

impl SdiState {
    pub fn new_shared() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Reset all devices — C cleanup_pipeline loop.
    pub fn reset(&self) {
        for i in 0..8 {
            self.audio_last_buffer_us[i].store(0, Ordering::Relaxed);
            self.audio_buffer_count[i].store(0, Ordering::Relaxed);
            self.audio_silence_reported[i].store(false, Ordering::Relaxed);
            self.video_buffer_count[i].store(0, Ordering::Relaxed);
        }
        if let Ok(mut modes) = self.detected_mode.lock() {
            *modes = Default::default();
        }
    }
}

/// Shared decoded-video metadata (C `video_info` + mutex).
pub type SharedVideoInfo = Arc<Mutex<Option<VideoInfo>>>;

// ── Serialized shapes — key order and names EXACTLY match C ─────────────

#[derive(Debug, Serialize, Clone)]
pub struct SourceStats {
    pub source: String,
    #[serde(rename = "total-bytes-received")]
    pub total_bytes_received: u64,
    /// Bytes since the previous report (C lite 234-235 emits this alongside the
    /// running total; the oracle omitted it, which silently zeroed
    /// route_controller.ex:31 "is data flowing?" fallback).
    #[serde(rename = "bytes-received")]
    pub bytes_received: i64,
    #[serde(rename = "packets-received")]
    pub packets_received: i64,
    #[serde(rename = "packets-received-lost")]
    pub packets_received_lost: i64,
    #[serde(rename = "packets-received-dropped")]
    pub packets_received_dropped: i64,
    #[serde(rename = "packets-received-retransmitted")]
    pub packets_received_retransmitted: i64,
    #[serde(rename = "rtt-ms")]
    pub rtt_ms: f64,
    #[serde(rename = "receive-rate-mbps")]
    pub receive_rate_mbps: f64,
    #[serde(rename = "bandwidth-mbps")]
    pub bandwidth_mbps: f64,
    #[serde(rename = "negotiated-latency-ms")]
    pub negotiated_latency_ms: i32,
    #[serde(rename = "connected-callers")]
    pub connected_callers: i32,
    pub callers: Vec<serde_json::Map<String, serde_json::Value>>,
}

#[derive(Debug, Serialize, Clone)]
pub struct SinkStats {
    #[serde(rename = "sink-index")]
    pub sink_index: i32,
    #[serde(rename = "bytes-sent-total")]
    pub bytes_sent_total: u64,
    #[serde(rename = "packets-sent")]
    pub packets_sent: i64,
    #[serde(rename = "packets-sent-lost")]
    pub packets_sent_lost: i64,
    #[serde(rename = "packets-sent-dropped")]
    pub packets_sent_dropped: i64,
    #[serde(rename = "packets-sent-retransmitted")]
    pub packets_sent_retransmitted: i64,
    /// C lite 354: srtsink "bytes-received" (this sink's inbound byte count).
    #[serde(rename = "bytes-received")]
    pub bytes_received: i64,
    #[serde(rename = "rtt-ms")]
    pub rtt_ms: f64,
    #[serde(rename = "send-rate-mbps")]
    pub send_rate_mbps: f64,
    #[serde(rename = "bandwidth-mbps")]
    pub bandwidth_mbps: f64,
    #[serde(rename = "negotiated-latency-ms")]
    pub negotiated_latency_ms: i32,
    #[serde(rename = "connected-callers")]
    pub connected_callers: i32,
    pub callers: Vec<serde_json::Map<String, serde_json::Value>>,
}

/// SDI per-device stats array — C collectSinkStats sdi_video_stats item.
#[derive(Debug, Serialize, Clone)]
pub struct SdiVideoStatsItem {
    pub device_number: i32,
    pub dropped_frames: u64,
    pub duplicated_frames: u64,
    pub video_frames: i64,
    pub audio_buffers: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detected_mode: Option<String>,
}

// ── gst stats extraction ─────────────────────────────────────────────────

// Per-tag last-seen totals for the source `bytes-received` delta (C lite
// `last_report_bytes`, source_ts_info[] slot 0=primary, 1=secondary).
static LAST_SOURCE_BYTES: [AtomicU64; 2] = [AtomicU64::new(0), AtomicU64::new(0)];

fn source_slot(tag: &str) -> usize {
    if tag == "secondary" {
        1
    } else {
        0
    }
}

fn struct_get_i64(s: &gst::Structure, name: &str) -> i64 {
    s.get::<i64>(name)
        .or_else(|_| s.get::<i32>(name).map(|v| v as i64))
        .or_else(|_| s.get::<u32>(name).map(|v| v as i64))
        .or_else(|_| s.get::<u64>(name).map(|v| v as i64))
        .or_else(|_| s.get::<f64>(name).map(|v| v as i64))
        .unwrap_or(0)
}

fn struct_get_u64(s: &gst::Structure, name: &str) -> u64 {
    s.get::<u64>(name)
        .or_else(|_| s.get::<i64>(name).map(|v| v.max(0) as u64))
        .or_else(|_| s.get::<u32>(name).map(|v| v as u64))
        .or_else(|_| s.get::<i32>(name).map(|v| v.max(0) as u64))
        .or_else(|_| s.get::<f64>(name).map(|v| v.max(0.0) as u64))
        .unwrap_or(0)
}

fn struct_get_f64(s: &gst::Structure, name: &str) -> f64 {
    s.get::<f64>(name).unwrap_or(0.0)
}

fn stats_structure(element: &gst::Element) -> Option<gst::Structure> {
    element.find_property("stats")?;
    element.property_value("stats").get::<gst::Structure>().ok()
}

/// Convert one caller GstStructure field to JSON (C: int64/int/uint64/double
/// passthrough + caller-address GInetSocketAddress → "ip:port").
fn caller_field_to_json(field_name: &str, value: &glib::Value) -> Option<serde_json::Value> {
    let t = value.type_();
    if t == i64::static_type() {
        value.get::<i64>().ok().map(serde_json::Value::from)
    } else if t == i32::static_type() {
        value.get::<i32>().ok().map(serde_json::Value::from)
    } else if t == u64::static_type() {
        value.get::<u64>().ok().map(serde_json::Value::from)
    } else if t == u32::static_type() {
        value.get::<u32>().ok().map(serde_json::Value::from)
    } else if t == f64::static_type() {
        value.get::<f64>().ok().map(serde_json::Value::from)
    } else if field_name == "caller-address" {
        // GInetSocketAddress object → "ip:port"
        use gio::prelude::*;
        let addr = value
            .get::<gio::SocketAddress>()
            .ok()?
            .downcast::<gio::InetSocketAddress>()
            .ok()?;
        let ip = addr.address().to_string();
        let port = addr.port();
        Some(serde_json::Value::from(format!("{}:{}", ip, port)))
    } else {
        None
    }
}

/// Walk the `callers` GValueArray-of-GstStructure in a stats structure.
fn extract_callers(
    stats: &gst::Structure,
) -> (i32, Vec<serde_json::Map<String, serde_json::Value>>) {
    use glib::translate::*;

    #[repr(C)]
    struct GValueArrayRepr {
        n_values: u32,
        values: *mut glib::gobject_ffi::GValue,
    }

    let Ok(callers_val) = stats.value("callers") else {
        return (0, Vec::new());
    };

    unsafe {
        let arr_ptr = glib::gobject_ffi::g_value_get_boxed(callers_val.to_glib_none().0)
            as *const GValueArrayRepr;
        if arr_ptr.is_null() {
            return (0, Vec::new());
        }
        let n = (*arr_ptr).n_values as usize;
        let mut out = Vec::with_capacity(n);

        for i in 0..n {
            let item = (*arr_ptr).values.add(i);
            let structure_ptr =
                glib::gobject_ffi::g_value_get_boxed(item) as *const gst::ffi::GstStructure;
            if structure_ptr.is_null() {
                continue;
            }
            let caller = gst::Structure::from_glib_none(structure_ptr);
            let mut obj = serde_json::Map::new();
            for idx in 0..caller.n_fields() {
                if let Some(name) = caller.nth_field_name(idx) {
                    if let Ok(value) = caller.value(name) {
                        if let Some(json) = caller_field_to_json(name, value) {
                            obj.insert(name.to_string(), json);
                        }
                    }
                }
            }
            out.push(obj);
        }
        (n as i32, out)
    }
}

/// C build_source_stats_json: fixed keys in fixed order + caller fallbacks.
pub fn build_source_stats(element: &gst::Element, tag: &str) -> SourceStats {
    let mut stats = empty_source_stats(tag);

    let Some(s) = stats_structure(element) else {
        return stats;
    };

    apply_source_stats_structure(&s, tag, &mut stats);
    stats
}

fn empty_source_stats(tag: &str) -> SourceStats {
    SourceStats {
        source: tag.to_string(),
        total_bytes_received: 0,
        bytes_received: 0,
        packets_received: 0,
        packets_received_lost: 0,
        packets_received_dropped: 0,
        packets_received_retransmitted: 0,
        rtt_ms: 0.0,
        receive_rate_mbps: 0.0,
        bandwidth_mbps: 0.0,
        negotiated_latency_ms: 0,
        connected_callers: 0,
        callers: Vec::new(),
    }
}

/// Map an srtsrc `stats` GstStructure onto `stats`. This is the step that looks
/// up GstStructure FIELD names — which are not the JSON wire keys.
fn apply_source_stats_structure(s: &gst::Structure, tag: &str, stats: &mut SourceStats) {
    // Diagnostic (BLACKGATE_DUMP_STATS=1): print the raw SRT structure once, with field
    // types. GStreamer's srtsrc stores the loss counters as `int` (gint32), which is why
    // the C engine's `gst_structure_get_int64` on them fails and always yields 0.
    if std::env::var("BLACKGATE_DUMP_STATS").is_ok()
        && STATS_DUMP_COUNT.fetch_add(1, Ordering::Relaxed) == 29
    {
        println!("STATS_STRUCT {}", s);
        println!(
            "STATS_RAW packets-received={} packets-received-lost={} packets-received-dropped={} packets-received-retransmitted={}",
            struct_get_i64(s, "packets-received"),
            struct_get_i64(s, "packets-received-lost"),
            struct_get_i64(s, "packets-received-dropped"),
            struct_get_i64(s, "packets-received-retransmitted")
        );
    }

    // GstStructure field on srtsrc is `bytes-received-total` (libgstsrt.so);
    // `total-bytes-received` is only the JSON wire key — lite reads the struct
    // and renames on emit. Reading the wire name here silently yielded 0.
    stats.total_bytes_received = struct_get_u64(s, "bytes-received-total");
    // C lite 217-239: bytes since the previous 1s report for this source slot.
    let slot = source_slot(tag);
    let prev = LAST_SOURCE_BYTES[slot].swap(stats.total_bytes_received, Ordering::Relaxed);
    let delta = stats.total_bytes_received.saturating_sub(prev) as i64;
    // lite build_source_stats_json emits the element's own per-report counter;
    // fall back to the total delta when the element does not expose it.
    let per_report = struct_get_i64(s, "bytes-received");
    stats.bytes_received = if per_report != 0 { per_report } else { delta };
    stats.packets_received = struct_get_i64(s, "packets-received");
    stats.packets_received_lost = struct_get_i64(s, "packets-received-lost");
    stats.packets_received_dropped = struct_get_i64(s, "packets-received-dropped");
    stats.packets_received_retransmitted = struct_get_i64(s, "packets-received-retransmitted");
    stats.rtt_ms = struct_get_f64(s, "rtt-ms");
    stats.receive_rate_mbps = struct_get_f64(s, "receive-rate-mbps");
    stats.bandwidth_mbps = struct_get_f64(s, "bandwidth-mbps");
    stats.negotiated_latency_ms = struct_get_i64(s, "negotiated-latency-ms") as i32;

    let (n, callers) = extract_callers(s);
    stats.connected_callers = n;
    stats.callers = callers;

    // C fallback: top-level listener stats zero → use caller max/sums
    if stats.rtt_ms <= 0.0 {
        let max_rtt = stats
            .callers
            .iter()
            .filter_map(|c| c.get("rtt-ms").and_then(|v| v.as_f64()))
            .fold(0.0f64, f64::max);
        if max_rtt > 0.0 {
            stats.rtt_ms = max_rtt;
        }
    }
    if stats.receive_rate_mbps <= 0.0 {
        let total: f64 = stats
            .callers
            .iter()
            .filter_map(|c| c.get("receive-rate-mbps").and_then(|v| v.as_f64()))
            .sum();
        if total > 0.0 {
            stats.receive_rate_mbps = total;
        }
    }
    if stats.bandwidth_mbps <= 0.0 {
        let total: f64 = stats
            .callers
            .iter()
            .filter_map(|c| c.get("bandwidth-mbps").and_then(|v| v.as_f64()))
            .sum();
        if total > 0.0 {
            stats.bandwidth_mbps = total;
        }
    }
}

/// C collect_sink_stats: fixed keys in fixed order.
pub fn build_sink_stats(element: &gst::Element, sink_index: i32) -> SinkStats {
    let mut out = SinkStats {
        sink_index,
        bytes_sent_total: 0,
        packets_sent: 0,
        packets_sent_lost: 0,
        packets_sent_dropped: 0,
        packets_sent_retransmitted: 0,
        bytes_received: 0,
        rtt_ms: 0.0,
        send_rate_mbps: 0.0,
        bandwidth_mbps: 0.0,
        negotiated_latency_ms: 0,
        connected_callers: 0,
        callers: Vec::new(),
    };

    let Some(s) = stats_structure(element) else {
        return out;
    };

    out.bytes_sent_total = struct_get_u64(&s, "bytes-sent-total");
    out.packets_sent = struct_get_i64(&s, "packets-sent");
    out.packets_sent_lost = struct_get_i64(&s, "packets-sent-lost");
    out.packets_sent_dropped = struct_get_i64(&s, "packets-sent-dropped");
    // GStreamer names this field `packets-retransmitted` (no `sent`); reading
    // `packets-sent-retransmitted` silently yielded 0 for every sink.
    let retransmitted = struct_get_i64(&s, "packets-retransmitted");
    out.packets_sent_retransmitted = if retransmitted != 0 {
        retransmitted
    } else {
        struct_get_i64(&s, "packets-sent-retransmitted")
    };
    out.bytes_received = struct_get_i64(&s, "bytes-received");
    out.rtt_ms = struct_get_f64(&s, "rtt-ms");
    out.send_rate_mbps = struct_get_f64(&s, "send-rate-mbps");
    out.bandwidth_mbps = struct_get_f64(&s, "bandwidth-mbps");
    out.negotiated_latency_ms = struct_get_i64(&s, "negotiated-latency-ms") as i32;

    let (n, callers) = extract_callers(&s);
    out.connected_callers = n;
    out.callers = callers;

    out
}

/// Attach video metadata fields to a serialized source-stats JSON object
/// (C print_stats: video-width/height/framerate/inferred/interlace-mode).
pub fn attach_video_info(value: &mut serde_json::Value, info: &VideoInfo) {
    let obj = match value.as_object_mut() {
        Some(o) => o,
        None => return,
    };
    obj.insert(
        "video-width".into(),
        serde_json::Value::from(info.width as i64),
    );
    obj.insert(
        "video-height".into(),
        serde_json::Value::from(info.height as i64),
    );
    obj.insert(
        "video-framerate-num".into(),
        serde_json::Value::from(info.fps_num as i64),
    );
    obj.insert(
        "video-framerate-den".into(),
        serde_json::Value::from(if info.fps_den == 0 { 1 } else { info.fps_den } as i64),
    );
    obj.insert(
        "video-framerate-inferred".into(),
        serde_json::Value::from(info.fps_inferred),
    );
    obj.insert(
        "video-interlace-mode".into(),
        serde_json::Value::from(if info.interlaced {
            "interleaved"
        } else {
            "progressive"
        }),
    );

    // Codec detail panel (C add_video_metadata_stats 285-299). Only emitted for
    // codecs the C engine names; unknown/mpeg2 emit the codec string alone.
    let codec_name = engine_metadata::codec_display_name(info.codec);
    if !codec_name.is_empty() {
        obj.insert("video-codec".into(), serde_json::Value::from(codec_name));
        let profile = match info.codec {
            engine_metadata::VideoCodec::H264 => {
                engine_metadata::h264_profile_name(info.profile_idc)
            }
            engine_metadata::VideoCodec::HEVC => engine_metadata::hevc_profile_name(
                info.profile_idc,
                info.chroma_format_idc,
                info.bit_depth,
            ),
            _ => "Unknown",
        };
        obj.insert("video-profile".into(), serde_json::Value::from(profile));
        obj.insert(
            "video-level-idc".into(),
            serde_json::Value::from(info.level_idc as i64),
        );
        obj.insert(
            "video-chroma-format".into(),
            serde_json::Value::from(engine_metadata::chroma_format_name(info.chroma_format_idc)),
        );
        obj.insert(
            "video-bit-depth".into(),
            serde_json::Value::from(info.bit_depth as i64),
        );
    }
    obj.insert(
        "video-sar-num".into(),
        serde_json::Value::from(if info.sar_num == 0 { 1 } else { info.sar_num } as i64),
    );
    obj.insert(
        "video-sar-den".into(),
        serde_json::Value::from(if info.sar_den == 0 { 1 } else { info.sar_den } as i64),
    );
    // Stream PIDs from the PMT (C add_mpegts_source_stats): video-pid only when
    // known, audio-pids always as an array.
    if info.video_pid > 0 {
        obj.insert(
            "video-pid".into(),
            serde_json::Value::from(info.video_pid as i64),
        );
    }
    obj.insert(
        "audio-pids".into(),
        serde_json::Value::from(
            info.audio_pids
                .iter()
                .map(|p| serde_json::Value::from(*p as i64))
                .collect::<Vec<_>>(),
        ),
    );
}

/// C print_stats sdi_video_stats array (primary only).
pub fn build_sdi_video_stats(
    sdi: &SdiState,
    vrate_elements: &[Option<gst::Element>; 8],
) -> Vec<SdiVideoStatsItem> {
    let modes = sdi
        .detected_mode
        .lock()
        .map(|m| m.clone())
        .unwrap_or_default();
    let mut out = Vec::new();
    for i in 0..8 {
        if let Some(vrate) = &vrate_elements[i] {
            let dropped = vrate.property::<u64>("drop");
            let duplicated = vrate.property::<u64>("duplicate");
            out.push(SdiVideoStatsItem {
                device_number: i as i32,
                dropped_frames: dropped,
                duplicated_frames: duplicated,
                video_frames: sdi.video_buffer_count[i].load(Ordering::Relaxed),
                audio_buffers: sdi.audio_buffer_count[i].load(Ordering::Relaxed),
                detected_mode: modes[i].clone(),
            });
        }
    }
    out
}

/// C SDI audio silence check — prints SDI_AUDIO_SILENT once per device until
/// recovery. Returns the devices that went silent (printed by caller for
/// testability).
pub fn check_sdi_audio_silence(sdi: &SdiState, now_us: i64) -> Vec<(i32, f64, i64)> {
    let mut silent = Vec::new();
    for i in 0..8usize {
        let last = sdi.audio_last_buffer_us[i].load(Ordering::Relaxed);
        if last == 0 {
            continue; // never received audio on this device
        }
        let silence_us = now_us - last;
        if silence_us > (SDI_AUDIO_HEALTH_INTERVAL_SEC * 1_000_000.0) as i64
            && !sdi.audio_silence_reported[i].load(Ordering::Relaxed)
        {
            sdi.audio_silence_reported[i].store(true, Ordering::Relaxed);
            silent.push((
                i as i32,
                silence_us as f64 / 1_000_000.0,
                sdi.audio_buffer_count[i].load(Ordering::Relaxed),
            ));
        }
    }
    silent
}

/// Socket handle shared across stats thread / bus watch / caller-connecting.
pub type SharedSocket = Arc<Mutex<UnixStream>>;

/// Send a JSON line over the socket (C send_json_to_socket: json + "\n").
/// Written in a single call so a socket chunk boundary can never split the
/// record: the reader is prefix-delimited, and an orphaned payload would be
/// parsed as the wrong message type.
pub fn send_json_line(socket: &SharedSocket, json: &str) {
    let mut record = Vec::with_capacity(json.len() + 1);
    record.extend_from_slice(json.as_bytes());
    record.push(b'\n');
    send_raw(socket, &record);
}

/// Send raw bytes over the socket (C send_message_to_unix_socket).
pub fn send_raw(socket: &SharedSocket, bytes: &[u8]) {
    if let Ok(mut s) = socket.lock() {
        let _ = s.write_all(bytes);
        let _ = s.flush();
    }
}

/// C print_stats thread: 1s loop → silence check → primary (+video fields,
/// +sdi_video_stats) → secondary (+video fields) → per-sink stats_sink: lines.
#[allow(clippy::too_many_arguments)]
pub fn start_stats_thread(
    socket: SharedSocket,
    source: gst::Element,
    sinks: Vec<gst::Element>,
    secondary: Option<gst::Element>,
    video_info: SharedVideoInfo,
    sdi: Arc<SdiState>,
    vrate_elements: Arc<Mutex<[Option<gst::Element>; 8]>>,
    running: Arc<AtomicBool>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        while running.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_secs(1));

            // SDI audio silence (stdout, C format)
            let now_us = monotonic_us();
            for (device, secs, buffers) in check_sdi_audio_silence(&sdi, now_us) {
                println!(
                    "SDI_AUDIO_SILENT: device={} no_audio_for={:.1}s total_buffers={}",
                    device, secs, buffers
                );
            }

            // Primary stats (+ metadata + sdi_video_stats)
            let primary = build_source_stats(&source, "primary");
            let mut value = serde_json::to_value(&primary).unwrap_or_default();
            if let Some(info) = video_info.lock().ok().and_then(|g| g.clone()) {
                attach_video_info(&mut value, &info);
            }
            let vrates = vrate_elements.lock().map(|g| g.clone()).unwrap_or_default();
            if let serde_json::Value::Object(ref mut obj) = value {
                let sdi_arr = build_sdi_video_stats(&sdi, &vrates);
                if let Ok(arr) = serde_json::to_value(&sdi_arr) {
                    obj.insert("sdi_video_stats".into(), arr);
                }
            }
            if let Ok(json) = serde_json::to_string(&value) {
                send_json_line(&socket, &json);
            }

            // Secondary stats (dual-ingest only; no sdi_video_stats)
            if let Some(sec) = &secondary {
                let sec_stats = build_source_stats(sec, "secondary");
                let mut sec_value = serde_json::to_value(&sec_stats).unwrap_or_default();
                if let Some(info) = video_info.lock().ok().and_then(|g| g.clone()) {
                    attach_video_info(&mut sec_value, &info);
                }
                if let Ok(json) = serde_json::to_string(&sec_value) {
                    send_json_line(&socket, &json);
                }
            }

            // Sink stats — one line per stored SRT sink, order primary→secondary→sinks
            for (i, sink) in sinks.iter().enumerate() {
                let s = build_sink_stats(sink, i as i32);
                if let Ok(json) = serde_json::to_string(&s) {
                    // Single write per record (same bytes as the C engine's
                    // prefix/payload/newline sends). Separate writes let a chunk
                    // boundary land between "stats_sink:" and its JSON, and the
                    // orphaned JSON was then parsed as source stats by the
                    // control plane, corrupting the source telemetry slot.
                    let mut record = Vec::with_capacity(11 + json.len() + 1);
                    record.extend_from_slice(b"stats_sink:");
                    record.extend_from_slice(json.as_bytes());
                    record.push(b'\n');
                    send_raw(&socket, &record);
                }
            }
        }
    })
}

fn monotonic_us() -> i64 {
    use std::time::Instant;
    static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    let start = START.get_or_init(Instant::now);
    start.elapsed().as_micros() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_without_stats_property_returns_zero_stats() {
        gst::init().unwrap();
        let source = gst::ElementFactory::make("fakesrc").build().unwrap();

        let stats = build_source_stats(&source, "primary");

        assert_eq!(stats.source, "primary");
        assert_eq!(stats.receive_rate_mbps, 0.0);
        assert_eq!(stats.packets_received, 0);
    }

    /// GstStructure FIELD names are not the JSON wire keys: the srtsrc struct
    /// exposes `bytes-received-total` / `bytes-received`, while the wire carries
    /// `total-bytes-received` / `bytes-received`. Reading the wire name out of
    /// the struct returned 0 forever, which stalled the control plane's
    /// "is data flowing?" fallback and its stall watchdog.
    #[test]
    fn source_stats_read_srt_struct_field_names() {
        gst::init().unwrap();
        let s = gst::Structure::builder("application/x-srt-statistics")
            .field("bytes-received-total", 4096u64)
            .field("bytes-received", 512i64)
            .field("packets-received", 10i64)
            .field("receive-rate-mbps", 8.0f64)
            .build();

        let mut stats = empty_source_stats("primary");
        apply_source_stats_structure(&s, "primary", &mut stats);

        assert_eq!(stats.total_bytes_received, 4096);
        assert_eq!(stats.bytes_received, 512);
        assert_eq!(stats.packets_received, 10);
        assert_eq!(stats.receive_rate_mbps, 8.0);

        // ...and the wire keeps the C key names.
        let v = serde_json::to_value(&stats).unwrap();
        assert_eq!(v["total-bytes-received"], 4096);
        assert_eq!(v["bytes-received"], 512);
    }

    fn source_stats_fixture() -> SourceStats {
        let mut caller = serde_json::Map::new();
        caller.insert(
            "caller-address".to_string(),
            serde_json::Value::from("192.168.1.50:5555"),
        );
        caller.insert("rtt-ms".to_string(), serde_json::Value::from(42.5));
        caller.insert(
            "receive-rate-mbps".to_string(),
            serde_json::Value::from(8.0),
        );
        SourceStats {
            source: "primary".into(),
            total_bytes_received: 123456789,
            bytes_received: 0,
            packets_received: 1000,
            packets_received_lost: 10,
            packets_received_dropped: 5,
            packets_received_retransmitted: 3,
            rtt_ms: 42.5,
            receive_rate_mbps: 8.0,
            bandwidth_mbps: 12.5,
            negotiated_latency_ms: 120,
            connected_callers: 1,
            callers: vec![caller],
        }
    }

    /// Golden key ORDER — must match C build_source_stats_json exactly.
    #[test]
    fn source_stats_key_order_matches_c() {
        let json = serde_json::to_string(&source_stats_fixture()).unwrap();
        let expected_keys = [
            "source",
            "total-bytes-received",
            "bytes-received",
            "packets-received",
            "packets-received-lost",
            "packets-received-dropped",
            "packets-received-retransmitted",
            "rtt-ms",
            "receive-rate-mbps",
            "bandwidth-mbps",
            "negotiated-latency-ms",
            "connected-callers",
            "callers",
        ];
        let mut last_pos = 0usize;
        for key in expected_keys {
            let pat = format!("\"{}\":", key);
            let pos = json
                .find(&pat)
                .unwrap_or_else(|| panic!("key {} missing in {}", key, json));
            assert!(pos > last_pos, "key {} out of order in {}", key, json);
            last_pos = pos;
        }
    }

    /// The two keys Elixir route_health.ex depends on for loss math.
    #[test]
    fn elixir_loss_keys_present() {
        let v: serde_json::Value = serde_json::to_value(source_stats_fixture()).unwrap();
        assert!(v.get("packets-received").is_some());
        assert!(v.get("packets-received-lost").is_some());
        assert!(v.get("receive-rate-mbps").is_some());
        assert!(v.get("callers").is_some());
        assert!(v.get("connected-callers").is_some());
        // Keys the old Rust format emitted must NOT exist (silent-zero bug)
        assert!(v.get("packets-lost").is_none());
        assert!(v.get("stream-id").is_none());
        assert!(v.get("packets-retransmitted").is_none());
        // But `bytes-received` is REQUIRED: blackgate-lite emits it and
        // route_controller.ex:31 uses it as the "is data flowing?" fallback.
        assert!(v.get("bytes-received").is_some());
    }

    /// lite's bytes-received is a per-report delta, not the running total.
    #[test]
    fn source_bytes_received_is_a_delta() {
        let mut a = source_stats_fixture();
        a.total_bytes_received = 1_000;
        let mut b = a.clone();
        b.total_bytes_received = 1_750;
        assert_eq!(
            b.total_bytes_received
                .saturating_sub(a.total_bytes_received),
            750
        );
        // The delta is carried on the wire, so the key must serialize.
        let v = serde_json::to_value(&a).unwrap();
        assert!(v.get("bytes-received").is_some());
        assert_eq!(v["bytes-received"], 0_i64);
    }

    #[test]
    fn sink_stats_key_order_matches_c() {
        let s = SinkStats {
            sink_index: 2,
            bytes_sent_total: 999,
            packets_sent: 100,
            packets_sent_lost: 1,
            packets_sent_dropped: 0,
            packets_sent_retransmitted: 2,
            bytes_received: 4,
            rtt_ms: 5.0,
            send_rate_mbps: 6.0,
            bandwidth_mbps: 7.0,
            negotiated_latency_ms: 90,
            connected_callers: 1,
            callers: vec![],
        };
        let json = serde_json::to_string(&s).unwrap();
        assert!(json.starts_with(concat!(
            r#"{"sink-index":2,"bytes-sent-total":999,"packets-sent":100,"#,
            r#""packets-sent-lost":1,"packets-sent-dropped":0,"#,
            r#""packets-sent-retransmitted":2,"bytes-received":4,"#,
            r#""rtt-ms":5.0,"send-rate-mbps":6.0,"bandwidth-mbps":7.0,"#,
            r#""negotiated-latency-ms":90,"connected-callers":1,"callers":[]}"#
        )));
    }

    #[test]
    fn attach_video_info_appends_c_fields() {
        let mut v = serde_json::to_value(source_stats_fixture()).unwrap();
        let info = VideoInfo {
            width: 1920,
            height: 1080,
            fps_num: 25,
            fps_den: 1,
            interlaced: true,
            codec: engine_metadata::VideoCodec::H264,
            profile_idc: 100,
            level_idc: 41,
            chroma_format_idc: 1,
            bit_depth: 8,
            sar_num: 1,
            sar_den: 1,
            fps_inferred: false,
            video_pid: 256,
            audio_pids: vec![257],
        };
        attach_video_info(&mut v, &info);
        assert_eq!(v["video-width"], 1920);
        assert_eq!(v["video-height"], 1080);
        assert_eq!(v["video-framerate-num"], 25);
        assert_eq!(v["video-framerate-den"], 1);
        assert_eq!(v["video-interlace-mode"], "interleaved");
        // Blackgate-lite codec detail panel (C add_video_metadata_stats).
        assert_eq!(v["video-codec"], "AVC/H.264");
        assert_eq!(v["video-profile"], "High");
        assert_eq!(v["video-level-idc"], 41);
        assert_eq!(v["video-chroma-format"], "4:2:0");
        assert_eq!(v["video-bit-depth"], 8);
        assert_eq!(v["video-sar-num"], 1);
        assert_eq!(v["video-sar-den"], 1);
        // PMT stream PIDs (C add_mpegts_source_stats).
        assert_eq!(v["video-pid"], 256);
        assert_eq!(v["audio-pids"][0], 257);
    }

    #[test]
    fn hevc_profile_and_chroma_names_match_c() {
        use engine_metadata::{chroma_format_name, h264_profile_name, hevc_profile_name};
        assert_eq!(h264_profile_name(100), "High");
        assert_eq!(h264_profile_name(66), "Baseline");
        assert_eq!(chroma_format_name(1), "4:2:0");
        assert_eq!(chroma_format_name(2), "4:2:2");
        // Chroma/depth win over the raw idc, as in C hevc_profile_name().
        assert_eq!(hevc_profile_name(1, 2, 10), "Main 4:2:2 10");
        assert_eq!(hevc_profile_name(1, 2, 8), "Main 4:2:2");
        assert_eq!(hevc_profile_name(1, 1, 10), "Main 10");
        assert_eq!(hevc_profile_name(1, 1, 8), "Main");
    }

    #[test]
    fn silence_check_reports_once_then_latches() {
        let sdi = SdiState::new_shared();
        let now = 20_000_000i64; // 20s monotonic
                                 // device 0 saw audio at t=0 → silent after 10s
        sdi.audio_last_buffer_us[0].store(1, Ordering::Relaxed);
        sdi.audio_buffer_count[0].store(500, Ordering::Relaxed);

        let first = check_sdi_audio_silence(&sdi, now);
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].0, 0);
        assert!(first[0].1 >= 10.0);

        // Second check → latched, no repeat
        let second = check_sdi_audio_silence(&sdi, now + 1_000_000);
        assert!(second.is_empty());
    }
}
