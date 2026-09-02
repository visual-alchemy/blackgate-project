# Changelog

All notable changes to the Blackgate SRT Gateway project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added
- **Guarded Seamless SDI Failover**: Matching dual-SRT inputs can remain warm and switch inside the running native pipeline. Blackgate validates MPEG-TS program/PID layout and codec configuration, waits for a target video keyframe, acknowledges the selector change, and retains deterministic pipeline-restart fallback for incompatible or incomplete streams. (`0faa825`)
- **MPEG-TS Timeline Normalization**: Seamless SDI mode rewrites PCR, PTS, and DTS onto a shared 90 kHz output timeline, handles 33-bit wraparound, and regenerates per-PID continuity counters across source changes. (`0faa825`)
- **Expanded Source Statistics**: Source cards expose receive rate, link bandwidth, RTT, receive latency, received/retransmitted/lost/dropped packets, resolution, frame rate, scan mode, and decimal Video/Audio PID values for each failover input. (`0faa825`)

### Changed
- **SDI Switch Policy**: SDI routes retain restart-based switching by default. Enabling both Auto Join and Seamless SDI Failover activates guarded in-process switching for compatible inputs; a rejected or timed-out switch automatically returns to restart fallback. (`0faa825`)
- **Network Timestamp Policy**: SRT and UDP sources preserve encoder timing with `do-timestamp=false`; seamless mode performs explicit post-selector MPEG-TS timeline normalization instead of deriving media time from network arrival. (`ce0d898`, `0faa825`)
- **Failover Configuration Documentation**: README now distinguishes Failover Mode, Auto Join, Seamless SDI Failover, and Keep Listening, including why full pipeline restart forces listener-side encoders to reconnect. (`0faa825`)

### Fixed
- **GStreamer SRT Listener Callback ABI**: Corrected `srtsrc::caller-connecting` callback return type and arguments for deployed GStreamer 1.24, avoiding undefined behavior and rejected connections. (`ce0d898`)
- **Native Port Recovery**: Route recovery clears dead Port terms and ignores delayed output from replaced Ports instead of attempting commands through a closed native process. (`ce0d898`)
- **Acknowledged Active-Source State**: Persisted source selection is honored during initialization and updated only after native switch or replacement-pipeline acknowledgement. (`ce0d898`)
- **Auto Join State Handling**: With Auto Join disabled, the inactive child is locked at `NULL`; switching starts the target before selector movement and stops the old source only after movement. (`ce0d898`)
- **Unix-Socket Framing and Writes**: Native messages use serialized, newline-delimited, full-write transport; the Ranch receiver accumulates split lines with a bounded packet size. (`ce0d898`)
- **Fresh Docker Release Builds**: Docker no longer depends on an ignored local `deps/` directory and fetches Mix dependencies inside the image build. (`ce0d898`)
- **Failover Validation and UI Refresh**: Backend and form validation reject malformed failover/SRT settings, non-2xx authenticated requests reject correctly, and active route details continue polling through automatic failover. (`ce0d898`)
- **Secret-Safe Logging**: SRT URIs, passphrases, tokens, authorization values, Stream IDs, route records, and FFmpeg source URLs are filtered or redacted from production logs. (`ce0d898`)
- **Manual-Mode Recovery**: Manual failover reconnects the currently selected source after transient pipeline or network failure without silently changing source selection. (`0faa825`)
- **Scalar-Array Metrics Export**: Metrics traversal now recurses only into map members of JSON arrays, preventing Video/Audio PID arrays from generating repeated `%BadMapError{}` log entries. (`0faa825`)

### Known Limitations
- Guarded seamless switching requires matching codec configuration and MPEG-TS program/PID layout. Arbitrary encoder or muxer layouts deliberately use restart fallback; PID remapping and demux/remux normalization are not implemented.
- A compatible seamless cut can briefly freeze while waiting for the target keyframe and downstream decoder recovery. Hardware testing observed approximately 500 ms with the current matching encoder pair.
- Abrupt sender termination can delay reconnection through the SRT dead-peer window plus sender-side retry backoff. This behavior remains transport/client dependent.

---

## [1.0.1] - 2026-07-12

