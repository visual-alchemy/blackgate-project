//! blackgate-ingest — the native pull sidecar.
//!
//! Replaces the ffmpeg loopback sidecar (`lib/AGENTS.md` §2). Same contract as before: this binary
//! *listens* on an SRT port carrying MPEG-TS, and the engine dials it as an SRT caller. That is why
//! the control plane barely changes.
//!
//! Pipelines are expressed in GStreamer launch syntax — the strings measured in the pilot
//! (docs/migration/NATIVE_PULL_PILOT.md) — which also sidesteps the `sometimes` pads (`flvdemux`,
//! `hlsdemux`) that cannot be linked statically before data flows:
//!
//!   HLS        souphttpsrc → hlsdemux → tsparse        (segments are already TS: no re-mux, which
//!                                                       is what preserves audio continuity)
//!   RTMP       rtmp2src → flvdemux → h264parse/aacparse → mpegtsmux → tsparse
//!   HTTP-FLV   souphttpsrc → flvdemux → …same tail
//!   HTTP TS    souphttpsrc → tsparse
//!
//! `rtmp2src` emits FLV rather than TS (so it cannot go straight into `tsparse`) and requires a
//! two-segment path (`rtmp://host:port/app/stream`) — both facts came out of the pilot.
//!
//! Failure behaviour mirrors the ffmpeg sidecar: a transient pull error is retried in-process with a
//! capped backoff (`-reconnect` / `-reconnect_delay_max 5`), end-of-stream exits so the control
//! plane restarts the route, and an unbuildable pipeline exits 2 because retrying cannot fix it.

use gstreamer as gst;
use gstreamer::prelude::*;
use std::time::Duration;

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum SourceKind {
    Hls,
    Rtmp,
    HttpFlv,
    HttpTs,
}

impl SourceKind {
    fn label(self) -> &'static str {
        match self {
            SourceKind::Hls => "hls",
            SourceKind::Rtmp => "rtmp",
            SourceKind::HttpFlv => "http-flv",
            SourceKind::HttpTs => "http-ts",
        }
    }
}

/// Decide how to pull a URL. Pure and unit-tested: the UI labels RTMP, HLS and HTTP sources with a
/// single generic schema, so the URL is the only signal available.
fn classify(url: &str) -> Option<SourceKind> {
    let lower = url.trim().to_ascii_lowercase();
    if lower.is_empty() {
        return None;
    }
    if lower.starts_with("rtmp://") || lower.starts_with("rtmps://") {
        return Some(SourceKind::Rtmp);
    }
    if lower.starts_with("http://") || lower.starts_with("https://") {
        let path = lower.split(['?', '#']).next().unwrap_or("");
        if path.contains(".m3u8") {
            return Some(SourceKind::Hls);
        }
        if path.ends_with(".flv") {
            return Some(SourceKind::HttpFlv);
        }
        return Some(SourceKind::HttpTs);
    }
    None
}

/// The loopback target, byte-identical to what the ffmpeg sidecar wrote to, so the route rewrite
/// (SRT caller, latency 500) keeps working.
fn srt_target(port: u16, latency_ms: u32) -> String {
    format!(
        "srt://127.0.0.1:{}?mode=listener&latency={}",
        port,
        latency_ms as u64 * 1000
    )
}

/// Quote a value for launch syntax. A signed URL legitimately contains `&`, `$` and `=`; only the
/// characters that terminate or escape a launch string need handling. The URL is never seen by a
/// shell — the binary is spawned with an argument list.
fn launch_quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

fn pipeline_description(kind: SourceKind, url: &str, target: &str) -> String {
    let source = match kind {
        SourceKind::Rtmp => format!("rtmp2src location={}", launch_quote(url)),
        _ => format!("souphttpsrc location={}", launch_quote(url)),
    };
    let sink = format!("queue ! srtsink uri={} mode=listener", launch_quote(target));
    match kind {
        SourceKind::Hls => format!("{source} ! hlsdemux ! tsparse ! {sink}"),
        SourceKind::HttpTs => format!("{source} ! tsparse ! {sink}"),
        SourceKind::Rtmp | SourceKind::HttpFlv => format!(
            "{source} ! flvdemux name=d d. ! queue ! h264parse ! mpegtsmux name=m ! tsparse ! \
             {sink} d. ! queue ! aacparse ! m."
        ),
    }
}

struct Args {
    url: String,
    port: u16,
    latency_ms: u32,
}

