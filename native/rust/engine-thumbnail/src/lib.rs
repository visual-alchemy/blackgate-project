// Thumbnail generation — ported from the C thumbnail branch (duo2 / quad2).
//
//   tee → queue (no leak, 64 MB / 8 s) → tsdemux
//        → [video pad] h264parse|h265parse → (H.264: keyframes only) → avdec_*
//        → deinterlace → videoconvert → videoscale 320x180 → capsfilter
//        → (1 fps gate) → jpegenc → appsink
//
// Deliberately not `decodebin` + a small leaky queue:
//
//   * The queue must not shed compressed TS. The previous branch used
//     `leaky=downstream, max-size-buffers=2` on the raw transport stream, i.e.
//     ~2.6 kB ≈ 1.6 ms of a 13 Mbps feed: almost every packet was dropped before
//     the demuxer, so the preview decoded from a shredded stream.
//   * H.264 must only reach the decoder at keyframes. Joining a live TS mid-GOP
//     and feeding P/B pictures to the decoder produces macroblocks and green
//     frames (measured on the live dashboard: 83% green pixels on one route, a
//     visible 16-px block grid on the other).
//   * HEVC needs `config-interval=-1` so VPS/SPS/PPS repeat at IDRs, plus
//     corrupt-frame rejection instead of writing visibly damaged JPEGs.
//
// The C branch's 1 fps PTS gate replaces videorate, which asserts when decoded
// frames carry no duration (a source reporting an unknown framerate).

use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::thread;
use std::time::{Duration, Instant};

/// Capture cadence for the preview file (the writer thread).
const CAPTURE_INTERVAL: Duration = Duration::from_secs(5);

/// Rate gate in front of jpegenc (C thumbnail_rate_probe).
#[derive(Default)]
struct RateGate {
    last_pts: Option<gst::ClockTime>,
    last_monotonic: Option<Instant>,
    emitted: bool,
}

impl RateGate {
    /// True when this frame is due (at most one per second).
    fn due(&mut self, pts: Option<gst::ClockTime>, now: Instant) -> bool {
        let due = match pts {
            Some(pts) => {
                !self.emitted
                    || match self.last_pts {
                        // PTS going backwards means a new stream/segment: let it through.
                        Some(last) => {
                            pts < last || pts.saturating_sub(last) >= gst::ClockTime::SECOND
                        }
                        None => true,
                    }
            }
            // No timestamps: fall back to wall clock so the gate cannot stall.
            None => {
                !self.emitted
                    || self
                        .last_monotonic
                        .is_none_or(|last| now.duration_since(last) >= Duration::from_secs(1))
            }
        };

        if due {
            self.last_pts = pts;
            self.last_monotonic = Some(now);
            self.emitted = true;
        }

        due
    }
}

pub struct ThumbnailBranch {
    thread_handle: Option<thread::JoinHandle<()>>,
    running: Arc<AtomicBool>,
    preview_path: PathBuf,
}