### Added
- **GStreamer C Engine Bus Warnings Intercept**: Added warnings interception in `bus_callback` inside `gst_pipeline.c`. Decoder and demuxer warnings (H.264 slice corruption, parser errors) are now captured, JSON-serialized, and sent via UNIX socket `/tmp/hydra_unix_sock`.
- **Erlang/Elixir Health Telemetry Pipeline**: Piped GStreamer JSON warnings through `UnixSockHandler`, aggregated count in `RouteStatsRegistry`, and updated `RouteHealth` to evaluate stream state:
  - `source_corrupted`: Upstream video warnings present, but 0% loopback packet loss.
  - `blackgate_config_issue`: Warnings present + loopback packet loss (indicating socket buffer overflow or CPU bottleneck).
  - `network_loss_egress`: Healthy input feed, but packet loss detected on output SRT clients.
- **Route Health UI Banners**: Added colored dot indicators in routes list, `HealthBadge` in `RouteStats`, and diagnostic `<Alert>` banners explaining exactly what issue is occurring and how to fix it.
- **Health State Transition Event Log**: Added state transition tracking in `RouteStatsRegistry`. When route health transitions (e.g. from healthy to egress loss), it writes a permanent log entry to `EventLog` database.
- **tsparse GStreamer Integration**: Added `tsparse` (MPEG transport stream parser) to `add_sink_to_pipeline` in `gst_pipeline.c` before the `srtsink`. Configured `alignment=7` to force MTU-sized (1316 bytes) UDP packet blocks, reducing packet rate overhead by 80%. Configured `set-timestamps=TRUE` to smooth out PCR clock jitter.

### Fixed
- **Phoenix Channel Join push Crash**: Cleanly resolved Phoenix 1.7 WebSocket join/push crash by deferring initial stats push via `:after_join`.
- **Non-Monotonic Timestamps / Decoder Sync Failure**: Changed `-mpegts_copyts` from `1` to `0` in FFmpeg sidecar command inside `route_handler.ex`. This forces FFmpeg's `mpegts` muxer to ignore broken/duplicate timestamps from the RTMP source and regenerate a clean, monotonic DTS/PTS timeline, preventing green macroblocking on hardware decoders (MediaKind RX1).
- **GStreamer SRT Outbound Jitter**: Changed `sync` from `FALSE` to `TRUE` on GStreamer `srtsink` in `gst_pipeline.c`. Paces packet output based on GStreamer's master clock to prevent micro-bursting and dropped frames.
- **Elixir Pipeline Raw Line Logging**: Changed `inspect(line)` to raw line logging in `RouteHandler` to prevent truncation of warning logs from the C binary.

---

## [1.0.0] - 2026-07-07

### Added
- First stable release.
- All 0.4.0 features (SRT StreamID, 8-channel audio upmix, silence auto-recovery) verified and marked stable.


## [0.4.0] - 2026-06-14

### Added
- **SRT StreamID Support**: Optional Stream ID field for SRT Caller sources and destinations, enabling compatibility with services like Vidio that require `streamid` in the SRT URI. (`391b189`)
- **SDI Audio Silence Auto-Recovery**: `RouteHandler` monitors stdout from the C pipeline for `SDI_AUDIO_SILENT` events and automatically restarts the pipeline to recover from DeckLink hardware audio desync. Three guards prevent restart loops: schema guard (SRT routes never restarted — self-healing), source-silence guard (skip if `total_buffers < 5000`, meaning source has no audio), and a 5-minute cooldown after each auto-restart. (`3f5d244`)
- **SDI 8-Channel Audio Upmix**: All SDI playout destinations now output 8 embedded audio channels regardless of source channel count. Uses `audiomixmatrix` in manual mode with a GValue matrix API (not `gst_util_set_object_arg` — causes SIGSEGV on GStreamer 1.24) to mirror stereo input to all 8 SDI channels. Downstream broadcast switchers (DeckLink Quad 2) require a full 8-channel audio frame to pass audio. (`4702799`)
- **Loopback Port Availability Check**: Before spawning an ffmpeg sidecar on a loopback port (range `39000–39999`), `RouteHandler` now verifies the port is free to prevent silent port conflicts between concurrent RTMP routes. (`4702799`)
- **Metrics Connection Spam Silenced**: Reduced log noise from periodic VictoriaMetrics connection errors when the metrics backend is unavailable. (`4702799`)
- **AGENTS.md — RTK + Caveman Mode Instructions**: Added `RTK` command prefix requirement (60–90% token savings on shell output) and caveman response style rules for AI agent sessions. (`326b397`)

