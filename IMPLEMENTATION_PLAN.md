# Blackgate Rust Migration — Implementation Plan

> Companion to `Rustroadmap.md`. File-level, function-by-function, build-command-by-build-command.

## Phase Dependencies

```
Phase 0 (feasibility) ─────────────────────────────────────────────────────┐
    ↓                                                                       │
Phase 1 (C modularize) → Phase 2 (IPC drop-in) → Phase 3 (skeleton)         │
                                                      ↓                      │
                                              Phase 4 (passthrough)          │
                                                      ↓                      │
                                              Phase 5 (failover)             │
                                                      ↓                      │
                                              Phase 6 (shadow deploy)        │
                                                      ↓                      │
                                              Phase 7 (SDI)                  │
                                                      ↓                      │
                                              Phase 8 (metadata) ←───────────┘
                                                      ↓
                                              Phase 9 (thumbnail)
                                                      ↓
                                              Phase 10 (stats/obs)
                                                      ↓
                                              Phase 11 (remove C)
```

---

## Phase 0 — Baseline, Freeze, Feasibility Spikes

### 0A — Behavior Freeze

**Files to create:**
```
docs/migration/frozen-schema.json
docs/migration/golden-logs/route-start-srt-srt.log
docs/migration/golden-logs/route-start-srt-udp.log
docs/migration/golden-logs/route-start-srt-sdi.log
docs/migration/golden-logs/source-disconnect.log
docs/migration/golden-logs/source-recovery.log
docs/migration/golden-logs/failover-switch.log
docs/migration/golden-logs/route-stop.log
docs/migration/baseline-metrics.md
docs/migration/parity-matrix.md
```

**Task 1: Capture IPC wire format**

Read these files and extract every format:
- `native/src/main.c` — stdin parsing
- `native/src/gst_pipeline.c` — all `g_print`/`printf`/`fprintf(stdout,...)` calls, all `print_stats` output
- `native/src/unix_socket.c` — `sendto` data format
- `lib/blackgate/route_handler.ex` — `handle_info({:stdout, ...})` parsing
- `lib/blackgate/unix_sock_handler.ex` — `handle_data` splitting logic

Document every event prefix with example output:
```
SOURCE_VALID:primary
SOURCE_VALID:secondary
SOURCE_INVALID:primary
SOURCE_INVALID:secondary
VIDEO_STREAM_TYPE:hevc
VIDEO_STREAM_TYPE:h264
VIDEO_STREAM_TYPE:mpeg2
meta_width:1920
meta_height:1080
meta_interlaced:0
meta_interlaced:1
meta_frame_rate:60000/1001
meta_frame_rate:30000/1001
FIRST_BUFFER_RECEIVED
SDI_AUDIO_SILENT:route-abc123
ROUTE_STARTED:route-abc123
ROUTE_STOPPED:route-abc123
```

Unix socket format (concatenated JSON):
```json
{"source":{"stream_id":"input-1","rtt_ms":12.5,"packets_lost":0,"packets_received":150,"bandwidth_mbps":25.3,"packets_retransmitted":0,"negotiated_latency_ms":120,"status":"healthy"}}stats_sink:{"id":"output-1","packets_sent":150,"bandwidth_mbps":25.3,"bytes_sent":197000}
```

**Task 2: Capture full route config**

Record the exact JSON structure accepted by `set_element_properties()` in `gst_pipeline.c`. Include:
- All SRT source properties
- All SRT sink properties
- All UDP source/sink properties
- SDI configuration block
- Secondary source config
- Failover config (auto-join, mode)

**Task 3: Record SDI config**

Capture:
- Device selection (`device-number`)
- Mode values (e.g., `1080i5994`, `1080p2997`, `auto`)
- Interlace mode values
- Framerate handling
- Audio channel layout for upmix (8ch matrix)

**Task 4: Golden log generation**

```bash
# Start route with SRT source + SRT sink
BLACKGATE_LOG=stdout mix phx.server &
# Capture all stdout from native pipeline for 60s

# Repeat for:
# - SRT + UDP sink
# - SRT + SDI sink
# - Source disconnect (kill source SRT stream)
# - Source recovery (restart source)
# - Failover switch (send switch-source command)
```

**Task 5: Baseline metrics**
```bash
# Throughput benchmark
rtk ./scripts/benchmark_passthrough.sh srt-srt 300  # 5 minutes

# Latency measurement
rtk ./scripts/measure_latency.sh srt-srt

# CPU/memory baseline
rtk ./scripts/profile_engine.sh native/build/blackgate_pipeline route-test
```

### 0B — GStreamer-RS Feasibility Spike

**Directory**: `native/rust/spike-srt-passthrough/`

**Files to create:**
```
native/rust/spike-srt-passthrough/Cargo.toml
native/rust/spike-srt-passthrough/src/main.rs
```

**`Cargo.toml`:**
```toml
[package]
name = "spike-srt-passthrough"
version = "0.1.0"
edition = "2021"

[dependencies]
gstreamer = "0.22"
gstreamer-app = "0.22"
gstreamer-sdp = "0.22"
anyhow = "1"
clap = { version = "4", features = ["derive"] }
```

**`main.rs` — Spike checklist:**

1. Create SRT source element:
```rust
let src = gst::ElementFactory::make("srtsrc")
    .property("uri", "srt://127.0.0.1:5000?mode=listener&latency=120")
    .build()?;
```

2. Create SRT sink element:
```rust
let sink = gst::ElementFactory::make("srtsink")
    .property("uri", "srt://127.0.0.1:5001?mode=caller&latency=120")
    .build()?;
```

3. Verify dynamic property injection works (replaces C `g_object_set` loop):
```rust
fn set_element_properties(el: &gst::Element, props: &serde_json::Value) -> Result<()> {
    if let serde_json::Value::Object(map) = props {
        for (key, val) in map {
            match val {
                serde_json::Value::String(s) => el.set_property(key, s.as_str()),
                serde_json::Value::Number(n) => {
                    if let Some(i) = n.as_i64() { el.set_property(key, i) }
                    else if let Some(f) = n.as_f64() { el.set_property(key, f) }
                }
                serde_json::Value::Bool(b) => el.set_property(key, b),
                _ => continue,
            };
        }
    }
    Ok(())
}
```

4. Run pipeline: `PLAYING` state, 30s run, verify data flows.

5. Test `gst::Bus::timed_pop_filtered()`:
```rust
let bus = pipeline.bus().unwrap();
loop {
    let msg = bus.timed_pop_filtered(gst::ClockTime::from_seconds(1), &[
        gst::MessageType::EOS,
        gst::MessageType::Error,
        gst::MessageType::Warning,
    ]);
    // handles message
}
```

6. Test `gst::Pad::add_probe()`:
```rust
src_sink_pad.add_probe(gst::PadProbeType::BUFFER, |_pad, info| {
    // first buffer = source valid
    gst::PadProbeReturn::Ok
});
```

7. Test `gst::Element::connect_pad_added()`:
```rust
decodebin.connect_pad_added(move |_db, src_pad| {
    // dynamic pad linking
});
```

8. Test DeckLink element access:
```rust
let sdi_sink = gst::ElementFactory::make("decklinkvideosink")
    .property("device-number", 0)
    .property("mode", 11) // 1080i5994
    .build()?;
```

**Go/No-go gating**: All 8 items must succeed. If any fails, document the failure and evaluate `gstreamer-sys` fallback.

