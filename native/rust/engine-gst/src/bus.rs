// Bus watch — C bus_callback parity.
//
// WARNING  → stdout "Pipeline Warning from <name>: <msg>"
//            decoder/demuxer sources → warning JSON over socket
//            source/secondary_source → SOURCE_INVALID:<tag> <msg>
// ERROR    → stdout "Error: <msg>" + quit main loop
//            SDI-branch errors → stdout "WARNING: SDI sink N failed — continuing without SDI output"
//            and the branch is detached; the route keeps running (see SdiBranchHandle)
// STATE_CHANGED (pipeline only) → stdout "Pipeline state changed from X to Y"
// ELEMENT  → GstSRTObject → "SRT Event: <structure>"
//            connection-removed → SOURCE_INVALID:<primary|secondary>

use gst::prelude::*;
use gstreamer as gst;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use engine_stats::{SdiState, SharedSocket};

use crate::builder::SdiBranchHandle;

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

/// `<element < parent < ... < pipeline>` — the SDI branch hangs straight off the pipeline, so the
/// ancestry is what tells an operator which chain a failure came from.
fn element_ancestry(obj: Option<&gst::Object>) -> String {
    let names = ancestry_names(obj);

    if names.is_empty() {
        "-".to_string()
    } else {
        names.join(" < ")
    }
}

/// The same walk as `element_ancestry`, as a list (used for SDI-branch attribution).
fn ancestry_names(obj: Option<&gst::Object>) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    let mut current = obj.cloned();

    while let Some(item) = current {
        names.push(item.name().to_string());
        current = item.parent();
    }

    names
}

/// The erroring object followed by its ancestors (element, then the bin/pipeline that own it).
fn ancestry_objects(obj: Option<&gst::Object>) -> Vec<gst::Object> {
    let mut objects: Vec<gst::Object> = Vec::new();
    let mut current = obj.cloned();

    while let Some(item) = current {
        current = item.parent();
        objects.push(item);
    }

    objects
}

/// Which SDI branch owns a failure? Attribution is by element identity: the failing element itself,
/// or an ancestor (an element inside the SDI decodebin reports the bin as its parent, and the bin is
/// one of the branch's elements). Anything else — the source, an SRT/UDP sink, the thumbnail branch —
/// stays fatal so RouteHandler reconnects the route.
fn sdi_branch_index(branches: &[SdiBranchHandle], src: Option<&gst::Object>) -> Option<usize> {
    let ancestry = ancestry_objects(src);

    branches.iter().position(|branch| {
        ancestry.iter().any(|obj| {
            branch
                .elements
                .iter()
                .any(|el| *el.upcast_ref::<gst::Object>() == *obj)
        })
    })
}

/// The line RouteHandler greps for when it raises the operator's `sdi_failed` event: it matches on
/// `WARNING: SDI sink` and `failed`, and the whole line becomes the event text, so keep both
/// substrings and keep it English.
fn sdi_failure_marker(sink_index: usize, device_number: i32, reason: &str) -> String {
    format!(
        "WARNING: SDI sink {} failed — continuing without SDI output (DeckLink device {}, {})",
        sink_index, device_number, reason
    )
}

/// Drop one SDI branch: unlink it from the tee, release the tee pad, and park the DeckLink sinks at
/// NULL so the driver frees the device instead of holding the last frame. The route keeps running on
/// its remaining outputs — an SDI misconfiguration must never take the SRT output down with it.
fn detach_sdi_branch(branch: &SdiBranchHandle, sdi_state: &Arc<SdiState>) {
    if branch.failed.swap(true, Ordering::Relaxed) {
        return; // only the first error on this branch acts
    }

    if let Some(branch_sink_pad) = branch.queue.static_pad("sink") {
        let _ = branch.tee_pad.unlink(&branch_sink_pad);
    }
    if let Some(tee) = branch
        .tee_pad
        .parent()
        .and_then(|p| p.downcast::<gst::Element>().ok())
    {
        tee.release_request_pad(&branch.tee_pad);
    }
    for sink in &branch.sinks {
        let _ = sink.set_state(gst::State::Null);
    }

    if (0..8).contains(&branch.device_number) {
        sdi_state.branch_failed[branch.device_number as usize].store(true, Ordering::Relaxed);
    }
}