### Fixed
- **GMainLoop Pointer Scope Bug**: Fixed SIGSEGV/freeze in `gst_pipeline.c` where the `GMainLoop *` was allocated on the stack of a short-lived function scope, causing the pipeline bus thread to dereference a dangling pointer after the outer function returned. Moved to heap allocation (`g_main_loop_new`) with matching `g_main_loop_unref` in the cleanup path. (`e149490` — local only, not yet pushed)
- **StatsChannel `push/3` in `join/3` Crash**: Phoenix 1.7+ forbids calling `push/3` directly inside `join/3` — doing so raises a `RuntimeError` that crashes the WebSocket transport, killing all preview and stats channels simultaneously. Fixed by deferring the initial stats push via `send(self(), :after_join)` and handling it in `handle_info/2`. (manual patch on remote — not yet committed to git)

### Changed
- **SDI Audio Sink Sync Policy**: `decklinkaudiosink` set to `sync=TRUE` to enable GStreamer master clock slaving and prevent audio drift/stuttering. `decklinkvideosink` remains `sync=FALSE`, with video timing paced by an upstream `identity sync=TRUE`. (`4702799`)

---

## [0.3.0] - 2026-05-19

### Added
- **RTMP/HTTP-FLV/HLS Source via ffmpeg Sidecar**: Accept RTMP push or pull HLS/HTTP-FLV streams by spawning an ffmpeg sidecar process that normalizes them to SRT MPEG-TS before entering the GStreamer pipeline. Supports cross-protocol routing: RTMP → SRT/UDP/SDI. (`09bdb8d`)
- **ffmpeg Sidecar Auto-Reconnect**: Seamless auto-reconnect for RTMP/HLS/HTTP-FLV routes when the source disconnects, with 10s retry interval and 3-minute timeout. (`9592bfe`, `42f0496`)
- **SDI Output via Blackmagic DeckLink**: Hardware SDI output with codec-agnostic decodebin pipeline. Supports H.264, HEVC, MPEG-2 video at resolutions from 480i SD to 2160p60 4K. Simultaneous SRT passthrough + SDI decode from the same route. (`54d7c9f`, `f4bb7d3`, `bbe6460`)
- **Watchdog for Stalled Pipelines**: Auto-detect and restart stalled pipelines via a 60-second heartbeat watchdog in RouteHandler. (`2113456`)
- **Event Log System**: In-memory event timeline (ETS ring buffer, 500 events) tracking route lifecycle (start, stop, crash, reconnect) and SDI failures. New `/api/events` endpoints and Events page in the UI. (`a7aee08`)
- **Bulk Delete Selected**: "Delete Selected" button on the routes table for bulk route deletion. (`5d4863f`)
- **Inline Output Popover**: Quick destination editing popover on the routes table showing output destinations at a glance. (`ffa8169`)
- **Systemd Service**: Auto-start on boot via `blackgate.service` for baremetal production deployments. (`f5b9017`)
- **Connection Status Badge**: Live green/red/yellow/grey connection indicator per route, including "Reconnecting" state for auto-reconnect scenarios. (`fae8912`)
- **SDI Port Conflict Prevention**: SDI device dropdown disables ports already in use by other routes and shows which route is using them. (`d4279a2`)

### Changed
- **Routes table "Last Updated" replaced with "Output" column**: Shows compact destination summary (e.g., `SRT:15000 · SDI 1`). (`6f6b8b6`)
- **SDI audio sync**: Configured `decklinkaudiosink sync=TRUE` to enable GStreamer's master-clock slaving and prevent stuttering/buffer underruns, while keeping `decklinkvideosink sync=FALSE` with upstream video paced by `identity sync=TRUE`.
- **SRT loopback latency**: Increased from 125ms to 500ms for ffmpeg sidecar reliability. (`e52b6d4`)
- **Node IP default**: Changed from `hostname -f` to `127.0.0.1` to avoid FQDN hostname issues. (`f4bb7d3`)
- **RELEASE_COOKIE**: Fixed cookie so `make stop`/`make status` can connect to running daemon. (`1eba812`)

### Fixed
- **SDI audio dropout after 30 minutes**: Added `audiorate` element to prevent audio timing drift. (`de4e65d`)
- **SDI pipeline stability**: Multiple rounds of decode pipeline tuning — removed `identity` from audio path, tested VA-API hardware decode (disabled — Intel HD 630 too weak), reverted to stable software avdec. (`b842b71`, `b60b579`, `32a1803`)
- **SDI caps mapping**: Explicit width/height/framerate from backend to C pipeline for correct DeckLink mode selection. (`273d0cb`)
- **DeckLink Quad 2 port mapping**: Corrected physical port layout (SDI 1-4 = even, SDI 5-8 = odd device numbers). (`88becf3`, `89f23ea`)
- **ffmpeg sidecar pipeline**: Added `-mpegts_copyts 1 -pcr_period 40` to prevent timestamp issues. (`dd7f100`)
- **Docker release build**: Added `--overwrite` for `mix release` to fix ERTS file error. (`273d0cb`)

