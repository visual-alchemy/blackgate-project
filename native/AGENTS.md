# Native Streaming Engine Context (`native/`)

Welcome! This folder contains the Native C GStreamer streaming engine.

## 🛠️ Technology Stack & Environment

- **Language:** C (C99 / C11 compatible)
- **Framework:** GStreamer 1.0 (base, good, bad, and decklink plugins)
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

---

## ⚠️ Critical Architectural Constraints

### 1. SDI Hardware Synchronization (DeckLink Quad 2)
- **Video Playout:** The uncompressed video sink (`decklinkvideosink`) MUST run with **`sync=FALSE`**. Its timing/pacing is controlled by an upstream **`identity`** element set to **`sync=TRUE`** placed right before the video output.
- **Audio Playout:** The audio sink (`decklinkaudiosink`) MUST run with **`sync=TRUE`**. This allows GStreamer's master clock-slaving mechanism to coordinate sample delivery, preventing audio drift, buffer underruns, and stuttering.

### 2. SDI Audio Must Be 8 Channels (`gst_pipeline.c`)
- All SDI playout destinations (`sdisink`) **must output exactly 8 embedded audio channels**, regardless of source channel count. Delivering fewer channels causes downstream switchers (e.g., DeckLink Quad 2 inputs) to output silence.
- **Upmix Matrix:** Insert an `audiomixmatrix` element in `manual` mode before `decklinkaudiosink`. Programmatically duplicate/mirror the stereo pairs (2 input channels to all 8 output channels). Set the capsfilter (`acaps`) to `channels=8`.
- **GValue Matrix Warning:** The `matrix` property of `audiomixmatrix` **must not** be set via `gst_util_set_object_arg` with a literal string on GStreamer 1.24+ — this causes a SIGSEGV. Use the GValue array API programmatically:
  ```c
  GValue matrix = G_VALUE_INIT;
  g_value_init(&matrix, GST_TYPE_ARRAY);
  // Nest GValue arrays for rows and append double coefficients
  ```