### 0C — SDI Feasibility Spike

**Directory**: `native/rust/spike-sdi-sink/`

Test that `decklinkvideosink` + UYVY caps works from Rust:

```rust
// Build: decodebin → videorate → videoscale → videoconvert → decklinkvideosink
let decodebin = gst::ElementFactory::make("decodebin").build()?;
let videorate = gst::ElementFactory::make("videorate").build()?;
let videoscale = gst::ElementFactory::make("videoscale").build()?;
let videoconvert = gst::ElementFactory::make("videoconvert").build()?;

let sdi_sink = gst::ElementFactory::make("decklinkvideosink")
    .property("device-number", 0)
    .property("mode", 11)
    .build()?;

// Dynamic linking on decodebin pad-added
decodebin.connect_pad_added(move |_db, src_pad| {
    let caps = src_pad.current_caps().unwrap();
    // negotiate to UYVY or video/x-raw downstream
});
```

Test audio upmix access (may require `unsafe` with gstreamer-sys):
```rust
// Check if gstreamer-rs wraps gst_structure_get_array / gst_value_list_get_size
// If not, document the unsafe FFI section needed
```

**Go/No-go gating**: DeckLink sink accessible and configurable. If not, Phase 7 becomes hybrid (C for SDI).

### 0D — Build Toolchain Proof

**Files to create:**
```
native/rust/Cargo.toml          # workspace root
native/rust/engine-stub/Cargo.toml
native/rust/engine-stub/src/main.rs
```

**`native/rust/Cargo.toml`:**
```toml
[workspace]
members = ["engine-stub"]
resolver = "2"
```

**`engine-stub/src/main.rs`:**
```rust
fn main() {
    let route_id = std::env::args().nth(1).unwrap_or_else(|| "unknown".into());
    eprintln!("[rust-engine] started for route: {}", route_id);
    std::process::exit(0);
}
```

**Update `native/Makefile`:**
```makefile
RUST_TARGET_DIR = build/rust
RUST_BINARY = $(RUST_TARGET_DIR)/release/blackgate-engine

rust-build:
	cd rust && cargo build --release --target-dir ../$(RUST_TARGET_DIR)

all: rust-build c-build
```

**Update `lib/mix/tasks/compile_c_app.ex`:**
- Add `rust_build()` function after `c_build()`.
- Call `System.cmd("make", ["-C", "native", "rust-build"])`.

**Verify:**
```bash
rtk make install   # should build both C and Rust
rtk ls native/build/rust/release/blackgate-engine  # should exist
```

---

## Phase 1 — C Modularization

### Files to create:
```
native/src/ipc_protocol.h
native/src/ipc_protocol.c
native/src/stats_serialize.h
native/src/stats_serialize.c
native/src/metadata_parser.h
native/src/metadata_parser.c
native/src/thumbnail_worker.h
native/src/thumbnail_worker.c
native/src/pipeline_builder.h
native/src/pipeline_builder.c
native/src/failover_selector.h
native/src/failover_selector.c
native/tests/test_ipc_protocol.c
native/tests/test_stats_serialize.c
native/tests/test_metadata_parser.c
native/tests/test_failover_selector.c
```

### 1A — IPC Protocol Extraction

**Source**: `gst_pipeline.c` → `native/src/ipc_protocol.{h,c}`

**`ipc_protocol.h`:**
```c
#ifndef IPC_PROTOCOL_H
#define IPC_PROTOCOL_H

#include <cjson/cJSON.h>

typedef enum {
    CMD_START_ROUTE,
    CMD_STOP_ROUTE,
    CMD_SWITCH_SOURCE,
    CMD_JOIN_SECONDARY,
    CMD_LEAVE_SECONDARY,
    CMD_UNKNOWN
} IpcCommand;

typedef struct {
    IpcCommand cmd;
    cJSON *payload;  // caller must free
} ParsedCommand;

ParsedCommand ipc_parse_command(const char *line);
void ipc_emit_event(const char *format, ...);
void ipc_emit_stats_json(const char *json);
void ipc_cleanup(void);

#endif
```

**`ipc_protocol.c`:**
- Move stdin line reading and `cJSON_Parse` from `main.c` and `gst_pipeline.c` into `ipc_parse_command()`.
- Move all `printf`/`fprintf(stdout,...)` calls for events into `ipc_emit_event()`.
- Move `print_stats` JSON output into `ipc_emit_stats_json()`.

### 1B — Stats Serialization Extraction

**Source**: `gst_pipeline.c` → `native/src/stats_serialize.{h,c}`

**`stats_serialize.h`:**
```c
#ifndef STATS_SERIALIZE_H
#define STATS_SERIALIZE_H

#include <gst/gst.h>
#include <cjson/cJSON.h>

cJSON* stats_collect_source(GstElement *source, const char *stream_id);
cJSON* stats_collect_sink(GstElement *sink, const char *sink_id);
cJSON* stats_collect_health(const char *status, const char *source, const char *secondary);
char*  stats_serialize_route(cJSON *source_stats, cJSON *secondary_stats,
                              cJSON *sink_stats, cJSON *health);

#endif
```

**`stats_serialize.c`:**
- Extract `collect_sink_stats` function from `gst_pipeline.c`.
- Extract source stats collection (srtsrc `stats` property reading via `g_object_get`).
- Extract health struct construction.
- Produce the concatenated JSON format `{"source":{...}}stats_sink:{...}`.

### 1C — Metadata Parsing Extraction

**Source**: `gst_pipeline.c` → `native/src/metadata_parser.{h,c}`

```c
// metadata_parser.h
typedef struct {
    int width, height;
    int frame_rate_num, frame_rate_den;
    int interlaced;
    char codec[16];
    int stream_id;
    int stream_type;
} VideoMeta;

VideoMeta metadata_parse(GstPad *src_pad);
```

Move `on_tee_src_pad_added` pad probe body (SPS parsing, frame rate extraction, stream type detection) into `metadata_parse()`.

### 1D — Thumbnail Worker Extraction

**Source**: `gst_pipeline.c` → `native/src/thumbnail_worker.{h,c}`

```c
// thumbnail_worker.h
typedef struct ThumbnailWorker ThumbnailWorker;

ThumbnailWorker* thumbnail_start(GstElement *tee, const char *route_id);
void thumbnail_stop(ThumbnailWorker *tw);
```

### 1E — Pipeline Builder Extraction

**Source**: `gst_pipeline.c` → `native/src/pipeline_builder.{h,c}`

```c
// pipeline_builder.h
GstElement* pipeline_build(const char *route_id, const cJSON *config);
void pipeline_destroy(GstElement *pipeline);
```

Move `build_pipeline` function. Keep it clean: just element creation + property injection + pad linking.

### 1F — Failover Selector Extraction

**Source**: `gst_pipeline.c` → `native/src/failover_selector.{h,c}`

```c
// failover_selector.h
typedef struct FailoverSelector FailoverSelector;

FailoverSelector* failover_create(GstElement *primary, GstElement *secondary,
                                   GstElement *selector);
void failover_switch(FailoverSelector *fs, const char *target);
void failover_join_secondary(FailoverSelector *fs);
void failover_leave_secondary(FailoverSelector *fs);
void failover_destroy(FailoverSelector *fs);
```

### 1G — Test Files

Each module gets a cmocka test:

```c
// native/tests/test_ipc_protocol.c
#include <stdarg.h>
#include <setjmp.h>
#include <cmocka.h>
#include "../src/ipc_protocol.h"

static void test_parse_start_route(void **state) {
    ParsedCommand cmd = ipc_parse_command("{\"command\":\"start-route\",\"route_id\":\"test\"}");
    assert_int_equal(cmd.cmd, CMD_START_ROUTE);
    cJSON_Delete(cmd.payload);
}

int main(void) {
    const struct CMUnitTest tests[] = {
        cmocka_unit_test(test_parse_start_route),
    };
    return cmocka_run_group_tests(tests, NULL, NULL);
}
```

### 1H — Verification

```bash
# Build
rtk make -C native

# Run cmocka tests
rtk ./native/build/test_ipc_protocol
rtk ./native/build/test_stats_serialize
rtk ./native/build/test_metadata_parser

# Golden test: compare output before/after modularization
rtk ./scripts/diff_golden.sh  # runs old binary, new binary, diffs stdout
```

---

## Phase 2 — Rust IPC Drop-In

### Files to create:
```
native/rust/engine-ipc/Cargo.toml
native/rust/engine-ipc/src/lib.rs
native/rust/engine-ipc/src/command.rs
native/rust/engine-ipc/src/event.rs
native/rust/engine-ipc/src/stats.rs
native/rust/engine-ipc/src/unix_writer.rs
native/rust/engine-ipc/tests/command_tests.rs
native/rust/engine-ipc/tests/event_tests.rs
native/rust/engine-ipc/tests/stats_tests.rs
```

**Update `native/rust/Cargo.toml`:**
```toml
[workspace]
members = ["engine-ipc", "engine-stub"]
```

### 2A — Command Parser (`command.rs`)

```rust
// native/rust/engine-ipc/src/command.rs
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Deserialize)]
pub struct RawCommand {
    pub command: String,
    #[serde(flatten)]
    pub payload: Value,
}

#[derive(Debug, Clone)]
pub enum Command {
    StartRoute { config: Value },
    StopRoute,
    SwitchSource { target: String },
    JoinSecondary,
    LeaveSecondary,
}

pub fn parse_command(line: &str) -> Result<Command, String> {
    if line.trim().is_empty() {
        return Err("empty command".into());
    }
    let raw: RawCommand = serde_json::from_str(line)
        .map_err(|e| format!("JSON parse error: {}", e))?;
    match raw.command.as_str() {
        "start-route"     => Ok(Command::StartRoute { config: raw.payload }),
        "stop-route"      => Ok(Command::StopRoute),
        "switch-source"   => {
            let target = raw.payload["target"].as_str()
                .ok_or("missing target field")?.to_string();
            Ok(Command::SwitchSource { target })
        }
        "join-secondary"  => Ok(Command::JoinSecondary),
        "leave-secondary" => Ok(Command::LeaveSecondary),
        unknown => Err(format!("unknown command: {}", unknown)),
    }
}
```

### 2B — Event Formatter (`event.rs`)

Every event line must produce byte-identical output to C's `printf`:

```rust
// native/rust/engine-ipc/src/event.rs

pub fn emit_source_valid(source: &str) {
    println!("SOURCE_VALID:{}", source);
}

pub fn emit_source_invalid(source: &str) {
    println!("SOURCE_INVALID:{}", source);
}

pub fn emit_video_stream_type(codec: &str) {
    println!("VIDEO_STREAM_TYPE:{}", codec);
}

pub fn emit_meta_frame_rate(num: u32, den: u32) {
    println!("meta_frame_rate:{}/{}", num, den);
}

pub fn emit_meta_width(w: u32) {
    println!("meta_width:{}", w);
}

pub fn emit_meta_height(h: u32) {
    println!("meta_height:{}", h);
}

pub fn emit_meta_interlaced(interlaced: bool) {
    println!("meta_interlaced:{}", if interlaced { 1 } else { 0 });
}

pub fn emit_first_buffer() {
    println!("FIRST_BUFFER_RECEIVED");
}

pub fn emit_sdi_audio_silent(route_id: &str) {
    println!("SDI_AUDIO_SILENT:{}", route_id);
}

pub fn emit_route_started(route_id: &str) {
    eprintln!("route {} started", route_id); // match C's stderr behavior
}

pub fn emit_route_stopped(route_id: &str) {
    eprintln!("route {} stopped", route_id);
}
```

**Critical**: Verify each `println!` output matches C's `printf` exactly (newline, no trailing spaces).

### 2C — Stats Serializer (`stats.rs`)

```rust
use serde::Serialize;

#[derive(Serialize)]
pub struct SourceStats {
    pub stream_id: String,
    pub rtt_ms: f64,
    pub packets_lost: u64,
    pub packets_received: u64,
    pub bandwidth_mbps: f64,
    pub packets_retransmitted: u64,
    pub negotiated_latency_ms: u32,
    pub status: String,
}

#[derive(Serialize)]
pub struct SinkStats {
    pub id: String,
    pub packets_sent: u64,
    pub bandwidth_mbps: f64,
    pub bytes_sent: u64,
}

pub fn format_route_stats(
    source: &SourceStats,
    secondary: Option<&SourceStats>,
    sink: &SinkStats,
) -> String {
    let source_json = serde_json::to_string(source).unwrap();
    let sink_json = serde_json::to_string(sink).unwrap();
    // Exact C format: {"source":{...}}stats_sink:{...}
    format!("{{\"source\":{}}}stats_sink:{}", source_json, sink_json)
}
```

**Critical**: `serde_json` by default alphabetizes keys. Verify the key order matches C's `cJSON_Print`. If C uses insertion order, use `serde_json::to_string_pretty` or a custom serializer.

### 2D — Unix Socket Writer (`unix_writer.rs`)

```rust
use std::os::unix::net::UnixDatagram;
use std::path::Path;

pub struct UnixWriter {
    socket: UnixDatagram,
}

impl UnixWriter {
    pub fn new() -> Result<Self, std::io::Error> {
        let socket_path = "/tmp/hydra_unix_sock";
        let socket = UnixDatagram::unbound()?;
        socket.connect(socket_path)?;
        Ok(Self { socket })
    }

    pub fn send(&self, data: &str) -> Result<(), std::io::Error> {
        self.socket.send(data.as_bytes())?;
        Ok(())
    }
}
```

### 2E — IPC Loop (`lib.rs`)

```rust
use std::io::{self, BufRead, Write};

pub struct IpcLoop {
    unix_writer: UnixWriter,
    stdin: io::Stdin,
    stdout: io::Stdout,
}

impl IpcLoop {
    pub fn new() -> Result<Self, String> {
        Ok(Self {
            unix_writer: UnixWriter::new().map_err(|e| format!("unix socket: {}", e))?,
            stdin: io::stdin(),
            stdout: io::stdout(),
        })
    }

    pub fn run(&mut self, mut handler: impl FnMut(Command)) {
        let reader = io::BufReader::new(self.stdin.lock());
        for line in reader.lines() {
            match line {
                Ok(line) => match parse_command(&line) {
                    Ok(cmd) => handler(cmd),
                    Err(e) => eprintln!("cmd parse error: {}", e),
                },
                Err(_) => break, // EOF → exit
            }
        }
    }
}
```

### 2F — Tests

