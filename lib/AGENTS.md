# Backend Core & API Context (`lib/`)

Welcome! This folder contains the Elixir OTP core, Phoenix REST API, and WebSocket channels.

## 🛠️ Technology Stack & Environment

- **Language/Platform:** Elixir 1.18.x / Erlang OTP 27 (configured in `.tool-versions`)
- **Web Layer:** Phoenix 1.7.x (REST API + Phoenix Channels WebSockets)
- **Database:** Khepri 0.16.x (embedded distributed Raft KV store; Ecto is disabled)

## 🏗️ Folder Layout

- `lib/blackgate/`:
  - `application.ex`: OTP supervision tree starting Khepri, Ranch Unix socket acceptor, and registries.
  - `route_handler.ex`: `gen_statem` managing Rust engine processes through Erlang Ports.
  - `unix_sock_handler.ex`: `gen_statem` Ranch protocol listener handling telemetry JSON streams.
  - `db.ex`: Khepri CRUD operations and binary database backup/restore.
- `lib/blackgate_web/`:
  - `router.ex`: API endpoints and Bearer Token session authorization pipeline.
  - `controllers/`: Controller handlers (routes, destinations, node metrics, event ring buffers).
  - `channels/stats_channel.ex`: Phoenix Channel pushing sub-second stream stats updates.

---

## ⚠️ Critical Architectural Constraints

### 1. Database Storage (Khepri)
- Khepri is the production state database.
- **Do not** attempt to run Ecto migrations or use SQLite3 in production. All persistent state must be managed via Khepri KV operations defined in `Blackgate.Db`.

### 2. FFmpeg Loopback Sidecar
- GStreamer FLV demuxing and live RTMP inputs deadlock or drift.
- Routes using `RTMP`, `HTTP`, or `HLS` sources launch a background `ffmpeg` port on loopback port range `39000..39999` to remux and push stream as MPEG-TS over SRT (`mode=listener`). The native pipeline then calls it as an `SRT` source.

### 3. Licensing Heartbeat Resilience
- The license checker heartbeats to Vercel every 6 hours.
- If the validation times out or fails due to network issues, the license cache **remains valid** to prevent production outages.

### 4. Listening-Port Gate (`output_claims.ex`)
- Two routes cannot listen on one local port: the engine that loses dies at start with nothing explaining why. `RouteHandler` is gated by `Blackgate.OutputClaims` **at start time**, not at configuration time.
- Only a listener claims a port; a caller dials out and binds nothing.
- Holding a port means running it, first come first served: the caller passes the RUNNING routes in (judged from live engines, not from the stored `status`), so a stale `started` label never blocks a free port.
- Destination schemas are SRT and UDP only; `Db.create_destination/2` refuses anything else at the boundary.