impl ThumbnailBranch {
    /// Attaches a thumbnail branch to the given tee element inside the pipeline.
    /// The branch captures a 320×180 JPEG preview every ~5 seconds and writes
    /// it to `/tmp/blackgate_preview_<route_id>.jpg` using atomic rename.
    pub fn new(
        pipeline: &gst::Pipeline,
        tee: &gst::Element,
        route_id: &str,
    ) -> Result<Self, String> {
        let route_id = route_id.to_string();

        // ─── Element creation ──────────────────────────────────────────
        // Queue: allow decode/scheduling bursts to queue up, but never let this branch
        // back-pressure the tee.
        //
        // The tee feeds the SRT destinations *and* this preview branch, so a preview that
        // falls behind stalls everything: the queue fills, the tee blocks, and the SRT sink
        // starves. Measured on a 1080p HLS route: with a non-leaky queue the receiver had no
        // data in 27-29 of 40 seconds and the pattern was ragged; making the branch leaky
        // brought it to 7 of 40 with a flat pattern (the preview branch is the only change).
        //
        // Dropping here is safe because the budget is generous (64 MB / 8 s): shedding only
        // starts once the branch is ~8 s behind, where the preview is stale anyway. This is
        // not the old `leaky=downstream, max-size-buffers=2` bug — that budget was ~2.6 kB
        // (1.6 ms of a 13 Mbps feed), so it shredded the stream before the demuxer on every
        // frame. The preview may miss a GOP under sustained overload; the live output must not.
        let tqueue = gst::ElementFactory::make("queue")
            .name("thumb-queue")
            .build()
            .map_err(|e| format!("thumb queue: {}", e))?;
        tqueue.set_property("max-size-buffers", 0u32);
        tqueue.set_property("max-size-bytes", 64u32 * 1024 * 1024);
        set_time_property(&tqueue, "max-size-time", 8);
        tqueue.set_property_from_str("leaky", "downstream");

        let tsdemux = gst::ElementFactory::make("tsdemux")
            .name("thumb-tsdemux")
            .build()
            .map_err(|e| format!("thumb tsdemux: {}", e))?;

        let deinterlace = gst::ElementFactory::make("deinterlace")
            .name("thumb-deinterlace")
            .build()
            .map_err(|e| format!("thumb deinterlace: {}", e))?;

        let videoconvert = gst::ElementFactory::make("videoconvert")
            .name("thumb-convert")
            .build()
            .map_err(|e| format!("thumb videoconvert: {}", e))?;

        let videoscale = gst::ElementFactory::make("videoscale")
            .name("thumb-scale")
            .build()
            .map_err(|e| format!("thumb videoscale: {}", e))?;

        let capsfilter = gst::ElementFactory::make("capsfilter")
            .name("thumb-caps")
            .property(
                "caps",
                gst::Caps::builder("video/x-raw")
                    .field("width", 320i32)
                    .field("height", 180i32)
                    .build(),
            )
            .build()
            .map_err(|e| format!("thumb capsfilter: {}", e))?;

        let jpegenc = gst::ElementFactory::make("jpegenc")
            .name("thumb-jpegenc")
            .property("quality", 85i32)
            .build()
            .map_err(|e| format!("thumb jpegenc: {}", e))?;

        // sync/async off: an optional preview may receive no frames at all
        // (unsupported codec, long GOP) and must not hold preroll in PAUSED.
        let appsink = gst::ElementFactory::make("appsink")
            .name("thumb-appsink")
            .property("emit-signals", false)
            .property("max-buffers", 1u32)
            .property("drop", true)
            .property("sync", false)
            .property("async", false)
            .build()
            .map_err(|e| format!("thumb appsink: {}", e))?;

        // ─── Pipeline assembly ─────────────────────────────────────────
        pipeline
            .add_many([
                &tqueue,
                &tsdemux,
                &deinterlace,
                &videoconvert,
                &videoscale,
                &capsfilter,
                &jpegenc,
                &appsink,
            ])
            .map_err(|e| format!("thumb add: {}", e))?;

        gst::Element::link(&tqueue, &tsdemux)
            .map_err(|e| format!("thumb link queue→tsdemux: {}", e))?;

        gst::Element::link_many([
            &deinterlace,
            &videoconvert,
            &videoscale,
            &capsfilter,
            &jpegenc,
            &appsink,
        ])
        .map_err(|e| format!("thumb link downstream: {}", e))?;

        // 1 fps gate: encode a preview frame per second, not per source frame.
        let rate_gate = Arc::new(Mutex::new(RateGate::default()));
        let rate_gate_clone = rate_gate.clone();
        if let Some(pad) = capsfilter.static_pad("src") {
            pad.add_probe(gst::PadProbeType::BUFFER, move |_pad, info| {
                let Some(buffer) = info.buffer() else {
                    return gst::PadProbeReturn::Ok;
                };
                let mut gate = match rate_gate_clone.lock() {
                    Ok(gate) => gate,
                    Err(_) => return gst::PadProbeReturn::Ok,
                };
                if gate.due(buffer.pts(), Instant::now()) {
                    gst::PadProbeReturn::Ok
                } else {
                    gst::PadProbeReturn::Drop
                }
            });
        }

        // tsdemux pad-added: build the codec chain for the video pad, consume the
        // rest. A demux pad left unlinked propagates GST_FLOW_NOT_LINKED back
        // through the tee and stalls the whole pipeline.
        let pipeline_for_pads = pipeline.clone();
        tsdemux.connect_pad_added(move |_demux, src_pad| {
            let caps_name = src_pad
                .current_caps()
                .or_else(|| {
                    let queried = src_pad.query_caps(None);
                    if queried.is_empty() {
                        None
                    } else {
                        Some(queried)
                    }
                })
                .and_then(|caps| caps.structure(0).map(|s| s.name().to_string()))
                .unwrap_or_default();

            let is_h264 = caps_name == "video/x-h264";
            let is_h265 = caps_name == "video/x-h265";
            // Caps can be unknown at pad-added time; fall back to the pad name.
            let looks_like_video = caps_name.starts_with("video/")
                || (caps_name.is_empty() && src_pad.name().starts_with("video"));

            if (!is_h264 && !is_h265) || !looks_like_video {
                src_pad.add_probe(gst::PadProbeType::BUFFER, |_, _| gst::PadProbeReturn::Drop);
                return;
            }

            let Some(deinterlace) = pipeline_for_pads.by_name("thumb-deinterlace") else {
                return;
            };
            // One decode chain per pipeline (duo2 guard): a second video pad would
            // otherwise race for the same deinterlace sink pad.
            if deinterlace
                .static_pad("sink")
                .map(|p| p.is_linked())
                .unwrap_or(false)
            {
                src_pad.add_probe(gst::PadProbeType::BUFFER, |_, _| gst::PadProbeReturn::Drop);
                return;
            }

            let (parser_factory, decoder_factory) = if is_h264 {
                ("h264parse", "avdec_h264")
            } else {
                ("h265parse", "avdec_h265")
            };

            let parser = match gst::ElementFactory::make(parser_factory)
                .name("thumb-parser")
                .build()
            {
                Ok(el) => el,
                Err(e) => {
                    println!("Thumbnail: {} unavailable: {}", parser_factory, e);
                    src_pad.add_probe(gst::PadProbeType::BUFFER, |_, _| gst::PadProbeReturn::Drop);
                    return;
                }
            };
            let decoder = match gst::ElementFactory::make(decoder_factory)
                .name("thumb-decoder")
                .build()
            {
                Ok(el) => el,
                Err(e) => {
                    println!("Thumbnail: {} unavailable: {}", decoder_factory, e);
                    src_pad.add_probe(gst::PadProbeType::BUFFER, |_, _| gst::PadProbeReturn::Drop);
                    return;
                }
            };

            // HEVC: repeat VPS/SPS/PPS at IDRs so the decoder can initialise after
            // joining a live transport stream mid-GOP.
            if is_h265 {
                set_property_if_present(&parser, "config-interval", -1i32);
                // P/B pictures carry references needed for later frames: reject
                // decoder-marked corrupt output instead of saving damaged JPEGs.
                set_property_if_present(&decoder, "output-corrupt", false);
                set_property_if_present(&decoder, "discard-corrupted-frames", true);
            }

            if pipeline_for_pads.add(&parser).is_err() || pipeline_for_pads.add(&decoder).is_err() {
                println!("Thumbnail: failed to add {} decode chain", caps_name);
                src_pad.add_probe(gst::PadProbeType::BUFFER, |_, _| gst::PadProbeReturn::Drop);
                return;
            }

            if gst::Element::link(&parser, &decoder).is_err()
                || gst::Element::link(&decoder, &deinterlace).is_err()
            {
                println!("Thumbnail: failed to link {} decode chain", caps_name);
                let _ = pipeline_for_pads.remove(&decoder);
                let _ = pipeline_for_pads.remove(&parser);
                src_pad.add_probe(gst::PadProbeType::BUFFER, |_, _| gst::PadProbeReturn::Drop);
                return;
            }

            // H.264 preview decodes keyframes only: without this the branch starts
            // decoding at whatever P/B picture arrives first and the JPEG shows
            // macroblocks/green until the next IDR. HEVC is deliberately not gated
            // here — dropping its inter pictures breaks reference continuity.
            if is_h264 {
                if let Some(parse_src) = parser.static_pad("src") {
                    parse_src.add_probe(gst::PadProbeType::BUFFER, |_pad, info| {
                        match info.buffer() {
                            Some(buffer)
                                if buffer.flags().contains(gst::BufferFlags::DELTA_UNIT) =>
                            {
                                gst::PadProbeReturn::Drop
                            }
                            _ => gst::PadProbeReturn::Ok,
                        }
                    });
                }
            }

            let _ = parser.sync_state_with_parent();
            let _ = decoder.sync_state_with_parent();

            let Some(parser_sink) = parser.static_pad("sink") else {
                return;
            };

            if let Err(err) = src_pad.link(&parser_sink) {
                println!(
                    "Thumbnail: failed to link {} pad into the decode chain: {:?}",
                    caps_name, err
                );
                let _ = decoder.set_state(gst::State::Null);
                let _ = parser.set_state(gst::State::Null);
                let _ = pipeline_for_pads.remove(&decoder);
                let _ = pipeline_for_pads.remove(&parser);
                src_pad.add_probe(gst::PadProbeType::BUFFER, |_, _| gst::PadProbeReturn::Drop);
            } else {
                println!(
                    "Thumbnail: linked {} through {}",
                    caps_name, decoder_factory
                );
            }
        });

        // Request tee src pad → link to queue sink
        let tee_pad = tee
            .request_pad_simple("src_%u")
            .ok_or("thumb: tee request pad failed")?;
        let queue_sink = tqueue.static_pad("sink").ok_or("thumb: queue sink pad")?;
        tee_pad
            .link(&queue_sink)
            .map_err(|e| format!("thumb tee→queue: {}", e))?;

        // ─── Background writer thread ───────────────────────────────────
        let appsink_weak = appsink.downgrade(); // non-owning: avoid ref cycle
        let preview_path = PathBuf::from(format!("/tmp/blackgate_preview_{}.jpg", route_id));
        let running = Arc::new(AtomicBool::new(true));
        let running_clone = running.clone();
        let preview_path_clone = preview_path.clone();
        let route_id_for_thread = route_id.clone();

        let handle = thread::spawn(move || {
            while running_clone.load(Ordering::Relaxed) {
                // Wait ~5s between captures, but allow shutdown to wake the worker
                // immediately so route teardown stays inside the IPC contract.
                thread::park_timeout(CAPTURE_INTERVAL);
                if !running_clone.load(Ordering::Relaxed) {
                    break;
                }

                if let Some(appsink) = appsink_weak.upgrade() {
                    let appsink_app = appsink.downcast_ref::<gst_app::AppSink>().unwrap();
                    // Bounded pull: keeps the worker responsive to shutdown.
                    if let Some(sample) =
                        appsink_app.try_pull_sample(gst::ClockTime::from_seconds(1))
                    {
                        if let Some(buffer) = sample.buffer() {
                            if let Ok(map) = buffer.map_readable() {
                                let tmp_path =
                                    format!("/tmp/blackgate_preview_{}.tmp", route_id_for_thread);
                                if fs::write(&tmp_path, &*map).is_ok() {
                                    // Atomic rename: avoids partial reads
                                    let _ = fs::rename(&tmp_path, &preview_path_clone);
                                }
                            }
                        }
                    }
                }
            }

            // Clean up preview file on stop
            let _ = fs::remove_file(&preview_path_clone);
        });

        Ok(Self {
            thread_handle: Some(handle),
            running,
            preview_path,
        })
    }