```rust
// native/rust/engine-ipc/tests/command_tests.rs
#[test]
fn test_parse_start_route() {
    let json = r#"{"command":"start-route","route_id":"test","source":{"protocol":"srt",...}}"#;
    let cmd = engine_ipc::command::parse_command(json).unwrap();
    assert!(matches!(cmd, Command::StartRoute { .. }));
}

#[test]
fn test_parse_switch_source() {
    let json = r#"{"command":"switch-source","target":"secondary"}"#;
    let cmd = engine_ipc::command::parse_command(json).unwrap();
    assert!(matches!(cmd, Command::SwitchSource { ref target } if target == "secondary"));
}

#[test]
fn test_unknown_command() {
    let json = r#"{"command":"nonexistent"}"#;
    assert!(engine_ipc::command::parse_command(json).is_err());
}

#[test]
fn test_empty_line() {
    assert!(engine_ipc::command::parse_command("").is_err());
}
```

```rust
// native/rust/engine-ipc/tests/stats_tests.rs
#[test]
fn test_format_route_stats() {
    let source = SourceStats {
        stream_id: "input-1".into(),
        rtt_ms: 12.5,
        packets_lost: 0,
        packets_received: 150,
        bandwidth_mbps: 25.3,
        packets_retransmitted: 0,
        negotiated_latency_ms: 120,
        status: "healthy".into(),
    };
    let sink = SinkStats {
        id: "output-1".into(),
        packets_sent: 150,
        bandwidth_mbps: 25.3,
        bytes_sent: 197000,
    };
    let result = format_route_stats(&source, None, &sink);
    assert!(result.contains("stats_sink:"));
    assert!(result.starts_with("{\"source\":{"));
}
```

### 2G — Integration with `engine-stub`

Replace the stub `main.rs` with IPC-only binary:

```rust
// native/rust/engine-stub/src/main.rs
fn main() -> Result<(), String> {
    let route_id = std::env::args().nth(1).unwrap_or_else(|| "unknown".into());
    eprintln!("[rust-engine] started for route: {}", route_id);

    let mut ipc = engine_ipc::IpcLoop::new()?;
    ipc.run(|cmd| {
        match cmd {
            engine_ipc::Command::StartRoute { config } => {
                eprintln!("[rust-engine] start-route received");
                engine_ipc::event::emit_route_started(&route_id);
                // Stub: no actual pipeline
            }
            engine_ipc::Command::StopRoute => {
                eprintln!("[rust-engine] stop-route received");
                engine_ipc::event::emit_route_stopped(&route_id);
                std::process::exit(0);
            }
            engine_ipc::Command::SwitchSource { target } => {
                eprintln!("[rust-engine] switch-source to {}", target);
            }
            _ => {}
        }
    });

    Ok(())
}
```

### 2H — Golden Test Verification

```bash
# Run C engine with golden input, capture stdout
rtk cat testdata/start-route.json | native/build/blackgate_pipeline route-test > /tmp/c-stdout.txt

# Run Rust IPC stub with same input, capture stdout
rtk cat testdata/start-route.json | native/build/rust/release/blackgate-engine route-test > /tmp/rust-stdout.txt

# Diff: should be byte-identical for event lines
rtk diff /tmp/c-stdout.txt /tmp/rust-stdout.txt
```

---

## Phase 3 — Engine Skeleton

### Files to create:
```
native/rust/engine-core/Cargo.toml
native/rust/engine-core/src/main.rs
native/rust/engine-core/src/engine.rs
native/rust/engine-config/Cargo.toml
native/rust/engine-config/src/lib.rs
native/rust/engine-config/src/route.rs
native/rust/engine-config/src/source.rs
native/rust/engine-config/src/sink.rs
native/rust/engine-config/src/sdi.rs
native/rust/engine-config/src/secondary.rs
```

**Update `native/rust/Cargo.toml`:**
```toml
[workspace]
members = ["engine-ipc", "engine-core", "engine-config"]
```

### 3A — Config Types (`engine-config`)

```rust
// native/rust/engine-config/src/source.rs
use serde::Deserialize;

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "snake_case")]
pub enum SourceProtocol { Srt, Udp }

#[derive(Debug, Deserialize, Clone)]
pub struct SourceConfig {
    pub protocol: SourceProtocol,
    pub host: String,
    pub port: u16,
    pub latency_ms: u32,
    #[serde(default)]
    pub mode: SrtMode,
    pub passphrase: Option<String>,
    pub streamid: Option<String>,
}

#[derive(Debug, Deserialize, Clone, Default)]
#[serde(rename_all = "snake_case")]
pub enum SrtMode { #[default] Listener, Caller, Rendezvous }
```

```rust
// native/rust/engine-config/src/sink.rs
#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "snake_case")]
pub enum SinkProtocol { Srt, Udp, Sdi }

#[derive(Debug, Deserialize, Clone)]
pub struct SinkConfig {
    pub protocol: SinkProtocol,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub sdi: Option<SdiConfig>,
    // ... SRT/UDP-specific fields
}
```

```rust
// native/rust/engine-config/src/route.rs
#[derive(Debug, Deserialize, Clone)]
pub struct RouteConfig {
    pub route_id: String,
    pub source: SourceConfig,
    pub sink: SinkConfig,
    pub secondary: Option<SecondaryConfig>,
}
```

### 3B — Engine Core (`engine-core`)

```rust
// native/rust/engine-core/src/engine.rs
use engine_ipc::command::Command;
use engine_config::route::RouteConfig;

pub enum EngineState {
    Idle,
    Running,
    Stopping,
}

pub struct BlackgateEngine {
    state: EngineState,
    route_id: String,
    config: Option<RouteConfig>,
    unix_writer: engine_ipc::unix_writer::UnixWriter,
}

impl BlackgateEngine {
    pub fn new(route_id: String) -> Result<Self, String> {
        Ok(Self {
            state: EngineState::Idle,
            route_id,
            config: None,
            unix_writer: engine_ipc::unix_writer::UnixWriter::new()
                .map_err(|e| format!("unix socket: {}", e))?,
        })
    }

    pub fn handle_command(&mut self, cmd: Command) {
        match cmd {
            Command::StartRoute { config } => {
                let route_config: RouteConfig = serde_json::from_value(config)
                    .expect("invalid route config");
                self.config = Some(route_config);
                self.state = EngineState::Running;
                engine_ipc::event::emit_route_started(&self.route_id);
                // Phase 4: build actual pipeline here
            }
            Command::StopRoute => {
                self.state = EngineState::Stopping;
                engine_ipc::event::emit_route_stopped(&self.route_id);
                // Phase 4: set pipeline to NULL
            }
            _ => {} // Phase 5: handle failover commands
        }
    }

    pub fn run_stats_loop(&self) {
        // Phase 10: emit stats every 1s here
    }
}
```

```rust
// native/rust/engine-core/src/main.rs
fn main() -> Result<(), String> {
    let route_id = std::env::args().nth(1).unwrap_or_else(|| "unknown".into());
    eprintln!("[rust-engine] started for route: {}", route_id);

    let mut engine = BlackgateEngine::new(route_id)?;
    let mut ipc = engine_ipc::IpcLoop::new()?;

    // Fetch init config from stdin (first message after start is always start-route)
    ipc.run(|cmd| engine.handle_command(cmd));

    Ok(())
}
```

### 3C — Verification