/// Runs the bus loop on the calling thread. Returns when the pipeline should
/// shut down (EOS, ERROR, or the stop flag). C parity: ERROR quits the run
/// loop; the caller then runs cleanup and exits. SDI-branch errors are the one
/// exception — they detach that branch and keep the loop alive.
pub fn run_bus_watch(
    pipeline: &gst::Pipeline,
    socket: SharedSocket,
    route_id: &str,
    stop: Arc<AtomicBool>,
    sdi_branches: &[SdiBranchHandle],
    sdi_state: &Arc<SdiState>,
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
                // The C-parity line first: RouteHandler and the logs already match on "Error: <msg>".
                let error = err.error();
                println!("Error: {}", error.message());

                // "Internal data stream error" alone does not say *which* chain failed, and on a
                // route with an SDI sink that is the difference between an hour of guessing and a
                // one-line answer: name the element, its ancestry, and hand over GStreamer's debug
                // string (which carries the reason, e.g. "streaming stopped, reason not-negotiated").
                let src = msg.src();
                println!(
                    "Error detail: element={} ancestry={}",
                    element_name(src),
                    element_ancestry(src)
                );
                if let Some(debug) = err.debug() {
                    if !debug.is_empty() {
                        println!("Error debug: {}", debug.trim());
                    }
                }

                // SDI output failures cost the SDI output only. Letting them end the run killed the
                // route's other outputs and made RouteHandler reconnect every ~40 s (PLTV SDI 1, and
                // an experimental 50p HDR route). RouteHandler documents this exact behaviour:
                // "WARNING: SDI sink N failed — continuing without SDI output", operator gets a
                // sdi_failed event, route keeps running.
                if let Some(idx) = sdi_branch_index(sdi_branches, src) {
                    let branch = &sdi_branches[idx];
                    println!(
                        "{}",
                        sdi_failure_marker(
                            branch.sink_index,
                            branch.device_number,
                            error.message()
                        )
                    );
                    detach_sdi_branch(branch, sdi_state);
                    continue;
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

                // Sources are named exactly "source"/"secondary_source"; SDI-branch elements carry a
                // tag, so this can never mis-tag an SDI warning as a source problem.
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

    /// Attribution is by element identity: a branch element — or something inside it, which reports
    /// the branch's bin as its parent — maps to that branch. Everything else stays fatal so
    /// RouteHandler reconnects the route.
    #[test]
    fn sdi_branch_attribution_uses_element_identity() {
        gst::init().expect("gst init");
        let pipeline = gst::Pipeline::new();
        let branch_bin = gst::Bin::new();
        let inner = gst::ElementFactory::make("fakesink")
            .name("inner")
            .build()
            .expect("inner fakesink");
        branch_bin.add(&inner).expect("add inner to bin");
        let branch_sink = gst::ElementFactory::make("fakesink")
            .name("branch-sink")
            .build()
            .expect("branch fakesink");
        let source = gst::ElementFactory::make("fakesrc")
            .build()
            .expect("fakesrc");
        let queue = gst::ElementFactory::make("queue").build().expect("queue");
        pipeline
            .add_many([
                branch_bin.clone().upcast::<gst::Element>(),
                branch_sink.clone(),
                source.clone(),
                queue.clone(),
            ])
            .expect("add elements");

        let branches = vec![SdiBranchHandle {
            sink_index: 0,
            device_number: 0,
            elements: vec![
                branch_bin.clone().upcast::<gst::Element>(),
                branch_sink.clone(),
            ],
            tee_pad: queue.static_pad("sink").expect("queue sink pad"),
            queue: queue.clone(),
            sinks: vec![branch_sink.clone()],
            failed: Arc::new(AtomicBool::new(false)),
        }];

        assert_eq!(
            sdi_branch_index(&branches, Some(inner.upcast_ref::<gst::Object>())),
            Some(0),
            "an element inside the branch reports the branch's bin as its parent"
        );
        assert_eq!(
            sdi_branch_index(&branches, Some(branch_sink.upcast_ref::<gst::Object>())),
            Some(0),
            "the branch's own sink"
        );
        assert_eq!(
            sdi_branch_index(&branches, Some(source.upcast_ref::<gst::Object>())),
            None,
            "a source error must stay fatal"
        );
        assert_eq!(
            sdi_branch_index(&branches, Some(pipeline.upcast_ref::<gst::Object>())),
            None,
            "a pipeline-level error must stay fatal"
        );

        let _ = pipeline.set_state(gst::State::Null);
    }

    /// RouteHandler raises the operator's sdi_failed event from this text, matching both substrings —
    /// and the route must be told it keeps running.
    #[test]
    fn sdi_failure_marker_matches_route_handler_contract() {
        let marker = sdi_failure_marker(1, 1, "GStreamer encountered a general stream error.");
        assert!(marker.contains("WARNING: SDI sink"), "marker: {}", marker);
        assert!(marker.contains("failed"), "marker: {}", marker);
        assert!(
            marker.contains("continuing without SDI output"),
            "marker: {}",
            marker
        );
        assert!(marker.contains("DeckLink device 1"), "marker: {}", marker);
        assert!(
            marker.contains("general stream error"),
            "marker: {}",
            marker
        );
    }

    /// Detaching has to really unlink the branch and park its sink: if the tee keeps pushing into a
    /// dead branch, the source dies anyway and the route reconnects — the bug this behaviour fixes.
    #[test]
    fn detaching_an_sdi_branch_unlinks_it_from_the_tee_and_parks_its_sink() {
        gst::init().expect("gst init");
        let pipeline = gst::Pipeline::new();
        let tee = gst::ElementFactory::make("tee")
            .property("allow-not-linked", true)
            .build()
            .expect("tee");
        let queue = gst::ElementFactory::make("queue")
            .name("sdi0-queue-0")
            .build()
            .expect("queue");
        let sink = gst::ElementFactory::make("fakesink")
            .name("sdi0-fakesink-1")
            .build()
            .expect("fakesink");
        pipeline
            .add_many([&tee, &queue, &sink])
            .expect("add elements");
        gst::Element::link_many([&tee, &queue, &sink]).expect("link branch");
        pipeline
            .set_state(gst::State::Paused)
            .expect("pipeline paused");

        let tee_pad = queue
            .static_pad("sink")
            .and_then(|pad| pad.peer())
            .expect("tee request pad");
        let handle = SdiBranchHandle {
            sink_index: 0,
            device_number: 0,
            elements: vec![tee.clone(), queue.clone(), sink.clone()],
            tee_pad,
            queue: queue.clone(),
            sinks: vec![sink.clone()],
            failed: Arc::new(AtomicBool::new(false)),
        };
        let sdi_state = SdiState::new_shared();

        detach_sdi_branch(&handle, &sdi_state);

        assert!(
            !queue
                .static_pad("sink")
                .expect("queue sink pad")
                .is_linked(),
            "branch must be unlinked from the tee"
        );
        assert_eq!(
            sink.current_state(),
            gst::State::Null,
            "the DeckLink sink has to release the device, not hold the last frame"
        );
        assert!(
            sdi_state.branch_failed[0].load(Ordering::Relaxed),
            "stats must know the branch is gone (health monitors go quiet)"
        );

        // Only the first error acts; a second one from the same branch is a no-op.
        detach_sdi_branch(&handle, &sdi_state);
        assert!(!queue
            .static_pad("sink")
            .expect("queue sink pad")
            .is_linked());

        let _ = pipeline.set_state(gst::State::Null);
    }
}
