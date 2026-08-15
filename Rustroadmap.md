# Blackgate Rust Migration Roadmap (v2 — Corrected)

## Purpose
This document is the authoritative migration plan for moving Blackgate's native C media engine to Rust while keeping the existing Elixir control plane, GStreamer media runtime, and operational behavior stable. The roadmap is intentionally detailed so that an agentic implementation run can follow it step by step without guessing what to do next.

## Goals
- Migrate the native engine from C to Rust with zero downtime via shadow deployment.
- Preserve current route behavior, failover semantics, SDI output, stats reporting, and IPC wire format.
- Keep Elixir/Phoenix as the orchestration and operator API layer.
- Retain GStreamer as the actual multimedia pipeline runtime.
- Reduce memory-safety bugs, ownership bugs, and concurrency hazards in the native layer.
- Provide a staged path validated with benchmarks, integration tests, and burn-in on real hardware.

## Non-Goals
- Do not rewrite the entire application in one change.
- Do not change operator-facing behavior without a compatibility reason.
- Do not replace GStreamer.
- Do not remove Elixir from the control plane.
- Do not change the IPC wire format without a parallel Elixir migration (keep drop-in compatibility throughout).
- Do not rewrite Elixir failover state machine — Rust emits events, Elixir decides.

## Current Architecture Summary

Blackgate uses a polyglot design: Elixir/OTP handles lifecycle and orchestration, a native C engine builds and manages GStreamer pipelines, and the UI layer exposes route and monitoring controls.

### Native Engine Reality (The Monolith Problem)

The C engine is **not** modular. It consists of 3 files:

| File | Lines | Contents |
|------|-------|----------|
| `native/src/gst_pipeline.c` | 2,512 | Pipeline construction, SRT/UDP/SDI sinks, dual-ingest input-selector failover, MPEG-TS metadata parsing, JPEG thumbnail generation, 1s stats thread, health probes, `collect_sink_stats`, runtime command dispatch, element property injection from JSON config |
| `native/src/main.c` | ~150 | Entry point, stdin initialization, route_id from argv, compile-time param query via `#ifndef` guards |
| `native/src/unix_socket.c` | ~120 | AF_UNIX DGRAM client to `/tmp/hydra_unix_sock`, send-only, 64KB max datagram |

There is no separation between pipeline construction, stats, metadata, SDI, failover, or thumbnail logic. Everything is interleaved in one monolith. This means **Phase 1 of migration must be C modularization before Rust porting can begin**.

### IPC Protocol (Prefix-Based, No Framing)

3 IPC channels between Elixir and C:

| Channel | Direction | Format | Example |
|---------|-----------|--------|---------|
| stdin | Elixir → C | Newline-delimited JSON | `{"command":"switch-source","target":"primary"}` |
| stdout | C → Elixir | Prefix-matched lines | `SOURCE_VALID:primary`, `stats_source_stream_id:...` |
| Unix socket | C → Elixir | Newline-delimited JSON | `{"source":{...}}stats_sink:{...}` |

**Critical constraint**: The Elixir side (`unix_sock_handler.ex` and `route_handler.ex`) parses stdout lines by literal string prefix matching (`"stats_source_stream_id:"`, `"stats_sink:"`). The Unix socket handler splits concatenated JSON objects on known prefixes. **Changing this wire format requires Elixir changes.** The Rust replacement must produce byte-identical output for all prefix-based event lines and concatenated JSON stats blocks.

### Elixir Side Dependencies on C Engine

- `lib/blackgate/route_handler.ex` (1653L): Port.spawn → `native/build/blackgate_pipeline`, stdin JSON init, stdout line parser, watchdog (30s check / 60s stall), reconnect (10s retry / 180s giveup), circuit breaker (3 crashes → diagnose), failover engine (4 modes)
- `lib/blackgate/unix_sock_handler.ex`: Ranch listener on `/tmp/hydra_unix_sock`, parses stats, pushes to `RouteStatsRegistry` ETS
- `lib/mix/tasks/compile_c_app.ex`: Mix compiler task that runs `make -C native`
- `lib/blackgate/application.ex`: Indirect dependency via RouteHandler supervision
- `mix.exs`: Compiler ordering, release steps reference C binary path

### Build & Deploy Dependencies

- `Makefile`: `make install` compiles C via `native/Makefile`, `make build` copies binary to release
- `native/Makefile`: GCC + pkg-config (gstreamer-1.0, libcjson, srt, cmocka, gio-2.0) → `native/build/blackgate_pipeline`
- `iso-builder/build.sh`: Packages `_build/prod/rel/blackgate` release tarball into Ubuntu autoinstall ISO
- `.github/workflows/build-iso.yml`: CI builds ISO in `ubuntu:jammy` container

## Target End State

The desired end state is a layered system:
- Elixir remains the supervisor, API server, route coordinator, and **failover decision-maker**.
- Rust becomes the native media engine — pipeline construction, stats production, health monitoring.
- GStreamer remains the low-level media framework.
- C is removed entirely.

The ideal runtime separation:
- Elixir: Route lifecycle, persistence (Khepri), API, auth, failover logic (gen_statem), operator workflows.
- Rust: Pipeline construction, IPC, stats emission, health probes, metadata extraction, thumbnail generation.
- GStreamer: Actual packet/pipeline processing.

**Failover persistence boundary**: Rust owns pipeline-level source switching (`input-selector` active pad). Elixir owns failover **decisions** (which source to use, when to switch, which failover mode) and persists `active_source` to Khepri. Rust emits `SOURCE_VALID` / `SOURCE_INVALID` / `SOURCE_SWITCHED` events; Elixir's gen_statem reacts. This preserves the current architecture and avoids adding Rust→Khepri IPC.

## Migration Strategy

The migration must be incremental and prove feasibility of risky components before committing resources:

1. **Phase 0 — Baseline, Freeze, Feasibility Spikes**: Lock current behavior, prove gstreamer-rs works, prove SDI works in Rust.
2. **Phase 1 — C Modularization**: Extract IPC, stats, commands, metadata from the 2,512-line monolith into separable C modules.
3. **Phase 2 — Rust IPC Drop-In**: Replace C IPC layer with Rust while keeping exact wire format. Elixir sees zero change.
4. **Phase 3 — Engine Skeleton**: Crate layout, config parsing, typed structs, stub pipeline.
5. **Phase 4 — Simple Passthrough**: SRT→SRT, SRT→UDP with gstreamer-rs.
6. **Phase 5 — Failover Logic**: Dual-ingest, input-selector, source switching (Rust owns pipeline, Elixir owns decisions).
7. **Phase 6 — Shadow Deployment**: Run both C and Rust engines simultaneously, compare telemetry on real hardware for N days before cutover.
8. **Phase 7 — SDI Output**: DeckLink path — decodebin, video/audio negotiation, upmix, auto-detect.
9. **Phase 8 — Metadata Parsing**: MPEG-TS PAT/PMT, H.264/HEVC SPS, framerate inference.
10. **Phase 9 — Thumbnail Generation**: JPEG preview branch (not optional — Dashboard depends on it).
11. **Phase 10 — Stats & Observability**: Typed, versioned stats with monotonic counters.
12. **Phase 11 — Remove C**: Cleanup build, packaging, ISO builder. Archive C code.