```bash
rtk cargo build --manifest-path native/rust/Cargo.toml
rtk ls native/build/rust/release/blackgate-engine

# Test start/stop cycle
echo '{"command":"start-route","route_id":"test","source":{"protocol":"srt","host":"127.0.0.1","port":5000,"latency_ms":120,"mode":"listener"},"sink":{"protocol":"srt","host":"127.0.0.1","port":5001,"latency_ms":120,"mode":"caller"}}' | native/build/rust/release/blackgate-engine test
# Expect: "route test started" on stderr, "ROUTE_STARTED:test" on stdout
```

---

## Phase 4 — Simple Passthrough

### Files to create:
```
native/rust/engine-gst/Cargo.toml
native/rust/engine-gst/src/lib.rs
native/rust/engine-gst/src/source.rs
native/rust/engine-gst/src/sink.rs
native/rust/engine-gst/src/pipeline.rs
native/rust/engine-gst/src/bus.rs
```

### 4A — Source Creation (`source.rs`)

```rust
use gst::prelude::*;
use engine_config::source::{SourceConfig, SourceProtocol};

pub fn create_source(config: &SourceConfig) -> Result<gst::Element, String> {
    let factory = match config.protocol {
        SourceProtocol::Srt => "srtsrc",
        SourceProtocol::Udp => "udpsrc",
    };

    let source = gst::ElementFactory::make(factory)
        .property("uri", &format_uri(config))
        // .property("latency", config.latency_ms as i32)
        .build()
        .map_err(|e| format!("source create failed: {}", e))?;

    Ok(source)
}

fn format_uri(config: &SourceConfig) -> String {
    match config.protocol {
        SourceProtocol::Srt => format!(
            "srt://{}:{}?mode={}&latency={}",
            config.host, config.port,
            config.mode.as_str(), config.latency_ms
        ),
        SourceProtocol::Udp => format!("udp://{}:{}", config.host, config.port),
    }
}
```

### 4B — Sink Creation (`sink.rs`)

```rust
pub fn create_sink(config: &SinkConfig) -> Result<gst::Element, String> {
    let (factory, uri) = match config.protocol {
        SinkProtocol::Srt => ("srtsink", format_srt_uri(config)),
        SinkProtocol::Udp => ("udpsink", format!("udp://{}:{}", config.host.as_deref().unwrap_or("127.0.0.1"), config.port.unwrap_or(5000))),
        SinkProtocol::Sdi => return Err("SDI not implemented yet".into()),
    };

    gst::ElementFactory::make(factory)
        .property("uri", &uri)
        .property("sync", false)
        .property("async", false)
        .build()
        .map_err(|e| format!("sink create failed: {}", e))
}
```

### 4C — Pipeline Assembly (`pipeline.rs`)

```rust
use gst::prelude::*;

pub fn build_passthrough_pipeline(
    source_config: &SourceConfig,
    sink_config: &SinkConfig,
) -> Result<gst::Pipeline, String> {
    gst::init().map_err(|e| format!("gst init: {}", e))?;

    let pipeline = gst::Pipeline::new(Some("blackgate-pipeline"));
    let source = create_source(source_config)?;
    let queue = gst::ElementFactory::make("queue")
        .property("max-size-time", 1_000_000_000u64) // 1s
        .property("leaky", 2i32) // downstream
        .build().unwrap();
    let sink = create_sink(sink_config)?;

    pipeline.add_many(&[&source, &queue, &sink])?;
    gst::Element::link_many(&[&source, &queue, &sink])?;

    Ok(pipeline)
}
```

### 4D — Bus Handling (`bus.rs`)

```rust
use gst::prelude::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

pub fn start_bus_watch(
    pipeline: gst::Pipeline,
    running: Arc<AtomicBool>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let bus = pipeline.bus().unwrap();
        while running.load(Ordering::Relaxed) {
            let msg = bus.timed_pop_filtered(
                Duration::from_secs(1).into(),
                &[gst::MessageType::Error, gst::MessageType::Eos, gst::MessageType::Warning],
            );
            match msg {
                Some(msg) => match msg.view() {
                    gst::MessageView::Eos(_) => {
                        eprintln!("[engine] EOS received");
                        running.store(false, Ordering::Relaxed);
                    }
                    gst::MessageView::Error(err) => {
                        eprintln!("[engine] ERROR: {} ({})", err.error(), err.debug().unwrap_or_default());
                        running.store(false, Ordering::Relaxed);
                    }
                    gst::MessageView::Warning(warn) => {
                        eprintln!("[engine] WARNING: {}", warn.debug().unwrap_or_default());
                    }
                    _ => {}
                },
                None => {} // timeout, continue
            }
        }
    })
}
```

### 4E — Verification

```bash
# Start SRT listener for test source
rtk srt-live-transmit srt://:5000 srt://:5001 &
SRT_PID=$!

# Start Rust engine
echo '{"command":"start-route",...}' | native/build/rust/release/blackgate-engine test &
ENGINE_PID=$!

# Wait 5s, check if process is alive and no errors
sleep 5
rtk kill -0 $ENGINE_PID  # should succeed

# Send stop-route
echo '{"command":"stop-route"}' > /proc/$ENGINE_PID/fd/0

# Cleanup
kill $SRT_PID 2>/dev/null
```

---

## Phase 5 — Failover Logic

### Files to create/modify:
```
native/rust/engine-core/src/selector.rs       (new)
native/rust/engine-core/src/failover.rs       (new)
native/rust/engine-gst/src/source.rs           (modify — dual source)
native/rust/engine-gst/src/pipeline.rs         (modify — input-selector)
native/rust/engine-ipc/src/command.rs          (modify — verify failover commands)
```

### 5A — Selector State (`selector.rs`)

```rust
use gst::prelude::*;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SourceTarget { Primary, Secondary }

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SecondaryState { Joined, Left }

pub struct SelectorState {
    selector: gst::Element,
    primary_pad: gst::Pad,
    secondary_pad: Option<gst::Pad>,
    active_source: SourceTarget,
    secondary_state: SecondaryState,
}

impl SelectorState {
    pub fn new(
        selector: gst::Element,
        primary_pad: gst::Pad,
        secondary_pad: Option<gst::Pad>,
    ) -> Self {
        // Set always-ok on inactive pads
        if let Some(ref pad) = secondary_pad {
            selector.request_pad_simple("sink_%u").unwrap(); // always-ok pad
        }
        Self {
            selector,
            primary_pad,
            secondary_pad,
            active_source: SourceTarget::Primary,
            secondary_state: SecondaryState::Left,
        }
    }

    pub fn switch_to(&mut self, target: SourceTarget) {
        self.active_source = target;
        let pad_name = match target {
            SourceTarget::Primary => "sink_0",
            SourceTarget::Secondary => "sink_1",
        };
        self.selector.set_property("active-pad", self.selector.pads().iter()
            .find(|p| p.name() == pad_name).unwrap());
        eprintln!("[selector] switched to {:?}", target);
    }

    pub fn join_secondary(&mut self) {
        if let Some(ref pad) = self.secondary_pad {
            // Link secondary pad via always-ok
            self.secondary_state = SecondaryState::Joined;
            eprintln!("[selector] secondary joined");
        }
    }

    pub fn leave_secondary(&mut self) {
        self.secondary_state = SecondaryState::Left;
        eprintln!("[selector] secondary left");
    }

    pub fn active(&self) -> SourceTarget { self.active_source }
    pub fn secondary_joined(&self) -> bool {
        self.secondary_state == SecondaryState::Joined
    }
}
```