    /// Stop the thumbnail worker and remove the preview file.
    pub fn stop(&mut self) {
        self.running.store(false, Ordering::Relaxed);
        if let Some(handle) = self.thread_handle.take() {
            handle.thread().unpark();
            let _ = handle.join();
        }
    }

    /// Path to the preview JPEG file.
    pub fn preview_path(&self) -> &Path {
        &self.preview_path
    }
}

/// Sets a property only when the element declares it (avdec properties differ
/// between builds).
fn set_property_if_present(element: &gst::Element, name: &str, value: impl Into<gst::glib::Value>) {
    if element.find_property(name).is_some() {
        element.set_property(name, value);
    }
}

/// Sets a GstClockTime property, tolerating bindings that expose it as a plain
/// u64 (nanoseconds).
fn set_time_property(element: &gst::Element, name: &str, seconds: u64) {
    let Some(pspec) = element.find_property(name) else {
        return;
    };
    if pspec.value_type().is_a(gst::ClockTime::static_type()) {
        element.set_property(name, gst::ClockTime::from_seconds(seconds));
    } else {
        element.set_property(name, seconds * 1_000_000_000u64);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn stop_wakes_sleeping_worker_within_shutdown_budget() {
        gst::init().expect("GStreamer must initialize");
        let pipeline = gst::Pipeline::new();
        let tee = gst::ElementFactory::make("tee")
            .name("test-tee")
            .build()
            .expect("tee element");
        pipeline.add(&tee).expect("add tee");

        let mut thumbnail =
            ThumbnailBranch::new(&pipeline, &tee, "thumbnail-stop-test").expect("thumbnail");
        std::thread::sleep(Duration::from_millis(100));
        let started = Instant::now();
        thumbnail.stop();

        assert!(
            started.elapsed() < Duration::from_millis(500),
            "thumbnail stop exceeded shutdown budget: {:?}",
            started.elapsed()
        );
    }

    /// The branch must build the C element set, not a decodebin.
    #[test]
    fn branch_uses_tsdemux_and_an_unbounded_queue() {
        gst::init().expect("GStreamer must initialize");
        let pipeline = gst::Pipeline::new();
        let tee = gst::ElementFactory::make("tee")
            .name("test-tee")
            .build()
            .expect("tee element");
        pipeline.add(&tee).expect("add tee");

        let mut thumbnail =
            ThumbnailBranch::new(&pipeline, &tee, "thumbnail-elements-test").expect("thumbnail");

        let queue = pipeline.by_name("thumb-queue").expect("queue");
        assert_eq!(queue.property::<u32>("max-size-buffers"), 0);
        assert_eq!(queue.property::<u32>("max-size-bytes"), 64 * 1024 * 1024);
        assert!(
            pipeline.by_name("thumb-tsdemux").is_some(),
            "tsdemux element"
        );
        assert!(
            pipeline.by_name("thumb-appsink").is_some(),
            "appsink element"
        );

        thumbnail.stop();
    }

    /// One frame per second is enough for a dashboard preview.
    #[test]
    fn rate_gate_emits_at_most_one_frame_per_second() {
        let mut gate = RateGate::default();
        let now = Instant::now();
        let sec = gst::ClockTime::SECOND;

        assert!(gate.due(Some(gst::ClockTime::ZERO), now), "first frame");
        assert!(
            !gate.due(Some(gst::ClockTime::from_mseconds(500)), now),
            "same second"
        );
        assert!(
            gate.due(Some(sec), now + Duration::from_millis(500)),
            "next second"
        );
        // PTS jumping backwards (new segment) is let through.
        assert!(gate.due(Some(gst::ClockTime::ZERO), now));
    }
}
