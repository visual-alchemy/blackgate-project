# Native Streaming Engine Context (`native/`)

Welcome! This folder contains the Native C GStreamer streaming engine.

## 🛠️ Technology Stack & Environment

- **Language:** C (C99 / C11 compatible)
- **Framework:** GStreamer 1.0 (base, good, bad plugins)
- **External Libraries:** `libsrt` (SRT streaming), `glib`, `cjson` (JSON parser)
- **Binary Output:** `./native/build/blackgate_pipeline` and `./native/build/srt_proxy`

## 🏗️ Folder Layout

- `src/gst_pipeline.c`: GStreamer pipeline builder, MPEG-TS demux parser, JPEG preview appsink, and stats gathering thread.
- `src/main.c`: Process entry point; reads route JSON configuration from stdin.
- `src/unix_socket.c`: IPC socket client connecting back to Elixir `/tmp/hydra_unix_sock`.
- `src/srt_proxy.c`: Lightweight SRT stream multiplexing proxy.

## 🚀 Setup & Execution Commands

### Build C Binaries
Run from project root or `native/` folder:
```bash
make -C native
# Or from root:
make build
```