---

## [0.2.0] - 2026-04-06

### Added
- **Real-time Connection Status**: Live green/red/grey connection indicator on the Routes table showing whether SRT streams are actively connected, waiting, or off. Auto-refreshes every 3 seconds.
- **Seamless Auto-Restart**: Editing a running route or destination now automatically restarts the pipeline with the new configuration — no manual stop/start cycle needed.
- **Dual Save Buttons**: Route and Destination edit pages now feature "Save and Continue" and "Save and Exit" buttons for a smoother editing workflow.
- **Bulk Start/Stop Routes**: Select multiple routes from the table and start/stop them all at once.
- **Route Cloning**: Duplicate a route with all its destinations via a "Clone" button.
- **Route Search & Filter**: Search routes by name and filter by status (Started/Stopped) or schema (SRT/UDP).
- **Credential Management**: Settings → Users tab allows changing the admin username and password from the Web UI, persisted via Khepri.
- **System Pipelines Page**: View and manage running GStreamer pipeline processes, including the ability to kill orphaned pipelines.
- **System Nodes Page**: View cluster node information and system health.

### Changed
- **Routes table Actions**: Action buttons (Start/Stop, Clone, Edit, Delete) are now icon-only for a cleaner, more compact table layout. Hover for tooltips.
- **Routes table columns**: "Status" column renamed to "Process" to differentiate from the new "Connection" indicator. New column order: Name → Enabled → Process → Authentication → Input → Last Updated → Connection → Actions.

### Fixed
- React rendering crash on Route details page when authentication is toggled.
- React rendering crash on RouteItem for undefined array filters.
- Login error display now uses a visible Alert component instead of an easily-missed toast message.
- Frontend production build errors related to static message API usage in MainLayout.

---

## [0.1.0-alpha] - 2026-02-06

### Added
- **HEVC (H.265) 4K support**: Detect resolution and infer framerate for HEVC streams, including 4K (2160p) at ~50fps (`88d0cb6`)
- **Enhanced source statistics**: Resolution, framerate, scan type (progressive/interlaced), and dropped packet metrics displayed in Web UI (`4f1b297`)
- **Inferred framerate display**: Show `~25 fps` with tilde prefix for H.264/HEVC streams where framerate is inferred rather than detected from the stream header. MPEG-2 shows exact framerate without prefix (`0a1c7fc`)
- **`fps_inferred` flag**: Backend C pipeline now tracks whether framerate was detected (MPEG-2) or inferred (H.264/HEVC) via `VideoInfo.fps_inferred` field

### Fixed
- HEVC 1080p framerate display corrected — now uses `~25 fps` (inferred) instead of incorrect 50fps (`8a26c71`)
- H.264 framerate display fixed — shows `~25 fps` (inferred default) instead of N/A for progressive content (`cbf1d87`)
- Docker ERTS copy issue resolved by adding clean step (`rm -rf _build/prod/rel`) before `mix release --overwrite` (`97a3ae2`)
- Docker base image tags updated to verified `hexpm/elixir` versions (`f40e343`, `3af1bc5`)

---

## [0.1.0-alpha.3] - 2026-01-23

### Added
- **Network interface detection**: API endpoint to list available network interfaces for source/destination configuration (`712f468`)
- **Baremetal deployment workflow**: `make install` now handles full system setup — Elixir, Erlang, Node.js, Yarn, GStreamer, and all dependencies on macOS and Linux (`9c8db09`, `712f468`)

### Fixed
- Elixir/Erlang installation improved with multiple fallback methods (apt, erlang-solutions repo, PPA) for broader Ubuntu compatibility (`7d175d1`)

---

## [0.1.0-alpha.2] - 2026-01-08

### Added
- User guide documentation with screenshots (`3f9303c`)

### Fixed
- Docker Compose v2 syntax for Ubuntu 24.04 compatibility (`a651471`)

### Removed
- Obsolete `docs/README.md` (`d14b097`)

---

## [0.1.0-alpha.1] - 2025-12-31

### Documentation
- Ubuntu fresh install instructions improved with `make setup` (`c317a54`)
- Node.js and Yarn installation instructions added (`83cc167`, `6697805`)
- Changed to `libsrt-openssl-dev` for Ubuntu 24.04 compatibility (`21dd323`)
- Added `universe` repository to Ubuntu installation steps (`a612660`)
- Corrected Ubuntu installation dependencies (`ee96ed4`)

