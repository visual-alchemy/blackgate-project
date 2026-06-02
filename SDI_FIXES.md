# SDI Output — BlackGate Project

## Status: ✅ Working (Baremetal, May 2026)

SDI output via Blackmagic DeckLink Quad 2 is fully functional on baremetal deployment.
Tested with H.264/AAC and HEVC/MP2 input sources outputting to 1080p25 SDI. Multiple rounds of audio and decode pipeline tuning completed.

---

## Architecture

```
SRT Source → tee ─┬─→ queue2 → srtsink (SRT passthrough output)
                  ├─→ queue2 → tsdemux ─┬─→ decodebin (video) → videoconvert → videorate → videoscale → capsfilter(UYVY) → decklinkvideosink
                  │                     └─→ decodebin (audio) → audioconvert → audioresample → decklinkaudiosink
                  └─→ thumbnail branch (JPEG preview)
```

Key design decisions:
- **`decodebin`** for codec-agnostic decode — handles H.264, HEVC, MPEG-2, AAC, MP2, Opus automatically
- **`videorate`** for framerate conversion (e.g., 50fps input → 25fps output mode)
- **`videoscale`** for resolution conversion (e.g., 720p input → 1080p output mode)
- **Video `sync=FALSE` / Audio `sync=TRUE`** on DeckLink sinks — audio utilizes GStreamer clock-slaving, while video pacing is handled by an upstream `identity sync=true` element
- SRT passthrough output runs simultaneously without interference

---

## Hardware Setup

| Component | Details |
|-----------|---------|
| **Card** | Blackmagic DeckLink Quad 2 (PCIe) |
| **Outputs** | 8 SDI channels (device-number 0–7) |
| **Driver** | Blackmagic Desktop Video (creates `/dev/blackmagic/io*`) |
| **Host OS** | Ubuntu 24.04 |
| **GStreamer** | 1.24.2 (system package) |
| **Required package** | `gstreamer1.0-libav` (provides avdec_h264, avdec_aac, etc.) |

### Device Number Mapping (DeckLink Quad 2)

The DeckLink Quad 2 has 4 sub-devices, each with input + output. Not all device numbers work as outputs:

| device-number | Physical Port | Status |
|---------------|--------------|--------|
| 0 | Sub-device 1 output | ✅ Working |
| 1 | Sub-device 1 input | ❌ Not an output |
| 2 | Sub-device 2 output | ✅ Working |
| 3 | Sub-device 2 input | ❌ Not an output |
| 4–7 | Sub-devices 3–4 | Untested |

> **Note:** Run `gst-launch-1.0 videotestsrc ! videoconvert ! "video/x-raw,format=UYVY,width=1920,height=1080,framerate=25/1" ! decklinkvideosink device-number=N mode=1080p25` to test each port.

---

## Issues Resolved

### 1. Pipeline crash when SDI destination added (Fatal)

**Symptom:** Adding SDI output kills the entire route — SRT output also stops.

**Root cause:** `add_sink_to_pipeline()` returns `FALSE` on SDI failure, which destroys the entire pipeline including already-working SRT sinks.

**Fix:** Ensure all required GStreamer packages are installed (`gstreamer1.0-libav`).

### 2. Caps mismatch — wrong video mode integers (`88a657d`)

**Symptom:** Pipeline links but DeckLink rejects the video because mode integer doesn't match GStreamer's enum.

**Fix:** Send mode as string (`"1080p25"`) + explicit width/height/framerate from Elixir backend. Use `gst_util_set_object_arg()` for string-to-enum conversion.

### 3. Hardware state change failure — sync=TRUE (`8171849`, Updated May 2026)

**Symptom:** Pipeline can't reach PLAYING state. DeckLink elements stuck in NULL when both sinks are set to `sync=TRUE`.

**Fix:** Set `sync=FALSE` on `decklinkvideosink` with video timing paced by an upstream `identity sync=TRUE` block. The `decklinkaudiosink` is set to `sync=TRUE` to avoid clock drift and audio stuttering.

