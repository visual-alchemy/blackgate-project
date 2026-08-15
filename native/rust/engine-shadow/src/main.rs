use anyhow::Result;
use serde::Deserialize;
use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

#[derive(Debug, Deserialize)]
struct SourceStatsRaw {
    source: Option<String>,
    #[serde(rename = "bandwidth-mbps")]
    bandwidth_mbps: Option<f64>,
    #[serde(rename = "packets-received")]
    packets_received: Option<f64>,
    #[serde(rename = "rtt-ms")]
    rtt_ms: Option<f64>,
    #[serde(rename = "receive-rate-mbps")]
    receive_rate_mbps: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct SinkStatsRaw {
    #[serde(rename = "bandwidth-mbps")]
    bandwidth_mbps: Option<f64>,
    #[serde(rename = "packets-sent")]
    packets_sent: Option<f64>,
    #[serde(rename = "rtt-ms")]
    rtt_ms: Option<f64>,
    #[serde(rename = "send-rate-mbps")]
    send_rate_mbps: Option<f64>,
}

#[derive(Debug, Default)]
struct EngineSnapshot {
    source_bw: Option<f64>,
    source_rtt: Option<f64>,
    sink_bw: Option<f64>,
    sink_packets: Option<f64>,
    last_update: Option<Instant>,
}

/// Parse one socket line: either a source-stats JSON object or
/// "stats_sink:<json>". Engines emit them as separate newline-terminated
/// sends (coalescing is handled per-line here, not by concatenation).
fn parse_line(line: &str) -> Option<(Option<SourceStatsRaw>, Option<SinkStatsRaw>)> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }

    if let Some(sink_json) = line.strip_prefix("stats_sink:") {
        let sink: SinkStatsRaw = serde_json::from_str(sink_json.trim()).ok()?;
        return Some((None, Some(sink)));
    }

    if line.starts_with('{') && line.contains("\"source\"") {
        let source: SourceStatsRaw = serde_json::from_str(line).ok()?;
        return Some((Some(source), None));
    }

    None
}

fn apply_snapshot_update(snapshot: &mut EngineSnapshot, source: Option<SourceStatsRaw>, sink: Option<SinkStatsRaw>) {
    if let Some(source) = source {
        if let Some(bw) = source.bandwidth_mbps.or(source.receive_rate_mbps) {
            snapshot.source_bw = Some(bw);
        }
        if let Some(rtt) = source.rtt_ms {
            snapshot.source_rtt = Some(rtt);
        }
    }
    if let Some(sink) = sink {
        if let Some(bw) = sink.bandwidth_mbps.or(sink.send_rate_mbps) {
            snapshot.sink_bw = Some(bw);
        }
        if let Some(pkts) = sink.packets_sent {
            snapshot.sink_packets = Some(pkts);
        }
    }
    snapshot.last_update = Some(Instant::now());
}

fn read_stats(socket_path: &str, snapshot: &mut EngineSnapshot) -> Result<()> {
    let stream = UnixStream::connect(socket_path)?;
    let reader = BufReader::new(stream);

    for line in reader.lines() {
        let line = line?;
        if let Some((source, sink)) = parse_line(&line) {
            apply_snapshot_update(snapshot, source, sink);
        }
    }
    Ok(())
}

fn compare(c: &EngineSnapshot, rust: &EngineSnapshot) -> Vec<String> {
    let mut alerts = vec![];

    if let (Some(c_bw), Some(r_bw)) = (c.source_bw, rust.source_bw) {
        let diff = ((c_bw - r_bw).abs() / c_bw.max(0.001)) * 100.0;
        if diff > 5.0 {
            alerts.push(format!("source_throughput: {:.1}% dev (C={:.2} Mbps, Rust={:.2} Mbps)", diff, c_bw, r_bw));
        }
    }
    if let (Some(c_bw), Some(r_bw)) = (c.sink_bw, rust.sink_bw) {
        let diff = ((c_bw - r_bw).abs() / c_bw.max(0.001)) * 100.0;
        if diff > 5.0 {
            alerts.push(format!("sink_throughput: {:.1}% dev (C={:.2} Mbps, Rust={:.2} Mbps)", diff, c_bw, r_bw));
        }
    }
    if let (Some(c_rtt), Some(r_rtt)) = (c.source_rtt, rust.source_rtt) {
        let diff = (c_rtt - r_rtt).abs();
        if diff > 10.0 {
            alerts.push(format!("source_latency: {:.1}ms dev (C={:.1}ms, Rust={:.1}ms)", diff, c_rtt, r_rtt));
        }
    }
    if let (Some(c_pkts), Some(r_pkts)) = (c.sink_packets, rust.sink_packets) {
        let diff = ((c_pkts - r_pkts).abs() / c_pkts.max(1.0)) * 100.0;
        if diff > 1.0 {
            alerts.push(format!("sink_packets: {:.1}% dev (C={:.0}, Rust={:.0})", diff, c_pkts, r_pkts));
        }
    }
    alerts
}

fn main() -> Result<()> {
    let c_socket = "/tmp/hydra_unix_sock";
    let rust_socket = "/tmp/hydra_unix_sock_rust";
    let compare_interval = Duration::from_secs(5);

    println!("[shadow-daemon] starting comparison daemon");
    println!("[shadow-daemon] C engine socket: {}", c_socket);
    println!("[shadow-daemon] Rust engine socket: {}", rust_socket);
    println!("[shadow-daemon] comparison interval: {}s", compare_interval.as_secs());

    let mut c_snapshot = EngineSnapshot::default();
    let mut rust_snapshot = EngineSnapshot::default();

    // In production, this would use threads for concurrent reading.
    // For the shadow deployment PoC, sequential poll is sufficient.
    loop {
        // Try reading both sockets (non-blocking attempt)
        if let Ok(stream) = UnixStream::connect(c_socket) {
            let mut reader = BufReader::new(stream);
            let mut buf = String::new();
            for _ in 0..5 {
                buf.clear();
                if reader.read_line(&mut buf).is_err() || buf.is_empty() {
                    break;
                }
                if let Some((source, sink)) = parse_line(&buf) {
                    apply_snapshot_update(&mut c_snapshot, source, sink);
                }
            }
        }

        if let Ok(stream) = UnixStream::connect(rust_socket) {
            let mut reader = BufReader::new(stream);
            let mut buf = String::new();
            for _ in 0..5 {
                buf.clear();
                if reader.read_line(&mut buf).is_err() || buf.is_empty() {
                    break;
                }
                if let Some((source, sink)) = parse_line(&buf) {
                    apply_snapshot_update(&mut rust_snapshot, source, sink);
                }
            }
        }

        // Compare and report
        let alerts = compare(&c_snapshot, &rust_snapshot);
        if alerts.is_empty() {
            if c_snapshot.source_bw.is_some() && rust_snapshot.source_bw.is_some() {
                println!("[shadow] OK — throughput: C={:.2}Mbps Rust={:.2}Mbps",
                    c_snapshot.source_bw.unwrap_or(0.0),
                    rust_snapshot.source_bw.unwrap_or(0.0));
            } else {
                println!("[shadow] waiting for stats from both engines...");
            }
        } else {
            println!("[shadow] ALERTS:");
            for alert in &alerts {
                println!("  ⚠  {}", alert);
            }
        }

        std::thread::sleep(compare_interval);
    }
}