### 5B — Source Pad Probes

Add probes to detect source health:

```rust
fn setup_source_probe(pad: &gst::GhostPad, source_name: &str) {
    let first_buffer = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let fb = first_buffer.clone();
    let name = source_name.to_string();

    pad.add_probe(gst::PadProbeType::BUFFER, move |_pad, _info| {
        if !fb.swap(true, std::sync::atomic::Ordering::Relaxed) {
            engine_ipc::event::emit_first_buffer();
            engine_ipc::event::emit_source_valid(&name);
        }
        gst::PadProbeReturn::Ok
    });

    pad.add_probe(gst::PadProbeType::EVENT_DOWNSTREAM, move |_pad, info| {
        if let Some(event) = info.event() {
            if event.type_() == gst::EventType::Eos {
                engine_ipc::event::emit_source_invalid(&name);
            }
        }
        gst::PadProbeReturn::Ok
    });
}
```

### 5C — Failover Command Handling

Update `engine.rs` `handle_command`:

```rust
Command::SwitchSource { target } => {
    let target = match target.as_str() {
        "primary" => SourceTarget::Primary,
        "secondary" => SourceTarget::Secondary,
        _ => { eprintln!("invalid switch target: {}", target); return; }
    };
    if let Some(ref mut selector) = self.selector {
        selector.switch_to(target);
        engine_ipc::event::emit_source_valid(target.as_str());
    }
}
Command::JoinSecondary => {
    if let Some(ref mut selector) = self.selector {
        selector.join_secondary();
    }
}
Command::LeaveSecondary => {
    if let Some(ref mut selector) = self.selector {
        selector.leave_secondary();
    }
}
```

### 5D — Verification

```bash
# Test failover switch
echo '{"command":"switch-source","target":"secondary"}' | native/build/rust/release/blackgate-engine test
# Expect: selector state change logged

# Integration test: dual source → switch → verify output stats show active source
rtk cargo test -p engine-gst --test failover_integration
```

---

## Phase 6 — Shadow Deployment

### Files to create/modify:
```
native/rust/engine-shadow/Cargo.toml          (new)
native/rust/engine-shadow/src/main.rs          (new)
native/rust/engine-shadow/src/comparator.rs    (new)
native/rust/engine-core/src/shadow.rs          (new)
lib/blackgate/shadow_supervisor.ex             (new)
```

### 6A — Shadow Engine Mode (`shadow.rs`)

```rust
// native/rust/engine-core/src/shadow.rs
pub fn run_shadow_mode(route_id: &str, config: &RouteConfig) -> Result<(), String> {
    // Build pipeline identically to normal mode
    let pipeline = build_passthrough_pipeline(&config.source, &config.sink)?;

    // BUT: replace sink with null sink for actual output
    // Keep a tee + tee branch to real sink for video comparison if desired

    // Emit stats to /tmp/hydra_unix_sock_rust
    let shadow_socket = UnixWriter::new_with_path("/tmp/hydra_unix_sock_rust")?;

    // Run identically
    pipeline.set_state(gst::State::Playing)?;
    // ...
}
```

### 6B — Comparator Daemon (`engine-shadow`)

```rust
// native/rust/engine-shadow/src/comparator.rs
struct MetricSnapshot {
    throughput_mbps: f64,
    packet_count: u64,
    latency_ms: f64,
}

impl MetricSnapshot {
    fn from_stats_json(json: &str) -> Self { /* parse */ }
}

fn compare(c_metrics: &MetricSnapshot, rust_metrics: &MetricSnapshot) -> Vec<String> {
    let mut alerts = vec![];
    let tp_diff = (c_metrics.throughput_mbps - rust_metrics.throughput_mbps).abs()
        / c_metrics.throughput_mbps.max(0.001) * 100.0;
    if tp_diff > 5.0 {
        alerts.push(format!("throughput deviation: {:.1}%", tp_diff));
    }
    let lat_diff = (c_metrics.latency_ms - rust_metrics.latency_ms).abs();
    if lat_diff > 10.0 {
        alerts.push(format!("latency deviation: {:.1}ms", lat_diff));
    }
    alerts
}
```

### 6C — Elixir Shadow Supervisor

```elixir
# lib/blackgate/shadow_supervisor.ex
defmodule Blackgate.ShadowSupervisor do
  use DynamicSupervisor

  # Spawned alongside RouteHandler when BLACKGATE_SHADOW_MODE=true
  # Spawns C pipeline (existing) for active traffic
  # Spawns Rust pipeline (new) with shadow flag for comparison

  def start_shadow(route_config) do
    # Launch Rust engine with --shadow
    rust_port = Port.open({:spawn_executable, rust_binary_path()}, [
      :binary, :exit_status,
      args: [route_config.route_id, "--shadow"],
      env: [{"BLACKGATE_SHADOW", "true"}]
    ])
    # Register for stats comparison
    {:ok, %{c_port: c_port, rust_port: rust_port, route_id: route_config.route_id}}
  end
end
```

---

## Phase 7 — SDI Output

### Files to create:
```
native/rust/engine-sdi/Cargo.toml
native/rust/engine-sdi/src/lib.rs
native/rust/engine-sdi/src/sink.rs
native/rust/engine-sdi/src/autodetect.rs
native/rust/engine-sdi/src/audio.rs
```

### 7A — SDI Sink (`sink.rs`)

```rust
use gst::prelude::*;

pub struct SdiSink {
    video_sink: gst::Element,  // decklinkvideosink
    audio_sink: gst::Element,  // decklinkaudiosink
    device_number: i32,
    mode: SdiMode,
}

#[derive(Debug, Clone)]
pub enum SdiMode {
    Auto,
    Explicit(SdiStandard),
}

#[derive(Debug, Clone, Copy)]
pub enum SdiStandard {
    Mode1080i5994,
    Mode1080i50,
    Mode720p5994,
    Mode720p50,
    Mode1080p2997,
    Mode1080p25,
    Mode1080p24,
    Mode1080p2398,
    Mode2160p2997,
    Mode2160p25,
}

impl SdiSink {
    pub fn new(device: i32, mode: SdiMode) -> Result<Self, String> {
        let video_sink = gst::ElementFactory::make("decklinkvideosink")
            .property("device-number", device)
            .property("sync", false)
            .build()
            .map_err(|e| format!("decklink video: {}", e))?;

        let audio_sink = gst::ElementFactory::make("decklinkaudiosink")
            .property("device-number", device)
            .build()
            .map_err(|e| format!("decklink audio: {}", e))?;

        Ok(Self { video_sink, audio_sink, device_number: device, mode })
    }
}
```

### 7B — Auto-Detect (`autodetect.rs`)