### 4. Codec-specific pipeline — only H.264/AAC worked (`54d7c9f`)

**Symptom:** HEVC or MP2 input sources fail silently — tsdemux exposes pads that don't match `h264parse`/`aacparse`.

**Fix:** Replaced hardcoded `h264parse → avdec_h264` and `aacparse → avdec_aac` with `decodebin` which auto-detects any codec.

### 5. Connection status shows "Waiting" in caller mode (`9b3532a`)

**Symptom:** Route with SRT caller source shows "Waiting" even when stream is flowing.

**Fix:** Added `bytes-received > 0` and `total-bytes-received > 0` checks to `route_connected?/1` as fallback for caller mode where `connected-callers` is always 0.

### 6. `make start` doesn't background (`f4bb7d3`)

**Symptom:** `make start` blocks the terminal.

**Fix:** Changed from `blackgate start` to `blackgate daemon`.

### 7. `make stop` fails with hostname error (`f4bb7d3`)

**Symptom:** `** Hostname woi-SRT-GATEWAY is illegal **` when trying to stop.

**Fix:** Default `NODE_IP` to `127.0.0.1` instead of `hostname -f` in `rel/env.sh.eex`.

### 8. Audio dropout and stuttering (`de4e65d`, `c012fcd`, `edf8075`, Updated May 2026)

**Symptom:** SDI audio would stutter or drop out over time.

**Root cause:** Audio timing drift between the GStreamer system clock and the DeckLink hardware playback clock. Without synchronization, the uncompensated drift caused buffer underruns in the hardware sink.

**Fix:** 
- Removed `identity` from the audio path.
- Configured `decklinkaudiosink` with `"sync", TRUE` to enable GStreamer's master-clock slaving, dynamically aligning audio playout and avoiding sample underrun.
- Added `audiorate` element to prevent sample rate drift.
- Added audio health monitor to detect silent audio outputs.

### 9. VA-API Hardware Decode Attempts (`32a1803`, `25e7f22`)

**Attempt:** Enable Intel VA-API hardware decode (`vah264dec`, `vaapidecodebin`) to reduce CPU load from software avdec.

**Result:** Disabled. Intel HD 630 on test hardware was too weak for real-time 1080p decode. Software avdec (libav) provides stable performance at ~70% CPU for 720p. VA-API may work with newer Intel Arc or NVIDIA NVDEC hardware.

### 10. SDI Audio silent warning not triggering at startup

**Symptom:** If a route starts up with video but has no audio buffers from the beginning, the warning event is never triggered.

**Fix:** Initialize `sdi_audio_last_buffer_time[device_number]` with the current monotonic time when installing the audio sink probe, rather than leaving it at `0`. This allows the health monitor thread to detect silence after 10 seconds of startup even if no audio buffers were ever received.

---

## Supported Video Modes

| Mode | Resolution | Framerate | UI Value |
|------|-----------|-----------|----------|
| 1080p25 (PAL) | 1920×1080 | 25fps | 9 |
| 1080p30 (NTSC) | 1920×1080 | 30fps | 11 |
| 1080p50 | 1920×1080 | 50fps | 12 |
| 1080p60 | 1920×1080 | 60fps | 13 |
| 1080i50 (PAL) | 1920×1080 | 25fps (interlaced) | 7 |
| 1080i60 (NTSC) | 1920×1080 | 30fps (interlaced) | 8 |
| 720p50 | 1280×720 | 50fps | 14 |
| 720p60 | 1280×720 | 60fps | 15 |
| 576i PAL SD | 720×576 | 25fps | 17 |
| 480i NTSC SD | 720×480 | 30fps | 18 |
| 2160p25 (4K) | 3840×2160 | 25fps | 22 |
| 2160p30 (4K) | 3840×2160 | 30fps | 23 |
| 2160p50 (4K) | 3840×2160 | 50fps | 24 |
| 2160p60 (4K) | 3840×2160 | 60fps | 25 |

