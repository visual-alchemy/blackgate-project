# Changelog

All notable changes to the Blackgate SRT Gateway project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added
- **Seamless Auto-Restart**: Editing a running route or destination now automatically restarts the pipeline with the new configuration, without requiring a manual stop/start cycle.
- **Dual Save Buttons**: Route and Destination edit pages now feature 'Save and Continue' and 'Save and Exit' buttons for a smoother user experience.
- `BLACKGATE_TECHNICAL_ANALYSIS.md` — comprehensive software design review document

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