```rust
pub fn detect_mode(caps: &gst::Caps) -> Option<SdiStandard> {
    let s = caps.structure(0)?;
    let w = s.get::<i32>("width").ok()?;
    let h = s.get::<i32>("height").ok()?;
    let fps_num = s.get::<i32>("framerate").ok().map(|f| f.numer() as i32).unwrap_or(0);
    let fps_den = s.get::<i32>("framerate").ok().map(|f| f.denom() as i32).unwrap_or(1);
    let interlaced = s.get::<bool>("interlace-mode").ok().unwrap_or(false);

    match (w, h, fps_num, fps_den, interlaced) {
        (1920, 1080, 30000, 1001, true)  => Some(SdiStandard::Mode1080i5994),
        (1920, 1080, 25, 1, true)        => Some(SdiStandard::Mode1080i50),
        (1920, 1080, 30000, 1001, false) => Some(SdiStandard::Mode1080p2997),
        (1920, 1080, 25, 1, false)       => Some(SdiStandard::Mode1080p25),
        (1280, 720, 60000, 1001, false)  => Some(SdiStandard::Mode720p5994),
        (1280, 720, 50, 1, false)        => Some(SdiStandard::Mode720p50),
        (3840, 2160, 30000, 1001, false) => Some(SdiStandard::Mode2160p2997),
        (3840, 2160, 25, 1, false)       => Some(SdiStandard::Mode2160p25),
        _ => None,
    }
}
```

### 7C — Audio Upmix (`audio.rs`)

```rust
// May require gstreamer-sys raw FFI for GValue matrix
// Use unsafe block documented with safety invariants

pub unsafe fn setup_audio_upmix(audio_sink: &gst::Element, channels: i32) -> Result<(), String> {
    // Access GValue matrix API via gstreamer-sys
    // Equivalent to C code's gst_structure_get_array loop
    // ...
    Ok(())
}
```

### 7D — Verification

```bash
# Requires DeckLink hardware connected
echo '{"command":"start-route",...,"sink":{"protocol":"sdi","sdi":{"device":0,"mode":"auto"}}}' | native/build/rust/release/blackgate-engine test

# Visual check on SDI monitor
# Check stdout for SDI_MODE_DETECTED event
# Burn-in for 24h
```

---

## Phase 8 — Metadata Parsing

### Files to create:
```
native/rust/engine-metadata/Cargo.toml
native/rust/engine-metadata/src/lib.rs
native/rust/engine-metadata/src/ts.rs
native/rust/engine-metadata/src/h264.rs
native/rust/engine-metadata/src/hevc.rs
native/rust/engine-metadata/src/mpeg2.rs
native/rust/engine-metadata/src/bitreader.rs
native/rust/engine-metadata/tests/h264_tests.rs
native/rust/engine-metadata/tests/hevc_tests.rs
native/rust/engine-metadata/tests/mpeg2_tests.rs
native/rust/engine-metadata/tests/fuzz_targets/sps_fuzz.rs
```

### 8A — Bit Reader (`bitreader.rs`)

```rust
pub struct BitReader<'a> {
    data: &'a [u8],
    byte_pos: usize,
    bit_pos: u8,
}

impl<'a> BitReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, byte_pos: 0, bit_pos: 0 }
    }

    pub fn read_bits(&mut self, n: u8) -> Option<u32> {
        assert!(n <= 32);
        let mut result: u32 = 0;
        for _ in 0..n {
            if self.byte_pos >= self.data.len() { return None; }
            let bit = (self.data[self.byte_pos] >> (7 - self.bit_pos)) & 1;
            result = (result << 1) | bit as u32;
            self.bit_pos += 1;
            if self.bit_pos == 8 {
                self.bit_pos = 0;
                self.byte_pos += 1;
            }
        }
        Some(result)
    }

    pub fn read_ue(&mut self) -> Option<u32> {
        // Exp-Golomb coded unsigned integer
        let mut leading_zeros = 0u32;
        while self.read_bits(1)? == 0 { leading_zeros += 1; }
        let value = self.read_bits(leading_zeros as u8)?;
        Some((1u32 << leading_zeros) - 1 + value)
    }

    pub fn read_se(&mut self) -> Option<i32> {
        let ue = self.read_ue()?;
        if ue & 1 == 0 { Some(-((ue >> 1) as i32)) }
        else { Some(((ue + 1) >> 1) as i32) }
    }
}
```

### 8B — H.264 SPS Parser (`h264.rs`)

```rust
pub fn parse_h264_sps(nal_data: &[u8]) -> Option<VideoInfo> {
    // nal_data[0] = NAL header byte (forbidden_bit(1) + nal_ref_idc(2) + nal_unit_type(5))
    let nal_type = nal_data[0] & 0x1F;
    if nal_type != 7 { return None; } // not an SPS

    let rbsp = remove_emulation_prevention(&nal_data[1..]);
    let mut br = BitReader::new(&rbsp);

    let profile_idc = br.read_bits(8)?;
    let _constraint_flags = br.read_bits(8)?;
    let level_idc = br.read_bits(8)?;
    let _seq_parameter_set_id = br.read_ue()?;

    // ... chroma_format_idc, etc.

    let pic_width_in_mbs = br.read_ue()? as u32 + 1;
    let pic_height_in_map_units = br.read_ue()? as u32 + 1;
    let frame_mbs_only_flag = br.read_bits(1)?;

    let (width, height, interlaced) = if frame_mbs_only_flag == 0 {
        // interlaced — need field_pic_flag, bottom_field_flag, etc.
        (pic_width_in_mbs * 16, pic_height_in_map_units * 32, true)
    } else {
        (pic_width_in_mbs * 16, pic_height_in_map_units * 16, false)
    };

    // Frame cropping
    let frame_cropping_flag = br.read_bits(1)?;
    let (crop_left, crop_right, crop_top, crop_bottom) = if frame_cropping_flag == 1 {
        let l = br.read_ue()? as u32;
        let r = br.read_ue()? as u32;
        let t = br.read_ue()? as u32;
        let b = br.read_ue()? as u32;
        (l, r, t, b)
    } else { (0, 0, 0, 0) };

    let width = width - 2 * crop_left - 2 * crop_right;
    let height = height - 2 * crop_top - 2 * crop_bottom;

    Some(VideoInfo {
        width, height,
        frame_rate_num: 0, frame_rate_den: 1, // from VUI if present
        interlaced,
        codec: VideoCodec::H264,
    })
}
```

### 8C — Verification

```bash
rtk cargo test -p engine-metadata

# Fuzz test
rtk cargo fuzz run sps_fuzz -- -max_total_time=300

# Golden test: compare parsed output against C engine for same TS stream
```

---

## Phase 9 — Thumbnail Generation

### Files to create:
```
native/rust/engine-thumbnail/Cargo.toml
native/rust/engine-thumbnail/src/lib.rs
```

### 9A — Thumbnail Worker