> **Important:** Select the mode that matches your downstream equipment. The pipeline will scale/convert the input to match the selected output mode.

---

## Diagnostic Commands

```bash
# Check if DeckLink plugin is available
gst-inspect-1.0 decklinkvideosink

# List all DeckLink output devices
gst-device-monitor-1.0 Video/Sink

# Test pattern output on specific port
gst-launch-1.0 videotestsrc ! videoconvert ! "video/x-raw,format=UYVY,width=1920,height=1080,framerate=25/1" ! decklinkvideosink device-number=0 mode=1080p25

# Check if DeckLink device is in use
sudo lsof /dev/blackmagic/io0

# Check if data is actively flowing (run twice, compare SIZE/OFF)
sudo lsof /dev/blackmagic/io0 2>/dev/null | grep blackgate

# Check running pipeline process
ps aux | grep blackgate_pipeline
```

---

## Future Architecture: True SDI Auto-Detect

Currently, the pipeline forces a strict output mode selected by the user (e.g., `1080i50`). To implement true auto-detection (matching the SDI output to the incoming source's native resolution/framerate), the following architectural changes are required:

### 1. Dynamic Caps Extraction
- **Pad-Added Probes:** Attach a blocking pad probe on the `decodebin` source pad or immediately after the `tsdemux`.
- **Metadata Interception:** When the first frame arrives, the probe extracts the stream's `GstCaps` (specifically `width`, `height`, `framerate`, and `interlace-mode`).

### 2. Mode Mapping Logic
- Build a C lookup table to map standard incoming caps to DeckLink modes.
  - Example: `1920x1080, 25/1 fps, interlaced` ➡️ `"1080i50"`
  - Example: `1280x720, 60/1 fps, progressive` ➡️ `"720p60"`

### 3. State Management & Dynamic Linking
- **Blocking Flow:** The probe must block the video flow just before it reaches the `decklinkvideosink`.
- **Reconfiguration:** While blocked, the `decklinkvideosink` element must be configured with the new `mode` property. This may require transitioning the sink to `READY` state, applying the mode, and transitioning back to `PLAYING`.
- **Dynamic Linking:** Only after the mode is successfully set is the `vconvert → vrate → vscale → videosink` chain fully linked and the block dropped.

### 4. Fallback Handling
- If the incoming stream is not a broadcast-standard format (e.g., an 800x600 webcam feed), the auto-detect must safely fallback to a globally defined default mode (e.g., `1080i50`).
- The pipeline will then re-engage `videoscale` and `videorate` to pad/convert the non-standard signal into the fallback SDI format, preventing crashes.

### 5. Audio Routing Configuration
- **Stream Selection:** Support multi-track audio sources (e.g., MPEG-TS with multiple PIDs) by allowing users to choose which audio track is routed to the SDI output.
- **Channel Mapping:** Allow channel manipulation (using `audiomixmatrix` or similar) to map stereo/surround channels to specific SDI audio pairs, useful for broadcast compliance.
- **UI Integration:** Expose audio routing options in the Elixir/React UI alongside the SDI mode selector.

---

## Remaining Work

- [ ] **Hardware decode** — NVDEC (`nvh264dec`) for NVIDIA GPUs. VA-API tested but disabled (Intel HD 630 too weak).
- [ ] **True auto-detect** — Implement the dynamic GStreamer probing and reconfiguration architecture detailed above.
- [ ] **Docker deployment** — Verify DeckLink works inside container with device passthrough
- [ ] **Multi-output test** — Run 4+ routes with SDI outputs simultaneously
- [x] ~~Graceful SDI failure~~ — SDI sink failure no longer kills SRT/UDP outputs (`bbe6460`)
- [x] ~~Bulk delete button~~ — Added (`5d4863f`)
- [x] ~~Inline output popover~~ — Added (`ffa8169`)
