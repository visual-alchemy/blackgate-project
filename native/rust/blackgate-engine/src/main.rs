// blackgate-engine — Rust port of native/src/main.c
//
// Startup contract (stdout/socket byte-parity with the C engine):
//   init_unix_socket(exit on fail) → "Connected to the socket."
//   → "Argument %d: %s" → socket "route_id:"+argv[1]
//   → "Waiting for JSON input..." → read init line
//   → "Received JSON: %s" → parse → build → PLAYING → bus loop + stdin commands

use std::io::{BufRead, Write};
use std::os::unix::net::UnixStream;
use std::process;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use gstreamer::prelude::*;

use engine_config::RouteConfig;
use engine_failover::{SelectorState, SourceTarget};
use engine_stats::SharedSocket;

/// Stats socket the engine dials.
///
/// The release passes BLACKGATE_STATS_SOCKET so a development or test node can
/// never bind the same path as a running appliance: a `mix test` run used to
/// unlink the live listener's socket and leave a dead file behind, after which
/// every new engine exited with `connect: Connection refused (os error 111)`.
fn stats_socket_path(shadow: bool) -> String {
    let base = std::env::var("BLACKGATE_STATS_SOCKET")
        .unwrap_or_else(|_| "/tmp/hydra_unix_sock".to_string());
    if shadow {
        format!("{}_rust", base)
    } else {
        base
    }
}

/// Parsed stdin command. The C engine dispatches on the same strings, so this is the wire
/// contract: the Elixir RouteHandler sends it, `ipc_smoke.py` sends it. Pure by design — a
/// regression here used to surface only as a route that stopped responding, with nothing in
/// `cargo test` to catch it.
#[derive(Debug)]
enum Command {
    SwitchSource(SourceTarget),
    JoinSecondary,
    LeaveSecondary,
    StopRoute,
    Unknown(String),
    Invalid,
}

fn parse_command(line: &str) -> Command {
    let value: serde_json::Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(_) => return Command::Invalid,
    };

    match value["command"].as_str() {
        Some("switch-source") => {
            let target = value["target"].as_str().unwrap_or("primary");
            Command::SwitchSource(if target == "secondary" {
                SourceTarget::Secondary
            } else {
                SourceTarget::Primary
            })
        }
        Some("join-secondary") => Command::JoinSecondary,
        Some("leave-secondary") => Command::LeaveSecondary,
        Some("stop-route") => Command::StopRoute,
        Some(other) => Command::Unknown(other.to_string()),
        None => Command::Invalid,
    }
}

fn connect_unix_socket(route_id: &str, shadow: bool) -> SharedSocket {
    let socket_path = stats_socket_path(shadow);
    match UnixStream::connect(&socket_path) {
        Ok(mut stream) => {
            println!("Connected to the socket.");
            // C left this record unframed ("route_id:" + argv[1], no newline), so the node's
            // socket handler had to guess where the id ended and could not buffer the stream
            // safely. Every other record on this socket is newline-terminated; so is this one now.
            let _ = stream.write_all(b"route_id:");
            let _ = stream.write_all(route_id.as_bytes());
            let _ = stream.write_all(b"\n");
            let _ = stream.flush();
            Arc::new(Mutex::new(stream))
        }
        Err(e) => {
            eprintln!("connect: {} ({})", e, socket_path);
            process::exit(1);
        }
    }
}