This sequence front-loads feasibility proof and defers hardware-specific complexity until the Rust scaffolding is proven.

---

## Phase 0 — Baseline, Freeze, And Feasibility Spikes

### Objective
Lock down current behavior AND prove the Rust migration is technically viable before writing production code. This phase must answer three go/no-go questions before any commitment to later phases.

### Part A — Behavior Freeze

**Tasks:**

1. Capture all IPC wire formats byte-for-byte:
   - stdin commands: `{"command":"start-route",...}`, `{"command":"switch-source","target":"primary"}`
   - stdout event lines: `SOURCE_VALID:primary`, `SOURCE_INVALID:secondary`, `SDI_AUDIO_SILENT:<id>`, `VIDEO_STREAM_TYPE:hevc`, etc.
   - Unix socket stats: JSON concatenation format `{"source":{...}}stats_sink:{"id":...}`
2. Capture route JSON schemas accepted by `set_element_properties` (dynamic `g_object_set` from JSON keys).
3. Record SRT source properties (latency, mode, passphrase, streamid) and sink properties.
4. Record SDI sink configuration (device, mode, framerate, interlace, audio channels).
5. Record stats JSON structure for `{source}`, `{sink}`, and health outputs.
6. Capture failover behavior: primary/secondary source lifecycle, input-selector pad states, `always-ok`, `cache-buffers`, `drop-backwards`.
7. Save golden logs: startup, route start, route stop, source loss, sink loss, recovery, failover switch.
8. Create test fixtures for all JSON command/event payloads.

**Deliverables:**
- `docs/migration/frozen-schema.json` — all IPC schemas, wire format specification, byte-level examples.
- `docs/migration/golden-logs/` — representative log samples for every operational scenario.
- `docs/migration/baseline-metrics.md` — throughput, latency, CPU, memory for SRT→SRT, SRT→UDP, SRT→SDI.
- `docs/migration/parity-matrix.md` — test matrix mapping each C behavior to a future Rust parity check.

### Part B — GStreamer-RS Feasibility Spike

**Goal**: Prove gstreamer-rs can build and run the pipeline patterns Blackgate depends on.

**Tasks:**

1. Create `native/rust/spike-srt-passthrough/` — standalone Rust binary with gstreamer-rs.
2. Build SRT source → tee → SRT sink pipeline using gstreamer-rs typed builders.
3. Test `gst::Element::set_property()` for dynamic property injection — verify it can replace the C code's `g_object_set` pattern for SRT latency, mode, passphrase, streamid.
4. Test `gst::Bus::timed_pop_filtered()` — verify it matches C's `gst_bus_timed_pop_filtered` behavior.
5. Test `gst::Pad::add_probe()` — verify it can replicate the C `gst_pad_add_probe` pattern for source validation.
6. Test `gst::Element::connect_pad_added()` — verify it works for decodebin dynamic pad linking (needed for SDI).
7. Test element lookup: `gstreamer::ElementFactory::make("srtsrc")`, `decklinkvideosink`, `input-selector` — verify all required GStreamer plugins are accessible from Rust.

**Go/No-Go Decision**: If gstreamer-rs cannot handle dynamic property injection or DeckLink elements, evaluate fallback: `gstreamer-sys` raw FFI bindings (would retain the unsafe block pattern but gain Rust ownership for the rest of the codebase).

### Part C — SDI Feasibility Spike

**Goal**: Prove a DeckLink video sink can be created and configured in Rust BEFORE committing to Phase 7 SDI work.

**Tasks:**

1. Create `native/rust/spike-sdi-sink/` — standalone binary.
2. Build decodebin → videorate → videoscale → videoconvert → `decklinkvideosink` pipeline in Rust.
3. Test UYVY caps negotiation via gstreamer-rs `Caps` builder.
4. Test DeckLink device selection (`device-number` property).
5. Test mode selection (1080i59, 720p59, auto-detect).
6. Test GValue array/matrix API for audio channel upmix — verify gstreamer-rs provides equivalent access to `gst_structure_get_array` / `gst_value_list_get_size`.
7. If gstreamer-rs cannot access the GValue matrix API, document the required `unsafe` sections.

**Go/No-Go Decision**: If DeckLink sink creation fails in Rust, Phase 7 must become a hybrid approach — keep C pipeline for SDI, Rust for everything else with an IPC bridge.

### Part D — Build Toolchain Proof

**Goals**: Verify Rust can be integrated into the existing `make` + `mix` build chain.

**Tasks:**

1. Create `native/rust/` workspace with one stub crate.
2. Add Cargo build step to `native/Makefile`: `cargo build --release --target-dir build/rust`.
3. Update `mix.exs` compiler ordering to include Rust build after C build.
4. Verify release assembly picks up Rust binary from `native/build/rust/release/`.
5. Test on CI (ubuntu:jammy).

**Deliverable**: Working hybrid build chain producing both C and Rust binaries.

---

## Phase 1 — C Modularization

### Objective
Extract separable concerns from the 2,512-line `gst_pipeline.c` monolith into independent C modules. This is a prerequisite for porting — you cannot port an entangled mass piecemeal.

### Why This Phase Exists
The original roadmap assumed you could "port low-risk pieces first" (unix_socket.c, command parsing, stats). But these pieces are interleaved throughout the monolith: the stats thread calls `collect_sink_stats()` which walks the pipeline, the command parser calls `set_element_properties()` which uses `g_object_set`, the unix socket module shares `route_id` global state with the pipeline builder. You must detangle before you port.

### Extraction Targets

