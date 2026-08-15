// Bus watch — C bus_callback parity.
//
// WARNING  → stdout "Pipeline Warning from <name>: <msg>"
//            decoder/demuxer sources → warning JSON over socket
//            source/secondary_source → SOURCE_INVALID:<tag> <msg>
// ERROR    → stdout "Error: <msg>" + quit main loop
// STATE_CHANGED (pipeline only) → stdout "Pipeline state changed from X to Y"
// ELEMENT  → GstSRTObject → "SRT Event: <structure>"
//            connection-removed → SOURCE_INVALID:<primary|secondary>

use gstreamer as gst;
use gst::prelude::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use engine_stats::SharedSocket;

fn state_name(state: gst::State) -> &'static str {
    match state {
        gst::State::VoidPending => "VOID_PENDING",
        gst::State::Null => "NULL",
        gst::State::Ready => "READY",
        gst::State::Paused => "PAUSED",
        gst::State::Playing => "PLAYING",
    }
}

fn is_decoder_element(name: &str) -> bool {
    name.starts_with("avdec")
        || name.starts_with("va")
        || name.starts_with("decodebin")
        || name.starts_with("tsdemux")
}

/// Runs the bus loop on the calling thread. Returns when the pipeline should
/// shut down (EOS, ERROR, or the stop flag). C parity: ERROR quits the run
/// loop; the caller then runs cleanup and exits.
pub fn run_bus_watch(
    pipeline: &gst::Pipeline,
    socket: SharedSocket,
    route_id: &str,
    stop: Arc<AtomicBool>,
) {
    let Some(bus) = pipeline.bus() else {
        return;
    };

    loop {
        if stop.load(Ordering::Relaxed) {
            return;
        }
        let msg = bus.timed_pop(gst::ClockTime::from_seconds(1));
        let Some(msg) = msg else {
            continue;
        };
        match msg.view() {
            gst::MessageView::Eos(_) => {
                return;
            }
            gst::MessageView::Error(err) => {
                println!("Error: {}", err.error());
                return;
            }
            gst::MessageView::Warning(warn) => {
                let src_name = msg
                    .src()
                    .map(|s| s.name().to_string())
                    .unwrap_or_default();
                let message = warn.error().message().to_string();
                println!("Pipeline Warning from {}: {}", src_name, message);

                if is_decoder_element(&src_name) {
                    let json = serde_json::json!({
                        "type": "warning",
                        "route_id": route_id,
                        "element": src_name,
                        "message": message,
                    })
                    .to_string();
                    engine_stats::send_raw(&socket, json.as_bytes());
                    engine_stats::send_raw(&socket, b"\n");
                }

                match src_name.as_str() {
                    "secondary_source" => {
                        println!("SOURCE_INVALID:secondary {}", message);
                    }
                    "source" => {
                        println!("SOURCE_INVALID:primary {}", message);
                    }
                    _ => {}
                }
            }
            gst::MessageView::StateChanged(s) => {
                if let Some(src) = msg.src() {
                    if *src == *pipeline.upcast_ref::<gst::Object>() {
                        println!(
                            "Pipeline state changed from {} to {}",
                            state_name(s.old()),
                            state_name(s.current())
                        );
                    }
                }
            }
            gst::MessageView::Element(el) => {
                if let Some(s) = el.structure() {
                    if s.name() == "GstSRTObject" {
                        println!("SRT Event: {}", s.to_string());
                    } else if s.name() == "connection-removed" {
                        let src_name = msg
                            .src()
                            .map(|s| s.name().to_string())
                            .unwrap_or_default();
                        let tag = if src_name == "secondary_source" {
                            "secondary"
                        } else {
                            "primary"
                        };
                        println!("SOURCE_INVALID:{}", tag);
                    }
                }
            }
            _ => {}
        }
    }
}