/// Stop decodebin from picking the VA (hardware) decoders.
///
/// The appliance's VA stack cannot initialise ("VA error: iHD_drv_video.so init failed", no usable
/// DRM render node) yet decodebin still picks `vah264dec` for H.264 by rank. That decoder reports
/// its output as `video/x-raw, format=NV12, interlace-mode=mixed`, and an interlaced SDI mode has to
/// demand `interlace-mode=interleaved` — nothing bridges the two (videoconvert refuses the
/// conversion, and the `interlace` element cannot output UYVY on GStreamer 1.24). Negotiation then
/// fails, the resulting not-negotiated error stops the SRT source's task, and the whole route dies
/// and reconnects forever: exactly the "SDI out 1 keeps reconnecting" symptom on PLTV. Software
/// decoding (avdec_h264 — what the thumbnail branch already uses) negotiates and puts frames on the
/// card, so keep the broken decoders out of the ranking.
fn demote_broken_va_decoders() {
    for name in [
        "vah264dec",
        "vah265dec",
        "vaapih264dec",
        "vaapih265dec",
        "vaapidecodebin",
    ] {
        if let Some(factory) = gstreamer::ElementFactory::find(name) {
            factory.set_rank(gstreamer::Rank::NONE);
            println!(
                "[rust-engine] {} disabled (rank NONE): its VA output caps break SDI negotiation",
                name
            );
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut shadow_mode = false;
    let route_id = std::env::args()
        .skip(1)
        .find(|a| {
            if a == "--shadow" {
                shadow_mode = true;
                false
            } else {
                true
            }
        })
        .unwrap_or_else(|| "unknown".into());

    let socket = connect_unix_socket(&route_id, shadow_mode);

    let argc = std::env::args().count();
    println!("Argument {}: {}", argc, route_id);

    println!("Waiting for JSON input...");

    let mut stdout = std::io::stdout();

    let stdin = std::io::stdin();
    let mut reader = std::io::BufReader::new(stdin.lock());

    let mut init_line = String::new();
    reader.read_line(&mut init_line)?;
    if init_line.trim().is_empty() {
        eprintln!("Failed to read init JSON from stdin");
        return Ok(());
    }
    // Release stdin before command thread takes its own lock. Keeping reader
    // alive here blocks stop-route and every other runtime command forever.
    drop(reader);
    println!("Received JSON: {}", init_line.trim());
    stdout.flush()?;

    let config = match RouteConfig::from_json(init_line.trim()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error parsing JSON: {}", e);
            process::exit(1);
        }
    };

    gstreamer::init().map_err(|e| format!("GStreamer init: {}", e))?;
    demote_broken_va_decoders();

    let built = match engine_gst::build_pipeline(&config, socket.clone()) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("[rust-engine] FATAL: {}", e);
            process::exit(1);
        }
    };

    let pipeline = built.pipeline;
    if pipeline.set_state(gstreamer::State::Playing).is_err() {
        eprintln!("Unable to set the pipeline to the playing state.");
        for el in pipeline
            .iterate_elements()
            .into_iter()
            .filter_map(Result::ok)
        {
            let (_, state, pending) = el.state(gstreamer::ClockTime::NONE);
            if state != gstreamer::State::Playing {
                let name = |s: gstreamer::State| match s {
                    gstreamer::State::VoidPending => "VOID_PENDING",
                    gstreamer::State::Null => "NULL",
                    gstreamer::State::Ready => "READY",
                    gstreamer::State::Paused => "PAUSED",
                    gstreamer::State::Playing => "PLAYING",
                };
                eprintln!(
                    "Element '{}' state={} pending={}",
                    el.name(),
                    name(state),
                    name(pending)
                );
            }
        }
        let _ = pipeline.set_state(gstreamer::State::Null);
        println!("Socket closed.");
        process::exit(1);
    }

    let running = Arc::new(AtomicBool::new(true));
    engine_stats::start_stats_thread(
        socket.clone(),
        built.source.clone(),
        built.srt_sinks.clone(),
        built.secondary.clone(),
        built.video_info.clone(),
        running.clone(),
    );

    let stop = Arc::new(AtomicBool::new(false));

    // The persisted selection must reach the seamless state too, not just the selector's
    // active-pad in builder.rs - otherwise the engine believes it is on primary while the
    // pipeline is provably on secondary.
    let active_source = match config.active_source.as_deref() {
        Some("secondary") => SourceTarget::Secondary,
        _ => SourceTarget::Primary,
    };

    let selector_state: Arc<Mutex<Option<SelectorState>>> =
        Arc::new(Mutex::new(match (&built.selector, &built.secondary) {
            (Some(sel), Some(sec)) => Some(SelectorState::new(
                sel.clone(),
                sec.clone(),
                config.auto_join,
                active_source,
            )),
            _ => None,
        }));

    // Dual-ingest only: learn each source's programme and keyframes, and keep the output timeline
    // continuous across an in-process switch.
    if built.selector.is_some() {
        if let Some(secondary) = built.secondary.as_ref() {
            SelectorState::install_probes(&selector_state, &built.source, secondary, &built.tee);
            println!(
                "SEAMLESS: source probes installed (keyframe-gated switch, timeline normalised)"
            );
        }
    }

    // stdin command thread (C stdin_watch_cb + handle_command_line)
    let stop_for_stdin = stop.clone();
    let selector_for_stdin = selector_state.clone();
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        let mut reader = stdin.lock();
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => {
                    println!("stdin closed (cond=0x10), shutting down pipeline");
                    stop_for_stdin.store(true, Ordering::Relaxed);
                    return;
                }
                Ok(_) => {}
            }
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }

            match parse_command(trimmed) {
                Command::Invalid => {
                    eprintln!("Bad command JSON: {}", trimmed);
                }
                Command::StopRoute => {
                    eprintln!("[rust-engine] stop-route received, shutting down pipeline");
                    stop_for_stdin.store(true, Ordering::Relaxed);
                    return;
                }
                Command::Unknown(other) => {
                    eprintln!("Unknown command: {}", other);
                }
                cmd => {
                    let mut sel_guard = match selector_for_stdin.lock() {
                        Ok(g) => g,
                        Err(_) => continue,
                    };
                    match (cmd, sel_guard.as_mut()) {
                        (Command::SwitchSource(tgt), Some(sel)) => {
                            // `true` means the engine is holding the switch: it moves the selector
                            // once THIS source reports a keyframe. Printing it on the other branch
                            // would label an already-completed move as pending.
                            if sel.request_switch(tgt) {
                                println!(
                                    "SOURCE_SWITCH_PENDING:{} (held until this source carries a keyframe)",
                                    tgt.as_str()
                                );
                            }
                        }
                        (Command::SwitchSource(_), None) => {
                            eprintln!("switch_source: not a dual-ingest pipeline");
                        }
                        (Command::JoinSecondary, Some(sel)) => sel.join_secondary(),
                        (Command::LeaveSecondary, Some(sel)) => sel.leave_secondary(),
                        // join/leave on a single-source pipeline: nothing to join.
                        _ => {}
                    }
                }
            }
            let _ = std::io::stdout().flush();
        }
    });

    // Main thread = bus loop (C g_main_loop_run with bus_callback)
    engine_gst::run_bus_watch(
        &pipeline,
        socket.clone(),
        &config.route_id,
        stop.clone(),
    );

    // C cleanup_pipeline
    running.store(false, Ordering::Relaxed);
    let _ = pipeline.set_state(gstreamer::State::Null);
    if let Some(mut thumb) = built.thumbnail {
        thumb.stop();
    }

    println!("Socket closed.");
    eprintln!("[rust-engine] shutdown complete");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_every_command_the_control_plane_sends() {
        assert!(matches!(
            parse_command(r#"{"command":"switch-source","target":"secondary"}"#),
            Command::SwitchSource(SourceTarget::Secondary)
        ));
        assert!(matches!(
            parse_command(r#"{"command":"switch-source","target":"primary"}"#),
            Command::SwitchSource(SourceTarget::Primary)
        ));
        // route_handler omits the target when switching back, so primary is the default.
        assert!(matches!(
            parse_command(r#"{"command":"switch-source"}"#),
            Command::SwitchSource(SourceTarget::Primary)
        ));
        assert!(matches!(
            parse_command(r#"{"command":"join-secondary"}"#),
            Command::JoinSecondary
        ));
        assert!(matches!(
            parse_command(r#"{"command":"leave-secondary"}"#),
            Command::LeaveSecondary
        ));
        assert!(matches!(
            parse_command(r#"{"command":"stop-route"}"#),
            Command::StopRoute
        ));
    }

    #[test]
    fn reports_unknown_and_malformed_commands_instead_of_wedging() {
        assert!(
            matches!(parse_command(r#"{"command":"warp-speed"}"#), Command::Unknown(ref s) if s == "warp-speed")
        );
        assert!(matches!(
            parse_command(r#"{"target":"primary"}"#),
            Command::Invalid
        ));
        assert!(matches!(parse_command("not json at all"), Command::Invalid));
        assert!(matches!(parse_command(""), Command::Invalid));
    }
}