fn parse_args(raw: &[String]) -> Result<Args, String> {
    let mut url = None;
    let mut port = None;
    let mut latency_ms = 500u32;
    let mut i = 0;
    while i < raw.len() {
        match raw[i].as_str() {
            "--url" => {
                url = raw.get(i + 1).cloned();
                i += 2;
            }
            "--port" => {
                port = raw.get(i + 1).and_then(|p| p.parse::<u16>().ok());
                i += 2;
            }
            "--latency-ms" => {
                if let Some(v) = raw.get(i + 1).and_then(|p| p.parse::<u32>().ok()) {
                    latency_ms = v;
                }
                i += 2;
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    match (url, port) {
        (None, _) => Err("--url is required".into()),
        (Some(url), _) if url.trim().is_empty() => Err("--url is empty".into()),
        (_, None) => Err("--port is required".into()),
        (Some(url), Some(port)) => Ok(Args {
            url,
            port,
            latency_ms,
        }),
    }
}

/// One pipeline run. `Ok(())` means the source ended (EOS); `Err` is a failure worth retrying.
fn run_once(args: &Args, kind: SourceKind) -> Result<(), String> {
    let description =
        pipeline_description(kind, &args.url, &srt_target(args.port, args.latency_ms));
    let element = gst::parse::launch(&description)
        .map_err(|e| format!("could not build pipeline: {e} ({description})"))?;
    let pipeline = element
        .downcast::<gst::Pipeline>()
        .map_err(|_| "parsed element is not a pipeline".to_string())?;

    pipeline
        .set_state(gst::State::Playing)
        .map_err(|e| format!("could not start pipeline: {e}"))?;

    let bus = pipeline.bus().ok_or("pipeline has no bus")?;
    let outcome = loop {
        match bus.timed_pop_filtered(
            gst::ClockTime::from_mseconds(500),
            &[gst::MessageType::Error, gst::MessageType::Eos],
        ) {
            Some(msg) => match msg.view() {
                gst::MessageView::Error(err) => {
                    break Err(format!(
                        "pipeline error: {} ({:?})",
                        err.error(),
                        err.debug().map(|d| d.to_string())
                    ));
                }
                gst::MessageView::Eos(_) => break Ok(()),
                _ => {}
            },
            None => continue,
        }
    };

    let _ = pipeline.set_state(gst::State::Null);
    outcome
}

fn main() {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    let args = match parse_args(&raw) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("[ingest] {e}");
            eprintln!(
                "[ingest] usage: blackgate-ingest --url <url> --port <port> [--latency-ms 500]"
            );
            std::process::exit(2);
        }
    };

    let kind = match classify(&args.url) {
        Some(k) => k,
        None => {
            eprintln!(
                "[ingest] unsupported source URL (expected rtmp://, http(s) …m3u8/.flv or http(s) TS): {}",
                args.url
            );
            std::process::exit(2);
        }
    };

    if let Err(e) = gst::init() {
        eprintln!("[ingest] gst init failed: {e}");
        std::process::exit(2);
    }

    eprintln!(
        "[ingest] {} pull: {} → {}",
        kind.label(),
        args.url,
        srt_target(args.port, args.latency_ms)
    );

    let mut attempt: u32 = 0;
    loop {
        attempt += 1;
        match run_once(&args, kind) {
            Ok(()) => {
                // End of stream: the ffmpeg sidecar exited here too, and the control plane's job is
                // to notice and restart the route.
                eprintln!("[ingest] end of stream after {attempt} attempt(s); exiting");
                std::process::exit(0);
            }
            Err(e) if e.starts_with("could not build pipeline") => {
                // A missing element or a description that cannot be parsed will not get better.
                eprintln!("[ingest] fatal: {e}");
                std::process::exit(2);
            }
            Err(e) => {
                // Transient (network, handshake, source refused): retry like ffmpeg's -reconnect
                // with -reconnect_delay_max 5.
                let delay = std::cmp::min(5, attempt);
                eprintln!("[ingest] {e} — reconnecting in {delay}s (attempt {attempt})");
                std::thread::sleep(Duration::from_secs(delay as u64));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_dispatches_on_the_url_not_the_schema() {
        // The UI sends every network source as one generic "RTMP" schema, so the URL decides.
        assert_eq!(
            classify("rtmp://34.101.170.62:9200/live/8WFCourt2"),
            Some(SourceKind::Rtmp)
        );
        assert_eq!(classify("rtmps://host:443/live/x"), Some(SourceKind::Rtmp));
        assert_eq!(
            classify("https://cdnw-pull.tvri.go.id/stream/ASEAN_GAMES/playlist.m3u8"),
            Some(SourceKind::Hls)
        );
        assert_eq!(
            classify("https://example.invalid/live/index.m3u8?token=abc&name=quoted"),
            Some(SourceKind::Hls)
        );
        assert_eq!(
            classify("http://34.101.170.62:8085/vse/playback/live/8WFCourt2.flv"),
            Some(SourceKind::HttpFlv)
        );
        assert_eq!(
            classify("http://host:8080/live.ts"),
            Some(SourceKind::HttpTs)
        );
        assert_eq!(classify(""), None);
        assert_eq!(classify("udp://127.0.0.1:5000"), None);
        assert_eq!(classify("srt://127.0.0.1:9000"), None);
    }

    #[test]
    fn srt_target_matches_the_contract_the_control_plane_expects() {
        // Byte-identical to the old ffmpeg target and to what the engine dials as an SRT caller.
        assert_eq!(
            srt_target(39_001, 500),
            "srt://127.0.0.1:39001?mode=listener&latency=500000"
        );
        assert_eq!(
            srt_target(39_999, 120),
            "srt://127.0.0.1:39999?mode=listener&latency=120000"
        );
    }

    #[test]
    fn launch_quote_keeps_hostile_urls_as_one_value() {
        // `$`, `&` and `=` are legal in a launch string and must survive untouched; only the
        // quote and backslash that would end the value are escaped.
        assert_eq!(
            launch_quote("https://x/y?token=$HOME&name=a=b"),
            "\"https://x/y?token=$HOME&name=a=b\""
        );
        assert_eq!(launch_quote(r#"a"b"#), "\"a\\\"b\"");
        assert_eq!(launch_quote(r"a\b"), "\"a\\\\b\"");
    }

    #[test]
    fn description_uses_the_pilot_proven_chains() {
        let rtmp = pipeline_description(
            SourceKind::Rtmp,
            "rtmp://127.0.0.1:1935/live/key",
            "srt://127.0.0.1:39001?mode=listener&latency=500000",
        );
        // rtmp2src emits FLV, so the explicit demux + remux chain is mandatory.
        assert!(rtmp.starts_with("rtmp2src location=\"rtmp://127.0.0.1:1935/live/key\""));
        assert!(rtmp.contains("flvdemux name=d"));
        assert!(rtmp.contains("h264parse"));
        assert!(rtmp.contains("aacparse"));
        assert!(rtmp.contains("mpegtsmux"));
        assert!(rtmp.ends_with("d. ! queue ! aacparse ! m."));

        // HLS passes TS fragments through: no demux, no re-mux — that is what keeps audio intact.
        let hls = pipeline_description(
            SourceKind::Hls,
            "https://x/y.m3u8",
            "srt://127.0.0.1:39002?mode=listener&latency=500000",
        );
        assert_eq!(
            hls,
            "souphttpsrc location=\"https://x/y.m3u8\" ! hlsdemux ! tsparse ! queue ! \
             srtsink uri=\"srt://127.0.0.1:39002?mode=listener&latency=500000\" mode=listener"
        );
        assert!(!hls.contains("mpegtsmux"));

        // Every kind ends in listener mode on the loopback target.
        for kind in [
            SourceKind::Hls,
            SourceKind::Rtmp,
            SourceKind::HttpFlv,
            SourceKind::HttpTs,
        ] {
            let d =
                pipeline_description(kind, "http://h/live.ts", "srt://127.0.0.1:1?mode=listener");
            assert!(d.contains("srtsink uri="));
            assert!(d.contains("mode=listener"));
        }
    }

    #[test]
    fn parse_args_reads_the_control_plane_invocation() {
        let raw = vec![
            "--url".to_string(),
            "rtmp://34.101.170.62:9200/live/8WFCourt2".to_string(),
            "--port".to_string(),
            "39001".to_string(),
        ];
        let args = parse_args(&raw).expect("should parse");
        assert_eq!(args.port, 39_001);
        assert_eq!(args.latency_ms, 500); // default
        assert_eq!(args.url, "rtmp://34.101.170.62:9200/live/8WFCourt2");

        let with_latency = vec![
            "--url".to_string(),
            "https://x/y.m3u8".to_string(),
            "--port".to_string(),
            "39002".to_string(),
            "--latency-ms".to_string(),
            "120".to_string(),
        ];
        assert_eq!(
            parse_args(&with_latency).expect("should parse").latency_ms,
            120
        );
    }

    #[test]
    fn parse_args_rejects_incomplete_or_bad_invocation() {
        assert!(parse_args(&["--port".into(), "39001".into()]).is_err()); // no url
        assert!(parse_args(&["--url".into(), " ".into(), "--port".into(), "1".into()]).is_err());
        assert!(parse_args(&["--url".into(), "http://x".into()]).is_err()); // no port
        assert!(parse_args(&[
            "--url".into(),
            "http://x".into(),
            "--port".into(),
            "notaport".into()
        ])
        .is_err());
        assert!(parse_args(&["--nope".into()]).is_err());
    }
}
