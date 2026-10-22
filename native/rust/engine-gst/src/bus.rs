// Bus watch — C bus_callback parity.
//
// WARNING  → stdout "Pipeline Warning from <name>: <msg>"
//            decoder/demuxer sources → warning JSON over socket
//            source/secondary_source → SOURCE_INVALID:<tag> <msg>
// ERROR    → stdout "Error: <msg>" + "Error detail: element=… ancestry=…" + "Error debug: …"
//            then quit main loop
// STATE_CHANGED (pipeline only) → stdout "Pipeline state changed from X to Y"
// ELEMENT  → GstSRTObject → "SRT Event: <structure>"
//            connection-removed → SOURCE_INVALID:<primary|secondary>

use gst::prelude::*;
use gstreamer as gst;
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

/// Element name of a message source, falling back to the plain GstObject name.
fn element_name(obj: Option<&gst::Object>) -> String {
    if let Some(element) = obj.and_then(|o| o.downcast_ref::<gst::Element>()) {
        return element.name().to_string();
    }

    obj.map(|o| o.name().to_string())
        .unwrap_or_else(|| "unknown".to_string())
}

/// Element and its ancestors, innermost first: `<element < parent < … < pipeline>`.
///
/// An error only ever said "Internal data stream error", which does not say which chain failed —
/// on a route with several branches that is the difference between an hour of guessing and a
/// one-line answer.
fn ancestry_names(obj: Option<&gst::Object>) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    let mut current = obj.cloned();

    while let Some(item) = current {
        names.push(item.name().to_string());
        current = item.parent();
    }

    names
}

fn element_ancestry(obj: Option<&gst::Object>) -> String {
    let names = ancestry_names(obj);

    if names.is_empty() {
        "-".to_string()
    } else {
        names.join(" < ")
    }
}

/// The line printed under "Error: <msg>". Kept as a function so a test can assert its shape
/// without capturing stdout.
fn error_detail_line(obj: Option<&gst::Object>) -> String {
    format!(
        "Error detail: element={} ancestry={}",
        element_name(obj),
        element_ancestry(obj)
    )
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
                // Keep the C-parity line first: logs and operators already grep "Error: <msg>".
                let error = err.error();
                println!("Error: {}", error.message());

                // ...then say *which* element failed, in which chain. "Internal data stream error"
                // on its own costs an operator an hour of guessing.
                println!("{}", error_detail_line(msg.src()));
                if let Some(debug) = err.debug() {
                    if !debug.is_empty() {
                        println!("Error debug: {}", debug.trim());
                    }
                }

                return;
            }
            gst::MessageView::Warning(warn) => {
                let src_name = msg.src().map(|s| s.name().to_string()).unwrap_or_default();
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
                        println!("SRT Event: {}", s);
                    } else if s.name() == "connection-removed" {
                        let src_name = msg.src().map(|s| s.name().to_string()).unwrap_or_default();
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

#[cfg(test)]
mod tests {
    use super::*;
    use gst::prelude::*;

    /// Builds `pipeline → bin → element` so ancestry is real, not a mock.
    fn nested() -> gst::Pipeline {
        gst::init().unwrap();
        let pipeline = gst::Pipeline::new();
        // `name` is a GstObject property; setting it as a property avoids the trait-method
        // ambiguity between `gst::prelude` and `gio::prelude`, both of which offer `set_name`.
        pipeline.set_property("name", "test-pipeline");

        let bin = gst::Bin::new();
        bin.set_property("name", "test-bin");
        pipeline.add(&bin).unwrap();

        let element = gst::ElementFactory::make("identity")
            .name("flaky-element")
            .build()
            .unwrap();
        bin.add(&element).unwrap();

        pipeline
    }

    fn leaf_of(pipeline: &gst::Pipeline) -> gst::Element {
        let bin = pipeline.by_name("test-bin").unwrap();
        let bin = bin.downcast::<gst::Bin>().unwrap();
        bin.by_name("flaky-element")
            .unwrap()
            .downcast::<gst::Element>()
            .unwrap()
    }

    #[test]
    fn error_line_names_the_element_and_its_ancestry() {
        let pipeline = nested();
        let leaf = leaf_of(&pipeline);
        let line = error_detail_line(Some(leaf.upcast_ref()));

        // The whole point: an operator sees which element failed and which chain it belongs to.
        assert!(line.contains("element=flaky-element"), "got: {line}");
        assert!(
            line.contains("flaky-element < test-bin < test-pipeline"),
            "got: {line}"
        );
    }

    #[test]
    fn ancestry_is_inert_when_the_source_is_unknown() {
        // A message with no src must not panic and must say so plainly.
        assert_eq!(element_name(None), "unknown");
        assert_eq!(element_ancestry(None), "-");
        assert_eq!(
            error_detail_line(None),
            "Error detail: element=unknown ancestry=-"
        );
    }

    /// The branch does `error_detail_line(msg.src())` on a real `MessageView::Error`. This drives
    /// that exact path with a genuine bus error (filesrc pointed at a missing file) instead of a
    /// hand-built object, so the wiring is covered and not just the formatting.
    #[test]
    fn real_bus_error_yields_a_named_element_and_ancestry() {
        gst::init().unwrap();
        if gst::ElementFactory::find("filesrc").is_none() {
            eprintln!("filesrc unavailable; skipping");
            return;
        }

        let pipeline = gst::Pipeline::new();
        pipeline.set_property("name", "error-pipeline");
        let src = gst::ElementFactory::make("filesrc")
            .name("missing-file-src")
            .property("location", "/nonexistent/blackgate-test-input.ts")
            .build()
            .unwrap();
        pipeline.add(&src).unwrap();

        // A missing file is a state-change failure that also lands on the bus as ERROR.
        let _ = pipeline.set_state(gst::State::Playing);

        let bus = pipeline.bus().unwrap();
        let mut line = None;
        for _ in 0..20 {
            let Some(msg) = bus.timed_pop(gst::ClockTime::from_mseconds(250)) else {
                continue;
            };
            if let gst::MessageView::Error(_) = msg.view() {
                line = Some(error_detail_line(msg.src()));
                break;
            }
        }
        let _ = pipeline.set_state(gst::State::Null);

        let line = line.expect("expected a bus ERROR from the missing file");
        assert!(line.contains("element=missing-file-src"), "got: {line}");
        assert!(line.contains("error-pipeline"), "got: {line}");
    }
}
