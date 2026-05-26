# AGENTS.md

Welcome, AI Agent! This file provides the context, setup steps, architectural constraints, and styles required to develop and debug the Blackgate SRT Gateway safely.

---

## 🛠️ Technology Stack & Environment

- **Backend:** Elixir 1.18.x / Erlang OTP 27 (configured in `.tool-versions`)
- **Web Layer:** Phoenix 1.7.x (REST API + Phoenix Channels WebSockets)
- **Database:** Khepri 0.16.x (embedded distributed Raft KV store; Ecto is vestigial/disabled)
- **Native Engine:** C + GStreamer 1.0 (compiled to `./native/build/blackgate_pipeline`)
- **Frontend:** React 18 + Vite + Ant Design 5 (located in `web_app/`)
- **OS Appliance Packaging:** Debian Bookworm + custom preseeded ISO installer (located in `iso-builder/`)

---

## 🚀 Setup & Execution Commands

### 1. Dependency Installation
Installs system libraries (GStreamer base/good/bad, libsrt, glib, cjson, etc.), Elixir hex/rebar dependencies, and React node modules:
```bash
make install
```

### 2. Development Execution
Runs the backend Phoenix server (`localhost:4000`) and the Vite React frontend server (`localhost:5173`) concurrently:
```bash
make dev-all
```

### 3. Production Release Build
Builds React assets, copies them to `priv/static`, digests Phoenix static assets, and builds an OTP release:
```bash
make build
```

### 4. Running Production Release Locally
Runs the compiled release daemon:
```bash
make start
```

---

## 🏗️ Codebase Layout

- **Elixir OTP Core:** [lib/blackgate](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/lib/blackgate)
  - `application.ex`: OTP supervision tree starting Khepri, Ranch Unix socket acceptor, and registries.
  - `route_handler.ex`: gen_statem managing the lifecycle of C pipeline processes (Ports).
  - `unix_sock_handler.ex`: gen_statem Ranch protocol listener handling telemetry JSON streams.
  - `db.ex`: Khepri CRUD operations and binary database backup/restore.
- **REST & Socket API:** [lib/blackgate_web](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/lib/blackgate_web)
  - `router.ex`: API endpoints and Bearer Token session authorization pipeline.
  - `controllers/`: Controller handlers (routes, destinations, node metrics, event ring buffers).
  - `channels/stats_channel.ex`: Phoenix Channel pushing sub-second stream stats updates.
- **Native C Streaming Engine:** [native/src](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/native/src)
  - `gst_pipeline.c`: GStreamer pipeline builder, MPEG-TS demux parser, JPEG preview appsink, and stats gathering thread.
  - `main.c`: Process entry point; reads route JSON config from stdin.
  - `unix_socket.c`: IPC socket client connecting back to Elixir `/tmp/hydra_unix_sock`.
- **Frontend App:** [web_app/src](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/web_app/src)
  - `pages/`: Route manager dashboards, source/destination edit views, settings, and node metric lists.
  - `hooks/useRouteStats.js`: Hybrid WebSocket-polling React hook.
- **Appliance Packaging:** [iso-builder](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/iso-builder)
  - `build.sh`: Ubuntu Preseed autoinstall ISO repacker.

---

## ⚠️ Critical Architectural Constraints

1.  **SDI Hardware Synchronization (DeckLink Quad 2):**
    - The uncompressed DeckLink sinks (`decklinkvideosink` and `decklinkaudiosink`) run with **`sync=FALSE`** because the hardware clock drifts from the GStreamer pipeline clock, dropping audio packets.
    - Video timing is maintained using an **`identity`** element with **`sync=TRUE`** placed right before the video output.
2.  **FFmpeg Loopback Sidecar:**
    - GStreamer FLV demuxing and live RTMP inputs deadlock or drift.
    - Routes using `RTMP`, `HTTP`, or `HLS` sources launch a background `ffmpeg` port on loopback port range `39000..39999` to remux and push stream as MPEG-TS over SRT (`mode=listener`). The native pipeline then calls it as an `SRT` source.
3.  **licensing Heartbeat Resilience:**
    - The license checker heartbeats to vercel every 6 hours. If the validation times out or fails due to network issues, the license cache **remains valid** to prevent production outages.
4.  **Database Storage:**
    - Khepri is the production state database. Do **not** try to run Ecto migrations or use SQLite3 in production.

---

## 🧠 Memory & Context Logs

- **Memory Folder:** [docs/memory/](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/docs/memory/)
- **Session Logs:** [docs/memory/01-LOGS/](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/docs/memory/01-LOGS/)
- **Custom Skill:** [docs/skills/project-memory/SKILL.md](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/docs/skills/project-memory/SKILL.md)
- **Startup Rule:** You MUST invoke the `project-memory` skill at the start of the session to retrieve recent context, and append a new session summary to the logs at the end of the session.

