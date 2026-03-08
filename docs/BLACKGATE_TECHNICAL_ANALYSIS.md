# Blackgate — Software Design Review: Technical Analysis

> **Document Version**: 1.0  
> **Date**: 2026-02-14  
> **Source Codebase**: `visual-alchemy/blackgate-project` (hydra-srt)  
> **Analysis Method**: Static code analysis of all source files

---

## Table of Contents

1. [Architecture & Tech Stack](#1-architecture--tech-stack)
2. [Core Functionality](#2-core-functionality)
3. [Architectural Improvements](#3-architectural-improvements-vs-legacy)
4. [Deployment & Infrastructure](#4-deployment--infrastructure)
5. [Issues & Roadmap](#5-issues--roadmap)

---

## 1. Architecture & Tech Stack

### 1.1 System Architecture Overview

```mermaid
graph TB
    subgraph "Elixir/OTP Application (BEAM VM)"
        APP["Blackgate.Application<br/>(OTP Supervisor)"]
        RANCH["Ranch TCP Listener<br/>/tmp/hydra_unix_sock"]
        USH["UnixSockHandler<br/>(:gen_statem)"]
        RSR["RouteStatsRegistry<br/>(GenServer + ETS)"]
        DS["DynamicSupervisor<br/>(PartitionSupervisor)"]
        RS["RoutesSupervisor<br/>(per-route Supervisor)"]
        RH["RouteHandler<br/>(:gen_statem)"]
        KHEPRI["Khepri DB<br/>(Raft Consensus)"]
        CACHEX["Cachex<br/>(In-Memory Cache)"]
        SYN["Syn<br/>(Process Registry)"]
        PHOENIX["Phoenix Endpoint<br/>(HTTP API)"]
        METRICS["Metrics.Connection<br/>(Instream/InfluxDB)"]
    end

    subgraph "Native C Processes (per-route)"
        NATIVE["blackgate_pipeline<br/>(C + GStreamer)"]
        GST["GStreamer Pipeline<br/>(srtsrc → tee → srtsink/udpsink)"]
    end

    subgraph "Frontend"
        REACT["React SPA<br/>(Vite + Ant Design)"]
    end

    subgraph "External"
        SRT_IN["SRT Source<br/>(Encoder/Gateway)"]
        SRT_OUT["SRT Destination<br/>(Decoder/Gateway)"]
        UDP_OUT["UDP Destination<br/>(Multicast)"]
        VM["VictoriaMetrics<br/>(TSDB)"]
    end

    REACT -->|REST API| PHOENIX
    PHOENIX -->|CRUD| KHEPRI
    PHOENIX -->|Auth Sessions| CACHEX
    PHOENIX -->|Read Stats| RSR
    PHOENIX -->|Start/Stop| DS

    DS --> RS --> RH
    RH -->|Erlang Port<br/>(stdin/stdout)| NATIVE
    RH -->|Process Lookup| SYN

    NATIVE -->|Unix Domain Socket<br/>(AF_UNIX, SOCK_STREAM)| RANCH
    RANCH --> USH
    USH -->|JSON Stats| RSR
    USH -->|Metrics Export| METRICS
    METRICS --> VM

    SRT_IN -->|SRT Protocol| GST
    GST -->|SRT Protocol| SRT_OUT
    GST -->|UDP Multicast| UDP_OUT
```

### 1.2 Backend: Elixir + Phoenix

**✅ CONFIRMED** — The backend is built on **Elixir 1.14+ / OTP 27** with **Phoenix 1.7.14**.

**Evidence from `mix.exs`:**
```elixir
{:phoenix, "~> 1.7.14"},
{:plug_cowboy, "~> 2.7"},
{:phoenix_ecto, "~> 4.5"},
```

#### Concurrency Model

Blackgate uses advanced OTP concurrency patterns, **not** basic GenServer:

| Pattern | Module | Purpose |
|---------|--------|---------|
| **`:gen_statem`** (State Machine) | `RouteHandler` | Manages lifecycle of each C pipeline process with state transitions (`start` → `started`) |
| **`:gen_statem`** (State Machine) | `UnixSockHandler` | Handles bidirectional communication over Unix socket with state (`exchange`) |
| **`GenServer`** | `RouteStatsRegistry` | Owns the ETS table for real-time stats storage |
| **`GenServer`** | `ErlSysMon` | Monitors BEAM VM health (GC pauses, scheduling delays, busy ports) |
| **`PartitionSupervisor`** | `Blackgate.DynamicSupervisor` | Distributes route processes across all scheduler threads to avoid bottlenecks |
| **`DynamicSupervisor`** | (child of PartitionSupervisor) | Dynamically starts/stops per-route supervisors |
| **`Supervisor`** | `RoutesSupervisor` | Per-route supervisor wrapping the `RouteHandler` — `one_for_all` strategy, `max_restarts: 10` in 60s |
| **`Registry`** (partitioned) | `Blackgate.Registry.MsgHandlers` | Partitioned process registry for message handlers |
| **Syn** | Process registration | Distributed process registry for route lookup (`:syn.lookup(:routes, id)`) |
| **Ranch** | TCP listener | High-performance connection acceptor for Unix Domain Socket (up to 75,000 connections, 100 acceptors) |

**Key Design Decision**: The use of `:gen_statem` over `GenServer` for `RouteHandler` is significant — it provides a proper finite state machine for managing pipeline lifecycle, including clean state transitions and trapped exits for graceful shutdown.

**Supervision Tree:**
```
Blackgate.Supervisor (one_for_one)
├── Cachex (auth session cache)
├── RouteStatsRegistry (ETS owner)
├── ErlSysMon (VM health monitor)
├── PartitionSupervisor
│   └── DynamicSupervisor (per-partition)
│       └── RoutesSupervisor (per-route, registered via Syn)
│           └── RouteHandler (:gen_statem, transient restart)
├── Registry (MsgHandlers, partitioned)
├── Telemetry
├── Phoenix.PubSub (partitioned)
├── Phoenix.Endpoint
└── Metrics.Connection (Instream/InfluxDB)
```

### 1.3 Streaming Engine: C + GStreamer

**✅ CONFIRMED** — The native streaming engine is implemented in **C** using **GStreamer 1.0** and compiled to a standalone binary (`blackgate_pipeline`).

**Source Files:**

| File | Lines | Purpose |
|------|-------|---------|
| `native/src/gst_pipeline.c` | 1,063 | Core pipeline: SRT stats collection, MPEG-TS parsing (PAT/PMT/PES), H.264/HEVC/MPEG-2 video info extraction, pipeline construction |
| `native/src/main.c` | 83 | Entry point: reads route_id from argv, JSON config from stdin, initializes GStreamer and Unix socket |
| `native/src/unix_socket.c` | 47 | Unix Domain Socket client: connects to `/tmp/hydra_unix_sock`, sends stats and metadata |

#### IPC Mechanism: Dual-Channel Communication

**✅ CONFIRMED** — Communication between Elixir and C uses **two separate channels**:

**Channel 1: Erlang Port (stdin/stdout) — Command Channel**
```
Elixir RouteHandler → [stdin] → C main() → JSON config parsed
C pipeline logs     → [stdout] → Elixir RouteHandler (logged)
```
- Used for: Sending initial pipeline configuration (source + sinks JSON)
- Direction: Primarily Elixir → C (one-time command), C → Elixir (log output)

**Channel 2: Unix Domain Socket — Stats Channel**
```
C pipeline → [AF_UNIX, /tmp/hydra_unix_sock] → Ranch → UnixSockHandler
```
- Used for: Continuous real-time stats streaming (every 1 second)
- Protocol: `AF_UNIX`, `SOCK_STREAM` (TCP over UDS)
- Server: Ranch TCP listener (Elixir side, started in `application.ex`)
- Client: C process connects on startup (`init_unix_socket()`)
- Messages: Newline-delimited JSON with prefixes (`route_id:`, `stats_sink:`, `stats_source_stream_id:`)

**Why Dual Channels?** The Port (stdio) channel provides Erlang's built-in process linking — when the C process crashes, the Port closes and the `RouteHandler` receives an exit signal, enabling automatic cleanup. The Unix socket provides a high-throughput data channel that doesn't block the Port's control path.

### 1.4 Database: Khepri (Raft-based)

**✅ CONFIRMED** — Blackgate uses **Khepri 0.16.0** as its primary persistent storage. **No traditional SQL database is used** in production (Ecto/SQLite3 deps exist but are commented out).

**Evidence from `mix.exs`:**
```elixir
{:khepri, "0.16.0"},
```

**Evidence from `application.ex`:**
```elixir
khepri_data_dir = System.get_env("DATABASE_DATA_DIR", "#{File.cwd!()}/khepri##{node()}")
:khepri.start(khepri_data_dir)
```

**Data Model (from `db.ex`):**

Khepri stores data in a tree structure with path-based addressing:

```
routes/
├── {route_id_1}/
│   ├── (route data: name, schema, schema_options, status, exportStats, etc.)
│   └── destinations/
│       ├── {dest_id_1}/ (destination data)
│       └── {dest_id_2}/ (destination data)
└── {route_id_2}/
    └── ...
```

**Operations verified in `db.ex`:**
- `create_route` → `:khepri.put(["routes", id], data)`
- `get_route` → `:khepri.get!(["routes", id])`
- `get_all_routes` → `:khepri.get_many("routes/*")`
- `update_route` → `:khepri.transaction()` with `:khepri_tx.get/put` (atomic read-modify-write)
- `delete_route` → `:khepri.delete(["routes", id])` + `:khepri.delete_many("routes/#{id}/destinations/*")`
- `backup` → `:khepri.get_many("**")` serialized with `:erlang.term_to_binary`
- `restore_backup` → `:khepri.delete_many("**")` then re-insert all

**Khepri Advantages:**
- Built on Ra (Raft consensus) — enables future multi-node clustering
- No external database dependency
- Data directory mounted as Docker volume (`./data/khepri:/app/khepri`)
- Embedded in the BEAM VM — zero network overhead for DB operations

### 1.5 Stats Storage: ETS (Erlang Term Storage)

**✅ CONFIRMED** — Real-time statistics are stored in **ETS** via the `RouteStatsRegistry` GenServer.

**Evidence from `route_stats_registry.ex`:**
```elixir
:ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
```

**Key Properties:**
- `:named_table` — Accessed by atom `:route_stats` globally
- `:public` — Any process can read/write (no GenServer bottleneck for reads)
- `:set` — Key-value storage with unique keys
- `read_concurrency: true` — Optimized for concurrent reads (many API requests reading stats simultaneously)

**Data Layout:**

| Key Format | Value | Use |
|-----------|-------|-----|
| `route_id` (string) | `{route_id, stats_map, timestamp_ms}` | Source stats per route |
| `{route_id, :sink, sink_index}` (tuple) | `{key, stats_map, timestamp_ms}` | Per-sink/destination stats |

**Performance Characteristics:**
- Write: O(1) per stats update (every 1s per pipeline from `UnixSockHandler`)
- Read: O(1) per route lookup (from `RouteController.stats/2`)
- No serialization bottleneck — direct ETS access from API handlers
- Stats are ephemeral — lost on restart (appropriate for real-time data)

---

## 2. Core Functionality

### 2.1 Routing Logic: SRT Modes

The system supports all three SRT connection modes. The mode configuration flows through:

**API → Khepri DB → RouteHandler → C Pipeline → GStreamer**

**Modes are set via the SRT URI** (not as separate GStreamer properties):

```
srt://{localaddress}:{localport}?mode={listener|caller|rendezvous}&passphrase=...&pbkeylen=...
```

**From `route_handler.ex` → `build_srt_uri/1`:**
```elixir
query_params = %{}
  |> maybe_add_param(opts, "mode")        # listener, caller, or rendezvous
  |> maybe_add_param(opts, "passphrase")  # SRT encryption passphrase
  |> maybe_add_param(opts, "pbkeylen")    # Key length (16, 24, 32)
  |> maybe_add_param(opts, "poll-timeout")
```

**From `gst_pipeline.c` → `set_srt_mode_property/3`:**
```c
// GStreamer SRT mode values: 0=none, 1=caller, 2=listener, 3=rendezvous
if (strcmp(mode_str, "listener") == 0)    mode_value = 2;
else if (strcmp(mode_str, "caller") == 0) mode_value = 1;
else if (strcmp(mode_str, "rendezvous") == 0) mode_value = 3;
```

**Supported Source/Sink Types:**

| Source Type | Sink Type | Supported Properties |
|-------------|-----------|---------------------|
| `srtsrc` | `srtsink` | `uri`, `latency`, `auto-reconnect`, `keep-listening`, `mode`, `passphrase`, `pbkeylen`, `poll-timeout` |
| `udpsrc` | `udpsink` | `address`/`host`, `port`, `buffer-size`, `mtu` |

### 2.2 Authentication

**Two-layer authentication:**

#### Layer 1: API Authentication (Bearer Token)

**From `auth_controller.ex` and `router.ex`:**

1. Login via `POST /api/login` with `{user, password}`
2. Credentials validated against environment variables (`API_AUTH_USERNAME`, `API_AUTH_PASSWORD`)
3. On success: 30-byte cryptographically random token generated (`crypto.strong_rand_bytes/1`)
4. Token stored in **Cachex** with 14-day TTL: `Cachex.put(Blackgate.Cache, "auth_session:#{token}", user, ttl: :timer.hours(24 * 14))`
5. Subsequent API requests require `Authorization: Bearer {token}` header
6. Token validated via `Cachex.get(Blackgate.Cache, "auth_session:#{token}")`

> ⚠️ **Note**: The code contains `TODO: Implement a proper authentication mechanism`. Current auth compares against plain-text env vars.

#### Layer 2: SRT Stream Authentication (Passphrase)

- SRT passphrase is passed via the SRT URI query parameter: `?passphrase=xxx&pbkeylen=16`
- This is **not** application-level auth — it's SRT protocol-level AES encryption
- Key lengths supported: 16, 24, or 32 bytes
- The `on_caller_connecting` callback in `gst_pipeline.c` handles incoming SRT connections and automatically authenticates (`*authenticated = TRUE`)

### 2.3 Monitoring Metrics

#### Source Stats (extracted every 1 second from `print_stats` thread in `gst_pipeline.c`):

| Metric | Type | Description |
|--------|------|-------------|
| `total-bytes-received` | uint64 | Cumulative bytes received |
| `packets-received` | int64 | Packets received in interval |
| `packets-received-lost` | int64 | Lost packets |
| `packets-received-dropped` | int64 | Dropped packets |
| `packets-received-retransmitted` | int64 | Retransmitted packets (SRT ARQ) |
| `bytes-received` | int64 | Bytes received in interval |
| `rtt-ms` | double | Round Trip Time in milliseconds |
| `receive-rate-mbps` | double | Current receive rate |
| `bandwidth-mbps` | double | Estimated link bandwidth |
| `negotiated-latency-ms` | int | SRT negotiated latency |
| `connected-callers` | int | Number of connected SRT callers |
| `callers[]` | array | Per-caller detailed stats (address, individual metrics) |

#### Video Metadata (from MPEG-TS PAT/PMT/PES parsing):

| Metric | Type | Description |
|--------|------|-------------|
| `video-width` | int | Horizontal resolution |
| `video-height` | int | Vertical resolution |
| `video-framerate-num` | int | Framerate numerator |
| `video-framerate-den` | int | Framerate denominator |
| `video-framerate-inferred` | bool | Whether framerate is estimated vs. detected |
| `video-interlace-mode` | string | `"progressive"` or `"interleaved"` |

#### Sink/Destination Stats (from `print_sink_stats` thread):

Similar SRT metrics reported per-sink, including connection and transmission statistics.

#### Metrics Export Pipeline:

```
C Pipeline → Unix Socket → UnixSockHandler → stats_to_metrics() → Metrics.Connection → VictoriaMetrics/InfluxDB
```

Uses the **Instream** library with InfluxDB v2 protocol. Configurable via `VICTORIOMETRICS_HOST` and `VICTORIOMETRICS_PORT` environment variables.

---

## 3. Architectural Improvements vs. Legacy

### 3.1 Native Process vs. Docker Container/FFmpeg

| Aspect | Legacy (Docker + FFmpeg) | Blackgate (Native C + GStreamer) |
|--------|--------------------------|----------------------------------|
| **Startup Time** | 2-10s (container init + FFmpeg launch) | <100ms (fork + exec of native binary) |
| **Memory Overhead** | ~50-100 MB per container (OS layers, filesystem) | ~15-30 MB per pipeline (GStreamer + SRT only) |
| **CPU Overhead** | Container runtime (cgroups, namespaces) + FFmpeg transcoding | Direct GStreamer pipeline, zero container overhead |
| **IPC** | Docker networking (veth pairs, NAT) | Unix Domain Socket (kernel-level, zero-copy potential) |
| **Process Management** | Docker daemon dependency, API calls to start/stop | Erlang Port supervision, automatic crash recovery |
| **Scaling** | Limited by Docker daemon (~1000 containers) | Limited by file descriptors (65,536+ configurable) |
| **Protocol Support** | FFmpeg command-line complexity | Native GStreamer SRT/UDP elements, direct API access |
| **Stats Collection** | External monitoring required | In-process stats via GStreamer API + inline MPEG-TS parsing |
| **Crash Isolation** | Container crash = restart entire container | C process crash = Erlang Port closes → RouteHandler terminates → Supervisor restarts only that route |

### 3.2 Key Architectural Advantages

**1. Process-per-Route with OTP Supervision**
```
PartitionSupervisor → DynamicSupervisor → RoutesSupervisor → RouteHandler → C Pipeline
```
Each route is supervised individually. A crash in one pipeline cannot affect any other route or the main application. The `RoutesSupervisor` allows up to 10 restarts in 60 seconds before giving up, providing automatic recovery for transient failures.

**2. Zero-Overhead Transport (No Transcoding)**  
GStreamer pipelines use `tsparse` for MPEG-TS remuxing — the video/audio streams are **not transcoded**. This provides a pure transport layer with minimal CPU usage per stream, unlike FFmpeg which often defaults to transcoding.

**3. Shared BEAM VM Resources**  
All route management, stats collection, API handling, and database operations run in a single BEAM VM. This eliminates inter-container communication overhead and enables:
- Shared ETS stats table (sub-microsecond reads)
- Shared Khepri database (no network round-trips)
- Shared metrics export connection pool
- Shared authentication cache

**4. Native SRT Library Integration**  
The C pipeline links directly against `libsrt`, avoiding FFmpeg's SRT wrapper overhead. This provides access to the full SRT API including caller management, per-caller stats, and fine-grained connection control (`on_caller_connecting` callback).

---

## 4. Deployment & Infrastructure

### 4.1 Dockerfile Analysis

**Multi-stage build** (2 stages):

#### Stage 1: Builder (`hexpm/elixir:1.18.2-erlang-27.0.1-debian-bookworm`)
```
1. Install build tools (gcc, make, git, curl)
2. Install Node.js 18.x
3. Install GStreamer dev libraries + libsrt + libcjson + cmocka
4. Install Elixir deps (mix deps.get, mix deps.compile)
5. Build C native binary (make -C native clean && make)
6. Build React frontend (npm install, npm run build)
7. Compile Elixir (mix compile)
8. Create release (mix release --overwrite)
   └── Custom release steps: copy_c_app/1, copy_web_app/1
```

#### Stage 2: Runner (`debian:bookworm-slim`)
```
1. Install runtime-only dependencies (no dev headers)
2. Install runtime GStreamer plugins + libsrt + libcjson
3. Copy release from builder
4. Entrypoint: tini → run.sh → bin/server
```

**Key Differences: Development vs. Production**

| Aspect | Development (`make dev`) | Production (Docker/Release) |
|--------|--------------------------|----------------------------|
| C binary path | `./native/build/blackgate_pipeline` | `#{:code.priv_dir(:blackgate)}/native/build/blackgate_pipeline` |
| Frontend | Vite dev server (`:5173`) | Pre-built static files in `priv/static/` |
| Backend | `iex -S mix phx.server` (interactive shell) | OTP release binary (`bin/server`) |
| Database | Local Khepri in `./khepri#node()` | Mounted volume `/app/khepri` |
| Hot reload | Yes (Elixir code reloading) | No (compiled release) |
| Observer | Available (`:wx, :observer` deps) | Not included |
| Environment | `MIX_ENV=dev` | `MIX_ENV=prod` |

### 4.2 Docker Compose Configuration

```yaml
network_mode: host  # Direct host networking (no Docker NAT)
volumes:
  - ./data/khepri:/app/khepri    # Persistent database
  - ./data/backup:/app/backup    # Backup storage
```

**Host networking** is critical — SRT requires direct port binding for listener mode (each route binds its own port). Docker's NAT would add latency and complicate SRT's connection management.

### 4.3 System-Level Dependencies

#### Build-Time Dependencies
| Library | Package (Debian) | Purpose |
|---------|------------------|---------|
| GStreamer 1.0 | `libgstreamer1.0-dev`, `libgstreamer-plugins-base1.0-dev` | Media pipeline framework |
| GStreamer Plugins Good | `gstreamer1.0-plugins-good` | Standard codecs (mpegts, rtp, udp) |
| GStreamer Plugins Bad | `gstreamer1.0-plugins-bad` | SRT source/sink elements |
| libsrt | `libsrt-openssl-dev` | SRT protocol library |
| libcjson | `libcjson-dev` | JSON parsing in C |
| cmocka | `libcmocka-dev` | C unit testing framework |
| GLib 2.0 | `libglib2.0-dev` | GObject type system (for GStreamer) |
| pkg-config | `pkg-config` | Build configuration tool |
| GCC | `build-essential` | C compiler |
| Node.js 18 | `nodejs` | Frontend build toolchain |

#### Runtime Dependencies
| Library | Package (Debian) | Purpose |
|---------|------------------|---------|
| GStreamer 1.0 | `libgstreamer1.0-0`, `libgstreamer-plugins-base1.0-0` | Pipeline runtime |
| GStreamer Plugins Good | `gstreamer1.0-plugins-good` | Codec plugins |
| GStreamer Plugins Bad | `gstreamer1.0-plugins-bad` | SRT elements |
| libsrt | `libsrt1.5-openssl` | SRT runtime |
| libcjson | `libcjson1` | JSON runtime |
| tini | `tini` | PID 1 init process for Docker (handles SIGTERM properly) |
| iptables | `iptables` | Network configuration |
| OpenSSL | `openssl` | TLS/crypto support |

---

## 5. Issues & Roadmap

### 5.1 TODO / FIXME Comments Found in Code

| File | Line | Comment | Severity |
|------|------|---------|----------|
| `router.ex` | 60 | `# TODO: improve this` — Refers to the backup restore endpoint (`/api/restore`) using `api_no_parse` pipeline | Low |
| `auth_controller.ex` | 5 | `# TODO: Implement a proper authentication mechanism` — Current auth compares against plain-text environment variables | **High** |

### 5.2 Incomplete / Planned Features

Based on code analysis:

| Feature | Status | Evidence |
|---------|--------|----------|
| **Cluster Mode** | 🟡 Partially Prepared | Khepri (Raft-based) supports multi-node. Syn configured for `:routes` scope. `node_controller.ex` exists for node management. `NodeController` exposes node info API. **But**: no actual clustering logic implemented yet. |
| **RTMP Input** | 🔴 Not Implemented | No RTMP source type in `route_handler.ex`. Only SRT and UDP sources are handled. |
| **HLS Output** | 🔴 Not Implemented | No HLS sink type. Only `srtsink` and `udpsink` exist. |
| **Ecto/SQL Database** | 🟡 Vestigial | `api.ex` contains full Ecto CRUD operations (`Repo.all`, `Repo.insert`, etc.) but `Blackgate.Repo` is **commented out** in the supervision tree. `ecto_sqlite3` is listed as a dependency but unused in production. |
| **Proper Authentication** | 🔴 Basic Implementation | Auth uses env-var credentials with Cachex session tokens. No JWT, no role-based access, no user management. |
| **Metrics Dashboard** | 🟡 Infrastructure Ready | VictoriaMetrics/InfluxDB integration exists (`Instream`), Grafana provisioning directory exists. But exportStats must be explicitly enabled per-route. |
| **DNS Cluster Discovery** | 🔴 Commented Out | `dns_cluster_query` config line exists but is commented out in `runtime.exs`. |

### 5.3 Identified Risks

#### Risk 1: C Pipeline Crash Handling

**Question**: Does a C pipeline crash affect the main Elixir backend?

**Answer: No** — The architecture provides strong crash isolation:

```
C process crashes
  → Erlang Port closes
    → RouteHandler receives {:EXIT, port, reason}
      → RouteHandler.terminate/3 called (sets route status to "stopped", kills OS process)
        → RoutesSupervisor detects child termination
          → Automatic restart (up to 10 times in 60 seconds, transient strategy)
```

**Evidence from `route_handler.ex`:**
```elixir
Process.flag(:trap_exit, true)  # Traps exit signals from the C port

def terminate(reason, _state, %{port: port, id: id}) when is_port(port) do
  close_port(port)              # Graceful cleanup
  Blackgate.set_route_status(id, "stopped")
end
```

**Risk mitigation**: The `RoutesSupervisor` uses `restart: :transient` — it only restarts on abnormal termination. The `close_port` function attempts both `Port.close/1` and `kill -9` for reliability.

#### Risk 2: Unix Socket Saturation

- Ranch is configured for **75,000 max connections** with **100 acceptors**
- Each running route creates one Unix socket connection
- Risk is low for typical deployments (hundreds of routes) but could be tested for extreme scale
- Each `UnixSockHandler` sets `max_heap_size: 90 MB` to prevent memory runaway

#### Risk 3: Stats Message Parsing

- The `split_stats_message` function handles concatenated source + sink stats in a single TCP message
- Edge case: if JSON messages are split across TCP segments, parsing may fail
- Mitigation: Ranch TCP socket is configured with `active: true` mode and messages are newline-delimited

#### Risk 4: Memory Management

- **Positive**: `ErlSysMon` monitors for long GC pauses (>250ms), long schedules (>100ms), busy ports
- **Positive**: Per-process heap limits (`max_heap_size: 90 MB` on socket handlers)
- **Risk**: ETS table for stats grows linearly with running routes (mitigated by ephemeral nature)

#### Risk 5: Commented-Out Ecto/SQLite Code

- `api.ex` contains full Ecto CRUD operations that are unused
- `Blackgate.Repo` is commented out in the supervision tree
- `ecto_sqlite3` dependency is still included in `mix.exs`
- **Risk**: Dead code may cause confusion; dependency adds to build size

---

## Appendix A: File Inventory

### Backend (Elixir)

| File | Lines | Role |
|------|-------|------|
| `lib/blackgate/application.ex` | 81 | OTP Application (supervision tree, Ranch, Khepri) |
| `lib/blackgate.ex` | 56 | Public API (start/stop/restart routes) |
| `lib/blackgate/route_handler.ex` | 305 | Pipeline lifecycle (gen_statem), SRT URI building |
| `lib/blackgate/unix_sock_handler.ex` | 234 | Stats receiver (gen_statem + Ranch protocol) |
| `lib/blackgate/db.ex` | 209 | Khepri CRUD operations |
| `lib/blackgate/route_stats_registry.ex` | 96 | ETS stats storage (GenServer) |
| `lib/blackgate/process_monitor.ex` | 246 | OS-level process stats for C pipelines |
| `lib/blackgate/routes_supervisor.ex` | 39 | Per-route supervisor |
| `lib/blackgate/helpers.ex` | 21 | Utility functions (heap limits, kill) |
| `lib/blackgate/erl_sys_mon.ex` | 30 | BEAM VM health monitor |
| `lib/blackgate/metrics.ex` | 21 | Metrics helper |
| `lib/blackgate/metrics/connection.ex` | 4 | Instream/InfluxDB connection |
| `lib/blackgate/api.ex` | 201 | Ecto context (vestigial, unused) |
| `lib/blackgate_web/router.ex` | 106 | API routes and auth middleware |
| `lib/blackgate_web/controllers/` | 14 files | REST API controllers |

### Native (C)

| File | Lines | Role |
|------|-------|------|
| `native/src/gst_pipeline.c` | 1,063 | GStreamer pipeline, stats, MPEG-TS parsing |
| `native/src/main.c` | 83 | Entry point, JSON config reader |
| `native/src/unix_socket.c` | 47 | UDS client for stats communication |

### Configuration

| File | Role |
|------|------|
| `config/config.exs` | Compile-time config (Ecto, Logger) |
| `config/runtime.exs` | Runtime config (Phoenix, VictoriaMetrics, auth) |
| `config/dev.exs` | Dev-specific config (debug logging) |
| `config/prod.exs` | Prod-specific config (info logging) |
| `config/test.exs` | Test-specific config |

---

## Appendix B: API Endpoints

| Method | Path | Auth | Controller | Action |
|--------|------|------|-----------|--------|
| `GET` | `/health` | No | `HealthController` | Health check |
| `POST` | `/api/login` | No | `AuthController` | Login, returns token |
| `GET` | `/api/routes` | Yes | `RouteController` | List all routes |
| `POST` | `/api/routes` | Yes | `RouteController` | Create route |
| `POST` | `/api/routes/bulk-action` | Yes | `RouteController` | Bulk start/stop routes |
| `GET` | `/api/routes/:id` | Yes | `RouteController` | Get route details |
| `POST` | `/api/routes/:id/clone` | Yes | `RouteController` | Clone route and its destinations |
| `PUT` | `/api/routes/:id` | Yes | `RouteController` | Update route |
| `DELETE` | `/api/routes/:id` | Yes | `RouteController` | Delete route |
| `GET` | `/api/routes/:id/start` | Yes | `RouteController` | Start pipeline |
| `GET` | `/api/routes/:id/stop` | Yes | `RouteController` | Stop pipeline |
| `GET` | `/api/routes/:id/restart` | Yes | `RouteController` | Restart pipeline |
| `GET` | `/api/routes/:id/stats` | Yes | `RouteController` | Get source stats (ETS) |
| `GET` | `/api/routes/:id/destination-stats` | Yes | `RouteController` | Get sink stats |
| `GET/POST/PUT/DELETE` | `/api/routes/:id/destinations/...` | Yes | `DestinationController` | Destination CRUD |
| `GET` | `/api/backup/export` | Yes | `BackupController` | Export Khepri data |
| `POST` | `/api/restore` | Yes | `BackupController` | Restore Khepri data |
| `GET` | `/api/system/pipelines` | Yes | `SystemController` | List C processes |
| `POST` | `/api/system/pipelines/:pid/kill` | Yes | `SystemController` | Kill C process |
| `GET` | `/api/nodes` | Yes | `NodeController` | List cluster nodes |
| `GET` | `/api/network/interfaces` | Yes | `NetworkController` | List network interfaces |
