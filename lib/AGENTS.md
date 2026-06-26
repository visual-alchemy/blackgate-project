# Backend Core & API Context (`lib/`)

Welcome! This folder contains the Elixir OTP core, Phoenix REST API, and WebSocket channels.

## 🛠️ Technology Stack & Environment

- **Language/Platform:** Elixir 1.18.x / Erlang OTP 27 (configured in `.tool-versions`)
- **Web Layer:** Phoenix 1.7.x (REST API + Phoenix Channels WebSockets)
- **Database:** Khepri 0.16.x (embedded distributed Raft KV store; Ecto is disabled)

## 🏗️ Folder Layout

- `lib/blackgate/`:
  - `application.ex`: OTP supervision tree starting Khepri, Ranch Unix socket acceptor, and registries.
  - `route_handler.ex`: `gen_statem` managing the lifecycle of C pipeline processes (Ports).
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

### 4. SDI Audio Desync Auto-Recovery (`route_handler.ex`)
- RTMP/HTTP/HLS sources go through the `ffmpeg` sidecar, which can cause brief audio gaps. When this happens, the DeckLink SDI audio embedder loses hardware sync and stays silent even after GStreamer recovers.
- `RouteHandler` automatically restarts the pipeline when `SDI_AUDIO_SILENT` is detected from the C pipeline's stdout, subject to three guards:
  1. **Schema guard:** `schema == "SRT"` routes are **never** auto-restarted (SRT is self-healing).
  2. **Source-silence guard:** if `total_buffers < 5000`, the source has no audio — restart would loop indefinitely, so it is skipped.
  3. **Cooldown guard:** after an auto-restart, a 5-minute cooldown prevents a restart loop if audio remains intermittent.
- The `data` struct in `RouteHandler` carries `sdi_audio_last_restart_at` (monotonic timestamp). This field is reset to `nil` on every successful start/reconnect so that user-triggered restarts clear the cooldown.