| Current Location | Extract To | Contents |
|-----------------|------------|----------|
| `gst_pipeline.c` scattered | `native/src/ipc_protocol.c/.h` | stdin command parsing, stdout event formatting, unix_socket.c send helpers |
| `gst_pipeline.c` scattered | `native/src/stats_serialize.c/.h` | `collect_sink_stats`, `print_stats`, stats JSON struct definitions |
| `gst_pipeline.c` scattered | `native/src/metadata_parser.c/.h` | `on_tee_src_pad_added`, `on_tee_sink_pad_added` pad probes, MPEG-TS PID/stream-type extraction |
| `gst_pipeline.c` scattered | `native/src/thumbnail_worker.c/.h` | Thumbnail tee branch, decodebin, jpegenc, preview file write thread |
| `gst_pipeline.c` scattered | `native/src/pipeline_builder.c/.h` | `build_pipeline`, `create_source`, `create_sink`, element creation, property injection |
| `gst_pipeline.c` scattered | `native/src/failover_selector.c/.h` | `setup_selector_pad_probe`, `switch_source`, source validation pad probes |

### Tasks (Per Module)

For each extraction target:

1. Separate the functions into the new `.c/.h` files.
2. Expose a clean C API (init, deinit, one function per operation).
3. Add unit tests (cmocka) for the extracted module in isolation.
4. Verify the integrated binary produces byte-identical IPC output to pre-extraction.
5. Update `native/Makefile` with new source files.

### Success Criteria
- `gst_pipeline.c` is reduced to pipeline orchestration and lifecycle only (target: <800 lines).
- Each extracted module has a documented API and unit tests.
- The C binary builds and passes all golden tests from Phase 0.
- Elixir sees zero behavioral change.

---

## Phase 2 — Rust IPC Drop-In Replacement

### Objective
Replace the C IPC layer (stdin/stdout/unix_socket) with a Rust binary while producing byte-identical wire output. Elixir's `route_handler.ex` and `unix_sock_handler.ex` must see zero difference.

### IPC Protocol Decision (FINAL)

**Wire format: Drop-in compatible. No versioned envelopes.**

We keep the exact current wire format:
- **stdin**: Newline-delimited JSON commands. Same verbs: `start-route`, `stop-route`, `switch-source`, `join-secondary`, `leave-secondary`.
- **stdout**: Prefix-matched text lines: `SOURCE_VALID:primary`, `VIDEO_STREAM_TYPE:hevc`, `meta_frame_rate:60000/1001`, etc.
- **Unix socket**: Concatenated JSON objects: `{"source":{...}}stats_sink:{"id":...}` — two JSON objects with literal `stats_sink:` separator.

**Rationale**: Adding versioned envelopes requires parallel Elixir changes. The C IPC format is stable, well-understood, and functionally adequate. We gain zero value from changing the wire format during migration. If protocol evolution is desired, do it as a separate project after Rust parity is proven.

### Crate: `engine-ipc`

**Location**: `native/rust/engine-ipc/`

**Module structure**:
```
engine-ipc/
├── Cargo.toml
└── src/
    ├── lib.rs              # Public API: IpcLoop::new(), .run()
    ├── command.rs          # Command enum, stdin reader, JSON deserialization
    ├── event.rs            # Event formatters (SOURCE_VALID, SOURCE_INVALID, etc.)
    ├── stats.rs            # Stats serialization, concatenated JSON output
    ├── unix_writer.rs      # AF_UNIX DGRAM client to /tmp/hydra_unix_sock
    └── tests/
        ├── command_tests.rs
        ├── event_tests.rs
        └── stats_tests.rs
```

### Tasks

1. **Implement command parser** (`command.rs`):
   - Read stdin line-by-line (newline-delimited JSON).
   - Deserialize into typed `Command` enum:
     ```rust
     enum Command {
         StartRoute { config: RouteConfig },
         StopRoute,
         SwitchSource { target: SourceTarget },
         JoinSecondary,
         LeaveSecondary,
     }
     ```
   - Reject unknown commands with a formatted error event on stdout.
   - Match C behavior: terminate process on stdin EOF.

2. **Implement event formatter** (`event.rs`):
   - Produce byte-identical output for every prefix-matched line:
     - `SOURCE_VALID:{source}\n`
     - `SOURCE_INVALID:{source}\n`
     - `VIDEO_STREAM_TYPE:{codec}\n`
     - `meta_frame_rate:{num}/{den}\n`
     - `meta_width:{w}\n`, `meta_height:{h}\n`, `meta_interlaced:{0|1}\n`
     - `SDI_AUDIO_SILENT:{route_id}\n` (if applicable)
     - `FIRST_BUFFER_RECEIVED\n`
   - Use a map of `Fn(&RouteState) -> Option<String>` for extensibility.

3. **Implement stats serializer** (`stats.rs`):
   - Produce the exact JSON concatenation format: `{"source":{...}}stats_sink:{...}`
   - `source` object keys: `stream_id`, `rtt_ms`, `packets_lost`, `packets_received`, `bandwidth_mbps`, `packets_retransmitted`, `negotiated_latency_ms`
   - `sink` object keys: `id`, `packets_sent`, `bandwidth_mbps`, `bytes_sent`
   - Include `route_health` object: `{status, source, secondary_source}`
   - Match the property name casing exactly (current uses underscores, keep it).

4. **Implement unix socket writer** (`unix_writer.rs`):
   - AF_UNIX DGRAM client to `/tmp/hydra_unix_sock`.
   - 64KB max datagram (match C limit).
   - Graceful handling when socket doesn't exist (don't crash, log warning).
   - Reconnect on `ECONNREFUSED` (socket listener restarted).

