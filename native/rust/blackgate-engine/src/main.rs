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

fn connect_unix_socket(route_id: &str, shadow: bool) -> SharedSocket {
    let socket_path = if shadow {
        "/tmp/hydra_unix_sock_rust"
    } else {
        "/tmp/hydra_unix_sock"
    };
    match UnixStream::connect(socket_path) {
        Ok(mut stream) => {
            println!("Connected to the socket.");
            // C: two raw sends — "route_id:" + argv[1], no newline
            let _ = stream.write_all(b"route_id:");
            let _ = stream.write_all(route_id.as_bytes());
            let _ = stream.flush();
            Arc::new(Mutex::new(stream))
        }
        Err(e) => {
            eprintln!("connect: {}", e);
            process::exit(1);
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
        built.sdi_state.clone(),
        built.vrate_elements.clone(),
        running.clone(),
    );

    let stop = Arc::new(AtomicBool::new(false));

    let selector_state: Arc<Mutex<Option<SelectorState>>> =
        Arc::new(Mutex::new(match (&built.selector, &built.secondary) {
            (Some(sel), Some(sec)) => Some(SelectorState::new(sel.clone(), sec.clone())),
            _ => None,
        }));

    // stdin command thread (C stdin_watch_cb + handle_command_line)
    let stop_for_stdin = stop.clone();
    let selector_for_stdin = selector_state.clone();
    let config_auto_join = config.auto_join;
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

            let cmd: serde_json::Value = match serde_json::from_str(trimmed) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("Bad command JSON: {}", e);
                    continue;
                }
            };

            let mut sel_guard = match selector_for_stdin.lock() {
                Ok(g) => g,
                Err(_) => continue,
            };

            match cmd["command"].as_str() {
                Some("switch-source") => {
                    let target = cmd["target"].as_str().unwrap_or("primary");
                    match sel_guard.as_mut() {
                        Some(sel) => {
                            let tgt = if target == "secondary" {
                                SourceTarget::Secondary
                            } else {
                                SourceTarget::Primary
                            };
                            sel.switch_to(tgt);
                        }
                        None => {
                            eprintln!("switch_source: not a dual-ingest pipeline");
                        }
                    }
                }
                Some("join-secondary") => {
                    if let Some(sel) = sel_guard.as_mut() {
                        sel.join_secondary();
                    }
                }
                Some("leave-secondary") => {
                    if let Some(sel) = sel_guard.as_mut() {
                        sel.leave_secondary();
                    }
                }
                Some("stop-route") => {
                    eprintln!("[rust-engine] stop-route received, shutting down pipeline");
                    stop_for_stdin.store(true, Ordering::Relaxed);
                    return;
                }
                Some(other) => {
                    eprintln!("Unknown command: {}", other);
                }
                None => {
                    eprintln!("Bad command JSON: {}", trimmed);
                }
            }
            let _ = config_auto_join;
            let _ = std::io::stdout().flush();
        }
    });

    // Main thread = bus loop (C g_main_loop_run with bus_callback)
    engine_gst::run_bus_watch(&pipeline, socket.clone(), &config.route_id, stop.clone());

    // C cleanup_pipeline
    running.store(false, Ordering::Relaxed);
    built.sdi_state.reset();
    let _ = pipeline.set_state(gstreamer::State::Null);
    if let Some(mut thumb) = built.thumbnail {
        thumb.stop();
    }

    println!("Socket closed.");
    eprintln!("[rust-engine] shutdown complete");
    Ok(())
}