```rust
// native/rust/engine-thumbnail/src/lib.rs
use gst::prelude::*;
use std::fs;
use std::thread;
use std::time::Duration;

pub struct ThumbnailWorker {
    pipeline: gst::Pipeline,
    appsink: gst::Element,
    preview_path: String,
}

impl ThumbnailWorker {
    pub fn new(source_tee: &gst::Element, route_id: &str) -> Result<Self, String> {
        let pipeline = gst::Pipeline::new(Some(&format!("thumb-{}", route_id)));

        let queue = gst::ElementFactory::make("queue")
            .property("leaky", 2i32).property("max-size-buffers", 1u32).build().unwrap();
        let decodebin = gst::ElementFactory::make("decodebin").build().unwrap();
        let videoscale = gst::ElementFactory::make("videoscale").build().unwrap();
        let capsfilter = gst::ElementFactory::make("capsfilter")
            .property("caps", &gst::Caps::builder("video/x-raw")
                .field("width", 320).field("height", 180).build())
            .build().unwrap();
        let videoconvert = gst::ElementFactory::make("videoconvert").build().unwrap();
        let jpegenc = gst::ElementFactory::make("jpegenc")
            .property("quality", 85i32).build().unwrap();
        let appsink = gst::ElementFactory::make("appsink")
            .property("max-buffers", 1u32).property("drop", true).build().unwrap();

        pipeline.add_many(&[&queue, &decodebin, &videoscale, &capsfilter, &videoconvert, &jpegenc, &appsink])?;
        gst::Element::link_many(&[&queue, &decodebin])?;
        // decodebin pad-added will handle the rest dynamically

        let preview_path = format!("/tmp/blackgate_preview_{}.jpg", route_id);

        // Periodic frame extraction thread
        let appsink_clone = appsink.clone();
        let preview_path_clone = preview_path.clone();
        thread::spawn(move || {
            loop {
                thread::sleep(Duration::from_secs(5));
                if let Ok(sample) = appsink_clone.pull_sample() {
                    let buffer = sample.buffer().unwrap();
                    let map = buffer.map_readable().unwrap();
                    let temp_path = format!("{}.tmp", preview_path_clone);
                    fs::write(&temp_path, &*map).ok();
                    fs::rename(&temp_path, &preview_path_clone).ok();
                }
            }
        });

        Ok(Self { pipeline, appsink, preview_path })
    }

    pub fn start(&self) -> Result<(), String> {
        self.pipeline.set_state(gst::State::Playing)
            .map_err(|e| format!("thumbnail pipeline: {}", e))
    }

    pub fn stop(&self) -> Result<(), String> {
        self.pipeline.set_state(gst::State::Null)?;
        let _ = fs::remove_file(&self.preview_path);
        Ok(())
    }
}
```

---

## Phase 10 — Stats & Health Reporting

### Files to modify:
```
native/rust/engine-core/src/stats.rs      (new)
native/rust/engine-core/src/engine.rs     (modify — add stats thread)
```

### 10A — Stats Collection

```rust
// native/rust/engine-core/src/stats.rs
use gst::prelude::*;

pub fn collect_source_stats(source: &gst::Element, stream_id: &str) -> SourceStats {
    let stats = source.property::<gst::Structure>("stats");
    SourceStats {
        stream_id: stream_id.into(),
        rtt_ms: stats.get::<f64>("rtt").unwrap_or(0.0),
        packets_lost: stats.get::<u64>("packets-lost").unwrap_or(0),
        packets_received: stats.get::<u64>("packets-received").unwrap_or(0),
        bandwidth_mbps: stats.get::<f64>("bandwidth").unwrap_or(0.0) / 1_000_000.0,
        packets_retransmitted: stats.get::<u64>("packets-retransmitted").unwrap_or(0),
        negotiated_latency_ms: stats.get::<u32>("negotiated-latency").unwrap_or(0),
        status: "healthy".into(),
    }
}

pub fn collect_sink_stats(sink: &gst::Element, sink_id: &str) -> SinkStats {
    let stats = sink.property::<gst::Structure>("stats");
    SinkStats {
        id: sink_id.into(),
        packets_sent: stats.get::<u64>("packets-sent").unwrap_or(0),
        bandwidth_mbps: stats.get::<f64>("bandwidth").unwrap_or(0.0) / 1_000_000.0,
        bytes_sent: stats.get::<u64>("bytes-sent").unwrap_or(0),
    }
}
```

### 10B — Stats Loop Integration

```rust
// In engine.rs
let source_el = self.source.clone();
let sink_el = self.sink.clone();
let unix_writer = std::sync::Arc::new(std::sync::Mutex::new(self.unix_writer));
let running = self.running.clone();
let route_id = self.route_id.clone();

std::thread::spawn(move || {
    while running.load(Ordering::Relaxed) {
        std::thread::sleep(Duration::from_secs(1));
        if let (Some(source), Some(sink)) = (source_el.as_ref(), sink_el.as_ref()) {
            let ss = stats::collect_source_stats(source, "input-1");
            let sk = stats::collect_sink_stats(sink, "output-1");
            let formatted = engine_ipc::stats::format_route_stats(&ss, None, &sk);
            unix_writer.lock().unwrap().send(&formatted).ok();
        }
    }
});
```

### 10C — Verification

```bash
# Verify exact format match with C golden log
rtk diff <(cat golden-log/stats-1s.txt) <(grep 'stats_sink:' /tmp/rust-stats-capture.txt)
```

---

## Phase 11 — Remove C

### Files to delete/archive:
```
native/src/*.c               → archive to native/archive/src/
native/src/*.h               → archive to native/archive/src/
native/decklink-sdk/          → archive to native/archive/decklink-sdk/
native/Makefile               → replace with Rust-only Makefile
native/build/blackgate_pipeline → delete
lib/mix/tasks/compile_c_app.ex  → delete, create compile_rust_app.ex
```

### Files to modify:
```
native/Makefile                    → cargo build --release only
mix.exs                            → compiler ordering, release steps
Makefile                           → make install: cargo build instead of make -C native
iso-builder/build.sh               → copy Rust binary path
iso-builder/files/blackgate.service → update ExecStart binary name
.github/workflows/build-iso.yml    → remove GCC dependencies
```

### Verification:

```bash
# Build from clean
rtk make clean && make install && make build

# Verify no C binary
rtk test -f native/build/blackgate_pipeline || echo "C binary removed ✓"

# Verify Rust binary present
rtk test -f _build/prod/rel/blackgate/bin/blackgate-engine || echo "Rust binary present ✓"

# Smoke test
rtk _build/prod/rel/blackgate/bin/blackgate start
# Wait 5s, check routes API
rtk curl -s http://localhost:4000/api/health
```

---

## CI/CD Integration

### GitHub Actions Updates

**`.github/workflows/test.yml`** (add Rust build + test):
```yaml
- name: Install Rust
  uses: actions-rs/toolchain@v1
  with:
    toolchain: stable
    profile: minimal

- name: Build Rust workspace
  run: cd native/rust && cargo build --release

- name: Test Rust workspace
  run: cd native/rust && cargo test

- name: Run golden tests
  run: ./scripts/verify_golden.sh
```

**`.github/workflows/build-iso.yml`** (update for Rust binary):
```yaml
- name: Install Rust
  run: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
```

---

## Testing Strategy Summary

| Phase | Test Type | Tool | Coverage Target |
|-------|-----------|------|----------------|
| 0 | Golden log capture | Bash scripts | All scenarios |
| 1 | C unit tests | cmocka | All extracted modules |
| 2 | IPC byte-identical | diff against C golden | 100% event lines |
| 3 | Config deserialization | Rust unit tests | All config variants |
| 4 | Pipeline integration | Rust integration tests | SRT→SRT, SRT→UDP |
| 5 | Failover scenario | Rust integration tests | All 4 modes, 8 scenarios |
| 6 | Shadow comparison | Comparator daemon | 14-day side-by-side |
| 7 | SDI hardware | Manual + visual QA | All broadcast standards |
| 8 | Metadata fuzzing | cargo-fuzz | 10M+ iterations |
| 9 | Thumbnail output | File size/timestamp check | 5s interval verification |
| 10 | Stats format | diff against C golden | Byte-identical |
| 11 | End-to-end | Full system smoke test | All route types |
