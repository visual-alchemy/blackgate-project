// Thumbnail generation — ported from native/src/thumbnail_worker.c
//
// Builds a GStreamer thumbnail branch: tee → queue → decodebin → videoconvert
// → videoscale(320x180) → jpegenc → appsink. A background thread pulls JPEG
// frames every ~5s and writes to /tmp/blackgate_preview_<route_id>.jpg with
// atomic rename.

use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::thread;
use std::time::Duration;

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
        let tqueue = gst::ElementFactory::make("queue")
            .name("thumb-queue")
            .property_from_str("leaky", "downstream")
            .property("max-size-buffers", 2u32)
            .build()
            .map_err(|e| format!("thumb queue: {}", e))?;

        let decodebin = gst::ElementFactory::make("decodebin")
            .name("thumb-decodebin")
            .build()
            .map_err(|e| format!("thumb decodebin: {}", e))?;

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

        let appsink = gst::ElementFactory::make("appsink")
            .name("thumb-appsink")
            .property("emit-signals", true)
            .property("max-buffers", 1u32)
            .property("drop", true)
            .build()
            .map_err(|e| format!("thumb appsink: {}", e))?;

        // ─── Pipeline assembly ─────────────────────────────────────────
        pipeline
            .add_many([
                &tqueue,
                &decodebin,
                &videoconvert,
                &videoscale,
                &capsfilter,
                &jpegenc,
                &appsink,
            ])
            .map_err(|e| format!("thumb add: {}", e))?;

        gst::Element::link(&tqueue, &decodebin)
            .map_err(|e| format!("thumb link queue→decodebin: {}", e))?;

        gst::Element::link_many([&videoconvert, &videoscale, &capsfilter, &jpegenc, &appsink])
            .map_err(|e| format!("thumb link downstream: {}", e))?;

        // decodebin pad-added → link to videoconvert
        let pipeline_clone = pipeline.clone();
        decodebin.connect_pad_added(move |_db, src_pad| {
            let caps = src_pad
                .current_caps()
                .or_else(|| Some(src_pad.query_caps(None)));
            if let Some(caps) = caps {
                let name = caps
                    .structure(0)
                    .map(|s| s.name().to_string())
                    .unwrap_or_default();
                if name.starts_with("video/") {
                    if let Some(convert) = pipeline_clone.by_name("thumb-convert") {
                        let sink_pad = convert.static_pad("sink").unwrap();
                        if !sink_pad.is_linked() {
                            src_pad.link(&sink_pad).ok();
                        }
                    }
                }
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

        let handle = thread::spawn(move || {
            while running_clone.load(Ordering::Relaxed) {
                // Wait ~5s between captures, but allow shutdown to wake the
                // worker immediately so route teardown stays within the IPC
                // contract's two-second budget.
                thread::park_timeout(Duration::from_secs(5));
                if !running_clone.load(Ordering::Relaxed) {
                    break;
                }

                if let Some(appsink) = appsink_weak.upgrade() {
                    let appsink_app = appsink.downcast_ref::<gst_app::AppSink>().unwrap();
                    if let Ok(sample) = appsink_app.pull_sample() {
                        if let Some(buffer) = sample.buffer() {
                            if let Ok(map) = buffer.map_readable() {
                                let tmp_path = format!("/tmp/blackgate_preview_{}.tmp", route_id);
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
}