5. **Integration test harness**:
   - Spawn Rust IPC binary, send `start-route` command, verify stdout/stderr output matches golden logs byte-for-byte.
   - Test disconnect handling (close stdin, verify process exit code).
   - Test malformed JSON (verify error event emitted, process doesn't crash).
   - Test empty stdin line (verify process handles gracefully).

### Success Criteria
- Elixir `route_handler.ex` can spawn the Rust binary via `Port.open` and receive identical stdout lines.
- Elixir `unix_sock_handler.ex` receives identical Unix socket stats.
- All golden log comparisons from Phase 0 pass.
- Rust binary starts and stops cleanly with a stub pipeline (no GStreamer yet — IPC only).

---

## Phase 3 — Create The Rust Engine Skeleton

### Objective
Build the Rust workspace structure and application shell before porting pipeline details.

### Crate Layout

```
native/rust/
├── Cargo.toml              # Workspace: members = ["engine-core", "engine-ipc", ...]
├── engine-core/            # main(), top-level state machine, lifecycle
├── engine-ipc/             # (Phase 2) stdin/stdout/unix-socket
├── engine-config/          # Route JSON parsing, validation, typed configs
├── engine-gst/             # GStreamer pipeline utilities, element wrappers
├── engine-sdi/             # DeckLink-specific logic, mode negotiation (Phase 7)
├── engine-failover/        # Source selection, input-selector state (Phase 5)
├── engine-metadata/        # MPEG-TS parsing (Phase 8)
├── engine-thumbnail/       # JPEG preview generation (Phase 9)
└── engine-test/            # Integration and burn-in test binaries
```

### Tasks

1. **Create workspace** (`Cargo.toml` at `native/rust/`):
   - Dependencies: `gstreamer` (0.22+), `serde`, `serde_json`, `anyhow`, `tracing`, `tracing-subscriber`, `clap`.
   - Dev dependencies: `tempfile`, `assert-json-diff`.

2. **Implement `engine-config`** (`config.rs`):
   - Typed structs mirroring the current JSON route format:
     ```rust
     struct RouteConfig {
         route_id: String,
         source: SourceConfig,
         sink: SinkConfig,
         secondary: Option<SecondaryConfig>,
         sdi: Option<SdiConfig>,
     }
     struct SourceConfig {
         protocol: SourceProtocol, // Srt, Udp
         host: String,
         port: u16,
         latency_ms: u32,
         mode: SrtMode, // caller, listener, rendezvous
         passphrase: Option<String>,
         streamid: Option<String>,
     }
     struct SinkConfig {
         protocol: SinkProtocol, // Srt, Udp, Sdi
         // ... protocol-specific fields
     }
     ```
   - Deserialize from JSON using serde with `#[serde(rename_all = "snake_case")]`.
   - Validate required fields, reject unknown fields (strict mode, but accept extras the C code currently ignores).

3. **Implement `engine-core`** (`main.rs`):
   - Parse `route_id` from `argv[1]` (match C behavior).
   - Initialize tracing/logging to stderr.
   - Spawn IPC loop (stdin reader, event writer).
   - Main loop: wait for `StartRoute` command → build pipeline → enter running state.
   - Graceful shutdown: handle SIGTERM → send EOS to pipeline → join threads → exit 0.
   - Handle SIGPIPE (stdout closed) → exit cleanly.

4. **Stub pipeline**:
   - Implement a `BlackgateEngine` struct that wraps an `Option<gst::Pipeline>`.
   - On `StartRoute`, create a fakesrc → fakesink pipeline that emits a heartbeat event every 1s.
   - On `StopRoute`, set pipeline to NULL state and drop.

### Success Criteria
- `cargo build` succeeds in CI.
- `native/build/rust/release/blackgate-engine` binary exists.
- Binary starts with `route_id` argument, accepts stdin commands, emits events on stdout.
- `make build` produces both C and Rust binaries.
- `mix compile` succeeds with both binaries present.

---

## Phase 4 — Port Simple Passthrough Pipelines

### Objective
Prove the Rust engine can handle basic media cases with throughput/latency parity against C.

### Candidate Paths

1. SRT in → SRT out
2. SRT in → UDP out
3. SRT in → tee → SRT + UDP out (dual sink)

### Tasks

1. **Implement source creation in `engine-gst`**:
   - `create_srt_source(config: &SourceConfig) -> Result<gst::Element>`.
   - Set properties: `uri`, `latency`, `mode`, `passphrase`, `streamid`.
   - Add `pad_added` probe for source validation.
   - `create_udp_source(config) -> Result<gst::Element>`.

2. **Implement sink creation in `engine-gst`**:
   - `create_srt_sink(config: &SinkConfig) -> Result<gst::Element>`.
   - `create_udp_sink(config) -> Result<gst::Element>`.
   - Set properties: `uri`, `sync`, `async`, bandwidth overhead, latency.

3. **Implement pipeline assembly**:
   - Element creation → property injection → pad linking.
   - Queue elements between source and sink (leaky, max-size-time=1s).
   - Tee + queue for multi-sink branching.

4. **Implement bus message handling**:
   - EOS → emit `route-stopped` event.
   - ERROR → emit `route-error` event with message.
   - WARNING → log and continue.
   - STATE_CHANGED → log for debugging.

5. **Implement reconnect behavior**:
   - Source pad probe detects source disconnect.
   - Emit `SOURCE_INVALID:{source}` event.
   - Attempt reconnect after configurable delay (match C's 10s retry).

6. **Implement stats collection thread**:
   - 1s interval thread (matching C's `print_stats` thread).
   - Collect source stats: `gst::Structure` from source element `stats` property.
   - Collect sink stats: `gst::Structure` from sink element `stats` property.
   - Serialize and send to Unix socket.

### Test Scenarios

1. Start route with valid SRT source and SRT sink — verify 30s stable throughput.
2. Start route with valid SRT source and UDP sink — verify packet delivery.
3. Disconnect source mid-stream — verify `SOURCE_INVALID` event, process doesn't crash.
4. Restart route after disconnect — verify recovery.
5. Start route with dual SRT+UDP sink — verify both sinks receive data.

### Success Criteria
- Throughput within 5% of C engine for same input.
- Latency within 10% of C engine.
- Logs and stats output byte-identical to C engine golden logs.
- 1-hour burn-in with no crashes, memory leaks (<1MB growth), or silent frame drops.

---

## Phase 5 — Port Failover Logic

### Objective
Port dual-ingest and input-selector source switching to Rust. Rust owns pipeline-level switching; Elixir owns failover decisions and Khepri persistence.

### Architecture Boundary (FINAL)

```
Elixir (gen_statem)                    Rust (engine-failover)
┌─────────────────────┐   stdin      ┌──────────────────────────────┐
│ failover_decision() │────────────▶│ switch_source(target)         │
│ Khepri persistence  │             │ input-selector pad swap       │
│ circuit_breaker()   │◀────────────│ SOURCE_VALID / SOURCE_INVALID │
│ 4-mode engine       │   stdout     │ cache-buffers management      │
└─────────────────────┘             └──────────────────────────────┘
```

- **Elixir decides**: Which source to use (primary/secondary), when to switch, failover mode selection, Khepri persistence of `active_source`.
- **Rust executes**: `input-selector` active-pad switching, `always-ok` pad configuration, `cache-buffers`/`drop-backwards` semantics, source health probing, `SOURCE_VALID`/`SOURCE_INVALID` event emission.
- **Rust does NOT decide**: Failover policy, switch timing, circuit breaker thresholds. Those stay in Elixir's gen_statem.

### Tasks

1. **Implement dual source creation**:
   - `create_primary_source(config)` → srtsrc element with active pad probe.
   - `create_secondary_source(config)` → srtsrc element (identical structure, different config).
   - Both feed into `input-selector` element.

2. **Implement input-selector state** (`engine-failover`):
   ```rust
   struct SelectorState {
       primary_pad: gst::Pad,
       secondary_pad: gst::Pad,
       active_source: SourceTarget, // Primary, Secondary
       secondary_joined: bool,
       cache_buffers: bool,
   }
   ```
   - `switch_to(target: SourceTarget)` → set `active-pad` property on selector.
   - `join_secondary()` → link secondary pad with `always-ok`=true.
   - `leave_secondary()` → unlink secondary pad.

3. **Implement pad probe behavior**:
   - Primary pad probe: on first buffer → emit `SOURCE_VALID:primary`. On disconnect → emit `SOURCE_INVALID:primary`.
   - Secondary pad probe: same logic, `SOURCE_VALID:secondary` / `SOURCE_INVALID:secondary`.
   - Pad probe must NOT block the pipeline — use `gst::PadProbeReturn::Ok`.

4. **Implement command dispatch**:
   - `switch-source {target: primary|secondary}` → call `selector.switch_to(target)`.
   - `join-secondary` → call `selector.join_secondary()`.
   - `leave-secondary` → call `selector.leave_secondary()`.

5. **Implement selector property persistence**:
   - `always-ok` pads: set on all inactive pads to keep them alive.
   - `sync-mode=1`: match C's sync mode for active pad.
   - `cache-buffers=true`, `drop-backwards=true`: match C's buffer handling.

### Design Requirements

- Selector state is explicit, testable, and logged on every transition.
- Switching sources is deterministic — no race condition between pad probe and active-pad change.
- Secondary source can be held idle (`leave-secondary` state) without consuming unnecessary bandwidth.
- A failed source does not poison the entire route if the alternate source is healthy.
- Rust does NOT auto-failover — it only executes explicit switch commands from Elixir. This preserves Elixir's failover mode logic (maintain-primary, maintain-stability, manual-switchback, manual).

### Test Scenarios

1. Start with primary only → verify primary receives data, secondary is not connected.
2. Start with primary + secondary, auto-join enabled → verify both sources linked.
3. Start with primary + secondary, auto-join disabled → verify only primary linked.
4. `switch-source secondary` → verify active pad changes, `SOURCE_SWITCHED:secondary` event emitted.
5. `switch-source primary` → verify active pad switches back.
6. Simulate primary disconnect → verify `SOURCE_INVALID:primary` emitted, route stays alive on secondary.
7. Simulate secondary disconnect → verify `SOURCE_INVALID:secondary` emitted, route stays alive on primary.
8. Both sources disconnect → verify both INVALID events emitted, route error reported.

### Success Criteria
- All 4 failover modes work identically to C engine (Elixir gen_statem logic is unchanged, Rust executes).
- State transitions are logged and observable in stats output.
- Zero-glitch switching (no black frames, no audio pops during active-pad change).
- 24-hour burn-in with periodic source switch — no selector deadlocks or memory leaks.

---

## Phase 6 — Shadow Deployment (A/B Testing)

### Objective
Run both C and Rust engines simultaneously on the same live streams for N days, comparing telemetry, before migrating production traffic. This is the phase that prevents "it worked in CI but fails in production" failures.

### Why This Phase Exists
Live streaming systems cannot be validated in CI alone. A pipeline can look healthy (all pads linked, no errors on bus) while silently dropping frames, introducing latency drift, or producing subtly wrong output. You must compare runtime behavior on real hardware with real streams before cutting over. The original roadmap had no transition phase between "Rust passes tests" and "remove C" — that's reckless for a broadcast system.

### Shadow Mode Architecture

```
                    ┌─────────────────┐
                    │  Elixir Control  │
                    │     Plane        │
                    └──────┬──────┬────┘
                           │      │
              ┌────────────┘      └────────────┐
              ▼                                ▼
     ┌────────────────┐              ┌────────────────┐
     │  C Engine       │              │  Rust Engine    │
     │  (active, on-air)│              │  (shadow, mute) │
     └───────┬────────┘              └───────┬────────┘
             │                               │
             ▼                               ▼
     ┌────────────────┐              ┌────────────────┐
     │  SRT/UDP sinks  │              │  /dev/null or   │
     │  (real output)  │              │  metrics sink   │
     └────────────────┘              └────────────────┘

Stats comparison:
  C engine stats ──┐
                   ├──► Comparison daemon ──► Metrics (Prometheus/VictoriaMetrics)
  Rust engine stats┘
```

### Tasks

1. **Create comparison daemon** (`native/rust/engine-shadow/`):
   - Reads both engines' stats from Unix sockets (`/tmp/hydra_unix_sock` and `/tmp/hydra_unix_sock_rust`).
   - Compares per-second: throughput, packet count, latency.
   - Alerts on deviation >5% (throughput), >10% (latency).
   - Exports comparison metrics to VictoriaMetrics via `Metrics.Connection` (new Elixir module or direct InfluxDB line protocol from Rust).

2. **Implement shadow mode in engine-core**:
   - `--shadow` CLI flag: when set, Rust engine connects to the same SRT sources as C but sends output to `/dev/null` (or a metrics-only sink) instead of real SRT/UDP/SDI sinks.
   - Shadow engine still emits full stats — the comparison daemon captures them.
   - Shadow engine reads the same stdin init JSON as C (Elixir sends identical config to both).

3. **Elixir shadow mode support**:
   - New `Blackgate.ShadowSupervisor` module (feature flag behind `BLACKGATE_SHADOW_MODE=true` env var).
   - Spawns both C and Rust engines for each route with identical config.
   - Does NOT route operator-facing stats from shadow engine — only comparison daemon sees it.

4. **Burn-in procedure**:
   - Week 1: 1 route in shadow mode, 24/7 monitoring. Compare every metric.
   - Week 2: 3 routes in shadow mode. Vary route types: SRT→SRT, SRT→UDP, SRT→SDI.
   - Week 3: All routes in shadow mode. Include failover scenarios.
   - Cutover decision: zero deviations >5% for 7 consecutive days.

### Shadow Mode Configuration

```json
{
  "shadow": {
    "enabled": true,
    "comparison_interval_secs": 1,
    "alert_threshold": {
      "throughput_pct": 5.0,
      "latency_pct": 10.0,
      "packet_loss_pct": 1.0
    },
    "metrics_sink": "victoria_metrics",
    "output_sink": "null"  // or "file:/tmp/shadow_output.ts" for visual comparison
  }
}
```

### Cutover Procedure

1. Stop C engine for route, Rust engine takes over.
2. Monitor for 1 hour — if any issue, revert to C (Rust binary kept as backup).
3. After 24h clean, mark route as "Rust primary, C removed".
4. Repeat per route until all routes are on Rust.

### Success Criteria
- Shadow mode runs for ≥14 consecutive days with zero deviations beyond threshold.
- Comparison metrics confirm throughput, latency, and packet counts match within tolerance.
- Operators can view comparison dashboard during shadow period.
- Cutover procedure tested at least once on a non-critical route before batch migration.

---

## Phase 7 — Port SDI Output

### Objective
Move the DeckLink/SDI output path to Rust. This is the most hardware-sensitive phase and is deferred until the Rust engine scaffolding, passthrough, and failover are proven in shadow mode.

### SDI Feasibility Pre-Check
Phase 0 SDI spike must have confirmed:
- `decklinkvideosink` element is accessible from gstreamer-rs.
- UYVY caps negotiation works.
- GValue matrix API for audio upmix is accessible (with documented `unsafe` sections if needed).
- If spike failed: Phase 7 becomes hybrid — keep C pipeline for SDI, Rust for passthrough + failover.

### Tasks

1. **Port decodebin dynamic linking**:
   - `tsdemux` → `decodebin` (video) + `decodebin` (audio).
   - `connect_pad_added` on decodebin elements.
   - Caps negotiation: UYVY for video, raw audio for audio path.

2. **Port video processing chain**:
   - `videorate` → `videoscale` → `videoconvert` → `decklinkvideosink`.
   - Set properties: `sync=false` on video elements, `identity sync=true` pacing.
   - Framerate matching: `videorate` `rate` property from detected source framerate.
   - Interlace handling: `interlace-mode` property on `decklinkvideosink`.

3. **Port audio processing chain**:
   - `audioconvert` → `audioresample` → `audiorate` → `decklinkaudiosink`.
   - 8ch audio upmix via GValue matrix API (use `unsafe` block with gstreamer-sys if gstreamer-rs doesn't wrap it).
   - Channel mask configuration.

4. **Port DeckLink device selection**:
   - `device-number` property on both video and audio sinks.
   - Device validation: emit error event if device number is invalid.

5. **Port auto-detect mode**:
   - Read source caps from decodebin pad probe.
   - Map to broadcast standard (1080i59, 1080i50, 720p59, 720p50, 1080p29, 1080p25).
   - Fallback to configured default mode if auto-detect fails.
   - Emit `SDI_MODE_DETECTED:{mode}` event.

6. **Port health probes**:
   - Video flow probe: detect silent/stalled video. Emit `SDI_VIDEO_SILENT`.
   - Audio flow probe: detect silent audio. Emit `SDI_AUDIO_SILENT:{route_id}`.
   - Emit health events with same format as C engine.

### Test Scenarios

1. Direct progressive source (1080p29) to SDI output — verify visible output on DeckLink monitor.
2. Direct interlaced source (1080i59) — verify deinterlacing or passthrough.
3. Auto-detect matching a broadcast standard — verify correct mode selected.
4. Auto-detect falling back to configured defaults — verify fallback triggers.
5. Audio present → verify both channels audible on SDI monitor.
6. Audio absent → verify `SDI_AUDIO_SILENT` event, no crash.
7. DeckLink device absent → verify graceful error, process doesn't crash.
8. Invalid device number → verify error event, process stays alive.
9. 1080p50 source → 1080i50 output (framerate conversion) — verify no judder.
10. 24-hour SDI burn-in — no dropped frames, no A/V drift >1 frame.

### Success Criteria
- SDI output visually matches C engine on same source.
- Audio/video sync maintained within 1 frame over 24h.
- Auto-detect behavior matches C engine for all supported broadcast standards.
- Audio upmix produces identical channel layout to C engine.
- Zero SIGSEGV or pipeline deadlocks in SDI path during 24h burn-in.

---

## Phase 8 — Port Metadata Parsing

### Objective
Move MPEG-TS parsing and video metadata extraction into Rust with safe buffer handling.

### Tasks

1. **Port TS parsing**:
   - PAT (Program Association Table) — PID 0x00.
   - PMT (Program Map Table) — PID from PAT.
   - Stream type detection: 0x1B (H.264), 0x24 (HEVC), 0x02 (MPEG-2).
   - PES header parsing for stream identification.

2. **Port H.264 SPS parsing**:
   - NAL unit type 7 (SPS) extraction.
   - Parsing: profile_idc, level_idc, pic_width_in_mbs, pic_height_in_map_units, frame_cropping.
   - Width/height calculation with cropping offsets.
   - Detect interlaced (`frame_mbs_only_flag=0`).

3. **Port HEVC SPS parsing**:
   - NAL unit type 33 (VPS) and 34 (SPS).
   - Parsing: general_profile_idc, general_level_idc, pic_width_in_luma_samples, pic_height_in_luma_samples.
   - Conformance window cropping.
   - Interlace detection from `general_progressive_source_flag`.

4. **Port MPEG-2 sequence header parsing**:
   - Sequence header code (0x000001B3).
   - Horizontal/vertical size, aspect ratio, framerate code.
   - Interlace detection from `progressive_sequence`.

5. **Implement safe buffer handling**:
   - Use Rust slices with bounds checking (replace C's raw pointer arithmetic).
   - `read_u8`, `read_u16_be`, `read_u32_be` helpers with `Option<T>` return (no panics on truncated data).
   - Bit-level reading: `read_bits(&self, n: u8) -> Option<u32>`.
   - Exhaustive match on all stream types — unknown types produce `Unknown(u8)` variant, not panic.

6. **Implement framerate inference**:
   - H.264: from `vui_parameters_present_flag` → `num_units_in_tick` / `time_scale`.
   - HEVC: from `vui_parameters` → `vui_num_units_in_tick` / `vui_time_scale`.
   - MPEG-2: from `frame_rate_code` lookup table.
   - Emit `meta_frame_rate:{num}/{den}` event (same format as C).

### Crate: `engine-metadata`

```rust
pub struct VideoInfo {
    pub width: u32,
    pub height: u32,
    pub frame_rate_num: u32,
    pub frame_rate_den: u32,
    pub interlaced: bool,
    pub codec: VideoCodec,
}

pub enum VideoCodec { H264, HEVC, Mpeg2, Unknown(u8) }

pub fn parse_ts_packet(buf: &[u8]) -> Option<TsPacket>;
pub fn parse_pat(payload: &[u8]) -> Option<PatInfo>;
pub fn parse_pmt(payload: &[u8]) -> Option<PmtInfo>;
pub fn parse_h264_sps(nal: &[u8]) -> Option<VideoInfo>;
pub fn parse_hevc_sps(nal: &[u8]) -> Option<VideoInfo>;
pub fn parse_mpeg2_seq_header(data: &[u8]) -> Option<VideoInfo>;
```

### Test Scenarios

1. Valid H.264 1080p29.97 SPS — verify width=1920, height=1080, framerate=30000/1001.
2. Valid HEVC 2160p59.94 SPS — verify width=3840, height=2160.
3. Valid MPEG-2 720p59 sequence header — verify width=1280, height=720.
4. Interlaced H.264 1080i — verify `interlaced=true`.
5. Truncated SPS (buffer cut at boundary) — verify `None` return, no panic.
6. Corrupted NAL unit — verify graceful handling, no UB.
7. Unknown stream type — verify `VideoCodec::Unknown(n)` return.
8. Random bytes (fuzzing) — verify no panic, no OOB access.

### Success Criteria
- Metadata detection matches C engine for all golden input samples.
- Fuzzing with `cargo-fuzz` on all parser functions — zero crashes on 10M+ iterations.
- No `unsafe` code in parser path.
- Elixir receives identical `VIDEO_STREAM_TYPE`, `meta_width`, `meta_height`, `meta_frame_rate`, `meta_interlaced` events.

---

## Phase 9 — Port Thumbnail Generation

### Objective
Move the JPEG thumbnail preview branch to Rust. **This is not optional** — the Dashboard's live preview panel depends on `/tmp/blackgate_preview_<id>.jpg` being written every 5s.

### Current C Behavior
- Tee branch after source → leaky queue → decodebin → videoscale (320×180) → videoconvert → jpegenc → appsink.
- Separate thread: every 5s pull a sample from appsink, write to `/tmp/blackgate_preview_<id>.jpg`.
- Atomic rename: write to temp file → `rename()` to target path (avoids partial reads by Dashboard).

### Tasks

1. **Implement thumbnail branch** (`engine-thumbnail`):
   - Add tee element after source.
   - Branch: `queue (leaky, max-size-buffers=1)` → `decodebin` → `videoscale (320×180)` → `videoconvert` → `jpegenc (quality=85)` → `appsink (max-buffers=1, drop=true)`.

2. **Implement periodic frame extraction**:
   - Thread with `std::thread::sleep(Duration::from_secs(5))`.
   - Pull sample from appsink via `gst::Sample`.
   - Map buffer → write bytes to temp file.
   - Atomic rename: `std::fs::rename(temp_path, preview_path)`.
   - Cleanup temp files on route stop.

3. **Verify no interference**:
   - Thumbnail branch must not impact main route throughput.
   - Queue before decodebin must be `leaky` (drop old frames, don't buffer).
   - Thumbnail thread must yield if appsink is empty (no busy-wait).

### Test Scenarios

1. Route start → verify preview file created within 10s.
2. Verify preview dimensions are 320×180.
3. Verify preview updates every ~5s (timestamp check).
4. Route stop → verify preview file cleaned up.
5. Concurrent thumbnail + high-bitrate passthrough → verify no frame drops in main route.

### Success Criteria
- Preview file appears at `/tmp/blackgate_preview_{route_id}.jpg` within 5s of route start.
- Dashboard displays live preview from Rust-generated thumbnails.
- Main route throughput unaffected by thumbnail branch (benchmarked vs. C engine).
- No file handle leaks during 24h burn-in.

---

## Phase 10 — Port Stats And Health Reporting

### Objective
Move all runtime observability into the Rust engine with typed, versioned structures.

### Tasks

1. **Mirror source stats**:
   - From `srtsrc` element: `stats` property → `gst::Structure`.
   - Extract: `packets-received`, `packets-lost`, `packets-retransmitted`, `packets-sent`, `bytes-received`, `rtt`, `bandwidth`, `negotiated-latency`.
   - Serialize to JSON matching current C format exactly.

2. **Mirror sink stats**:
   - From `srtsink` / `udpsink`: `stats` property.
   - Extract: `packets-sent`, `bytes-sent`, `bandwidth`.
   - SDI sink stats: videorate-based counter as proxy.

3. **Emit lifecycle events**:
   - `route-started` → when pipeline reaches PLAYING state.
   - `route-stopped` → when pipeline reaches NULL state.
   - `route-error {message}` → on pipeline ERROR message.
   - `reconnecting {attempt, max}` → on reconnect cycle.

4. **Emit health events**:
   - `route-health {status, source, secondary_source}` → every stats interval.
   - Source health: `healthy` / `stalled` / `disconnected`.
   - Sink health: `healthy` / `stalled` / `error`.

5. **Monotonic counters**:
   - Packet counters must be monotonic (never decrease).
   - Reset explicitly on route restart (stats restart signal in IPC protocol).
   - Delta computation is Elixir's responsibility.

### Design Requirements
- Stats are structured, typed, and validated before serialization.
- No consumer should parse ambiguous free-form logs.
- Reset behavior is explicit on route restart.

### Crate: `engine-core/src/stats.rs`

```rust
#[derive(Serialize)]
pub struct RouteStats {
    pub timestamp: u64, // Unix millis
    pub source: SourceStats,
    pub secondary_source: Option<SourceStats>,
    pub sink: SinkStats,
    pub health: RouteHealth,
}

#[derive(Serialize)]
pub struct SourceStats {
    pub stream_id: String,
    pub rtt_ms: f64,
    pub packets_lost: u64,
    pub packets_received: u64,
    pub bandwidth_mbps: f64,
    pub packets_retransmitted: u64,
    pub negotiated_latency_ms: u32,
    pub status: HealthStatus,
}
// ... sink, health structs similarly defined
```

### Success Criteria
- Stats output byte-identical to C engine golden logs.
- Monotonic counters verified via test harness.
- Elixir `unix_sock_handler.ex` receives identical JSON format.
- StatsChannel pushes identical data to UI.

---

## Phase 11 — Remove C Or Keep Compatibility Shim

### Objective
After parity is proven through shadow deployment and production cutover, remove C from the codebase completely or archive it.

### Decision Criteria

- Rust has been running in production for ≥30 days with zero critical incidents.
- All routes (SRT→SRT, SRT→UDP, SRT→UDP/SRT dual-sink, SRT→SDI) are on Rust.
- Failover works identically in all 4 modes under Rust.
- Performance benchmarks (throughput, latency, CPU, memory) match or improve on C.
- Operators have confirmed no workflow changes needed.

### Tasks

1. **Remove C source**:
   - Delete `native/src/*.c`, `native/src/*.h`.
   - Delete `native/decklink-sdk/`.
   - Delete `native/obj/`, `native/build/` (old C binary artifacts).
   - Archive to `native/archive/` branch tag (`archive/c-engine-final`).

2. **Update build system**:
   - Remove `native/Makefile` → replace with `native/Makefile` that only builds Rust workspace.
   - Remove `lib/mix/tasks/compile_c_app.ex` → create `lib/mix/tasks/compile_rust_app.ex`.
   - Update `mix.exs` compiler ordering.
   - Update `Makefile` at project root to call `cargo build` instead of `make -C native`.

3. **Update packaging**:
   - Update `iso-builder/build.sh` to copy Rust binary from `native/build/rust/release/blackgate-engine`.
   - Update `iso-builder/files/blackgate.service` if binary name changes.
   - Update `.github/workflows/build-iso.yml`.

4. **Update documentation**:
   - Update `AGENTS.md`, `README.md`, `PRODUCT_KNOWLEDGE.md` to reference Rust engine.
   - Update `native/AGENTS.md` for Rust development workflow.
   - Archive the C AGENTS.md to `native/archive/C_AGENTS.md`.

5. **Rollback plan**:
   - Keep `archive/c-engine-final` branch tag — can be checked out and built if catastrophic Rust failure.
   - Document rollback procedure: checkout tag → build C binary → deploy.
   - Remove rollback plan documentation after 90 days of stable Rust operation.

### Success Criteria
- Production traffic runs entirely on Rust for ≥30 days.
- No feature lost.
- Operators notice no change.
- C code is archived but recoverable if needed.

---

## Implementation Order Inside The Rust Repo

1. `engine-ipc` (Phase 2 — first because it's the Elixir integration point and needs the most byte-level testing)
2. `engine-config` (Phase 3 — typed structs needed by all other crates)
3. `engine-core` shell with stub pipeline (Phase 3)
4. `engine-gst` simple passthrough (Phase 4)
5. `engine-failover` input-selector (Phase 5)
6. `engine-shadow` comparison daemon (Phase 6)
7. `engine-test` integration harness (parallel with all phases)
8. `engine-sdi` (Phase 7)
9. `engine-metadata` (Phase 8)
10. `engine-thumbnail` (Phase 9)

## Build & Deploy Pipeline Changes

### Current State
```
make install → make -C native (GCC) → native/build/blackgate_pipeline
make build   → mix compile (C + Elixir) → mix release → _build/prod/rel/blackgate
iso build    → build.sh → tar czf release → embed in ISO
```

### Target State (After Phase 3)
```
make install → make -C native (GCC for C + cargo build for Rust) → both binaries
make build   → mix compile → mix release → includes both binaries
```

### Target State (After Phase 11)
```
make install → cargo build --release
make build   → mix compile → mix release → only Rust binary
```

## Acceptance Tests

The migration is complete when:
- A route can start and stop through Elixir with the Rust worker.
- A route can fail over from primary to secondary source (Elixir decides, Rust executes).
- SRT output survives network loss and recovery.
- SDI output works on real DeckLink hardware.
- Observability data matches C engine golden logs byte-for-byte.
- Shadow deployment ran for ≥14 days with zero deviations beyond threshold.
- Long-running burn-in (≥7 days) reveals no leaks, deadlocks, or state corruption.
- Rust binary runs in production for ≥30 days with zero critical incidents.

## Risks (Corrected)

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| GStreamer-RS cannot match C's dynamic property injection (`g_object_set` from JSON) | Medium | High — blocks Phase 4 | Phase 0 spike proves capability. Fallback: `gstreamer-sys` raw FFI for property-setting path only. |
| GStreamer-RS lacks DeckLink plugin access or GValue matrix API | Medium | High — blocks Phase 7 | Phase 0 SDI spike proves capability. Fallback: hybrid approach (SDI stays in C, Rust handles passthrough + failover). |
| Byte-identical IPC output impossible (Rust serialization produces different JSON key ordering) | Low | Medium — requires Elixir changes | Phase 2 validates before committing. Use `serde_json::to_string` with sorted keys or manual formatting if needed. |
| Input-selector behavior differs between gstreamer-rs and raw C | Medium | High — failover breaks | Phase 5 must test with real SRT streams. Always-ok pads and cache-buffers semantics validated against C behavior. |
| Shadow mode reveals silent frame drops in Rust pipeline | Medium | Medium — requires pipeline tuning | Shadow comparison daemon detects deviations automatically. Extended shadow period catches drift. |
| SDI auto-detect produces different mode than C on same source | Medium | Medium — operator confusion | Golden log comparison in Phase 7. Match C's mode detection logic exactly. |
| Memory leak from gstreamer-rs reference counting | Low | Medium | Long burn-in tests. `valgrind` / `heaptrack` on Rust binary. |
| Rust toolchain not available in ubuntu:jammy CI container | Low | Low | Phase 0 build toolchain proof handles this. Rustup installs in CI setup step. |
| Refactoring Elixir side required (e.g., changing Port path) | Low | Medium | All Elixir changes are configuration/feature-flag only, not logic changes. |

## Rollout Plan (Corrected)

- **Stage 0**: Phase 0 — Feasibility spikes prove Rust can replace C. Go/no-go decision.
- **Stage 1**: Phases 1-2 — C modularization + Rust IPC drop-in. Elixir sees zero change.
- **Stage 2**: Phases 3-4 — Engine skeleton + simple passthrough. Benchmark parity against C.
- **Stage 3**: Phase 5 — Failover logic. Rust executes, Elixir decides.
- **Stage 4**: Phase 6 — Shadow deployment. A/B testing for ≥14 days.
- **Stage 5**: Phase 7 — SDI output. Cutover one route at a time.
- **Stage 6**: Phases 8-10 — Metadata, thumbnails, observability polish.
- **Stage 7**: Phase 11 — Remove C. Archive and monitor for 90 days.

## Final Recommendation

For Blackgate, the Rust migration is a disciplined compatibility-preserving sequence. **Do not begin Phase 1 until Phase 0 feasibility spikes pass.** The gstreamer-rs and SDI spikes are the make-or-break questions. If both pass, the remaining phases are incremental execution with clear success criteria at each gate. If either fails, adjust scope: keep C for that path, Rust for everything else.

The shadow deployment phase (Phase 6) is the single most important risk-reduction step. No live streaming system should cut over without side-by-side runtime comparison on real hardware.