---

## [0.0.4] - 2025-12-24

### Added
- **Advanced SRT Settings UI**: Expose `auto-reconnect`, `keep-listening`, `latency`, and `poll-timeout` settings in route configuration (`29cb45e`)
- **MPEG-TS packet alignment**: `tsparse` element for proper TS packet handling (`bb959a8`)
- **Input buffer queue**: Network smoothing queue before `tee` element to handle jitter (`79065bb`)

### Changed
- **Pipeline simplification**: Refactored to ultra-simple `source → tee → sinks` architecture — removed unnecessary intermediate elements (`98f834b`)

### Fixed
- Disabled `do-timestamp` to preserve original MPEG-TS timestamps in passthrough mode (`1bef551`)

---

## [0.0.3] - 2025-12-21

### Added
- **Import Routes from JSON**: Bulk import route configurations (`f8d247e`)
- **High bitrate support**: Increased `queue2` buffer for streams exceeding 20 Mbps (`ddefc98`)

### Changed
- Rebrand from `hydra_srt` to `blackgate` — Docker node, backup files, and service names (`8713b48`, `c3df382`)
- Switched from `queue` to `queue2` for improved streaming performance and memory management (`84baf05`)
- Updated documentation to Alpha status (`76b7a7d`)

### Fixed
- Removed `tsparse` and reverted to simple passthrough for high bitrate compatibility (`a533a40`)
- Import routes endpoint moved to `api_no_parse` pipeline with proper parameter handling (`a2a6305`, `bc1c190`, `48f8698`)
- Added `tsparse` for MPEG-TS timing — later reverted in favor of simple passthrough (`403412f`)

---

## [0.0.2] - 2025-12-20

### Added
- **SRT Destination Statistics**: Per-sink real-time stats displayed in the UI — connection status, bitrate, RTT, packet loss (`33fe843`)
- **Mermaid network topology diagrams** in README (`e93bb07`)

### Fixed
- Concatenated source + sink stats messages now handled correctly by splitting on `stats_sink:` prefix (`f8e2111`)
- Newline separators added between stats messages for reliable parsing (`816fabe`)
- Destination type filter corrected in `DestinationStats` component (`889a125`)
- Latency from `schema_options` now displayed correctly in destinations table (`bdb47b2`)
- Correct field names for destination data in `DestinationStats` (`8929117`)
- Queue buffering improved to prevent video artifacts and freezes (`10b87c4`)
- Cache-busting added to favicon (`e8501e7`)

### Changed
- Logo updated with new white icon design (`7dca5f9`)
- README updated with destination statistics screenshots and badges (`7e5b6f0`)
- Removed unused files (`d4607ce`)

---

## [0.0.1] - 2025-12-19

### Added
- **Real-time SRT statistics**: Live source stats (bitrate, RTT, packet loss, bandwidth) on route detail page (`0a2f10d`)
- **OBS SRT compatibility**: `wait-for-connection` and `poll-timeout` settings for streaming software compatibility (`82c40a3`)
- Production deployment documentation and WSL2/Windows installation instructions (`483f8d2`, `5b42090`)

### Fixed
- CRLF → LF conversion for all shell scripts in Docker release (`626b81a`, `60d76e0`, `4da2a37`)
- Dockerfile release path updated from `hydra_srt` to `blackgate` (`ca74347`)
- PNG files added to `static_paths` for production builds (`a1b3b43`)
- Removed hardcoded SRT authentication — now allows connections without `streamid` (`5522bd1`)

### Changed
- **Full rebrand**: `HydraSrt` → `Blackgate` — all modules, files, Docker services, and native binary renamed (`fdde8fd`, `99f8663`, `8ea3af7`, `78dfe22`)
- New Blackgate logo and branding (`e2422f4`, `5439e7e`, `a9a05d2`, `1d19a97`)

---

## [0.0.0] - 2025-12-18

### Added
- **Initial release** of Blackgate SRT Gateway (`744fc2b`)
- Elixir/Phoenix backend with OTP supervision tree
- C + GStreamer native streaming pipeline
- SRT source/sink support (Listener, Caller, Rendezvous modes)
- UDP source/sink support
- Khepri (Raft-based) persistent storage
- ETS-based real-time statistics registry
- Unix Domain Socket IPC between Elixir and C pipeline
- React + Ant Design web interface
- Route CRUD with start/stop/restart lifecycle management
- Bearer token authentication with Cachex session storage
- Docker containerization with multi-stage build
- Backup/restore functionality
