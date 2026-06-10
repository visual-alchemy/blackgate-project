# Design: SDI Audio Channel Selection
> **Status: PARKED** — Implementation ready, waiting for SWIT broadcast monitor to be set up for physical SDI audio verification.
> **Roadmap Reference:** Item 10 — `ROADMAP.md:L71`

---

## Problem Statement

International broadcast feeds (e.g. Premier League SRT, BWF) embed multiple stereo audio pairs inside a single 8-channel MPEG-TS stream:

| Channel Pair | Typical Content |
|---|---|
| Ch 1+2 | International mix (clean feed, no commentary) |
| Ch 3+4 | Commentary — Language A (e.g. English) |
| Ch 5+6 | Commentary — Language B (e.g. Indonesian) |
| Ch 7+8 | Atmo / ambient sound |

The gateway currently **always outputs Ch 1+2** because `audiomixmatrix` uses `first-channels` mode. There is no way to select a different pair per SDI destination.

---

## Chosen Approach: `audiomixmatrix` Programmatic GValue Matrix

**Do NOT use** `gst_util_set_object_arg(G_OBJECT(amix), "matrix", "<<...>>")` — this causes **SIGSEGV** on GStreamer 1.24 (confirmed in production on 2026-06-09).

Instead, build the extraction + upmix matrix programmatically using the GValue API:
- Input: N channels (whatever the source has, e.g. 8)
- Output: 8 channels (required for DeckLink SDI frame)
- Matrix: Routes the selected pair to output Ch 1+2, remaining output channels zeroed

### Matrix Examples

**Pair 1 (Ch 1+2) — current default:**
```
Out\In  0    1    2    3    4    5    6    7
  0   [ 1.0  0.0  0.0  0.0  0.0  0.0  0.0  0.0 ]
  1   [ 0.0  1.0  0.0  0.0  0.0  0.0  0.0  0.0 ]
  2   [ 0.0  0.0  0.0  0.0  0.0  0.0  0.0  0.0 ]
  ...
  7   [ 0.0  0.0  0.0  0.0  0.0  0.0  0.0  0.0 ]
```

**Pair 2 (Ch 3+4):**
```
Out\In  0    1    2    3    4    5    6    7
  0   [ 0.0  0.0  1.0  0.0  0.0  0.0  0.0  0.0 ]
  1   [ 0.0  0.0  0.0  1.0  0.0  0.0  0.0  0.0 ]
  2..7  zeros
```

Formula: `matrix[out_row][in_col] = 1.0` where `in_col = (pair - 1) * 2 + out_row` for rows 0 and 1; 0.0 everywhere else.

---

## Files to Change

### 1. `native/src/gst_pipeline.c`

In `add_sink_to_pipeline`:
- Read `audio_channel_pair` from `sink_config` JSON (integer, default `1`)
- Replace `gst_util_set_object_arg(G_OBJECT(amix), "mode", "first-channels")` with programmatic GValue matrix construction
- Set `in-channels` dynamically (or use a fixed large value like 8 as upper bound)
- Fallback: if source channels < `(pair-1)*2 + 2`, log warning and fall back to pair 1

### 2. `lib/blackgate/route_handler.ex` → `sinks_from_record`

In the SDI sink serialisation function, include `audio_channel_pair` from the destination config:
```elixir
%{
  "type" => "sdisink",
  "device-number" => device_number,
  "audio_channel_pair" => Map.get(dest, "audio_channel_pair", 1),
  ...
}
```

### 3. Frontend — SDI Destination Form

Add a dropdown to the SDI destination edit form:
- Options: `Ch 1+2` / `Ch 3+4` / `Ch 5+6` / `Ch 7+8`
- Maps to `audio_channel_pair: 1 | 2 | 3 | 4`
- Default: `Ch 1+2`
- Stores in Khepri destination config via existing API

---

## Test Plan (requires SWIT broadcast monitor)

### Test Infrastructure — ffmpeg Synthetic 8-Channel Source

Run on the gateway (in background or tmux session):
```bash
ffmpeg -re \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000" \
  -f lavfi -i "sine=frequency=1320:sample_rate=48000" \
  -f lavfi -i "sine=frequency=1760:sample_rate=48000" \
  -f lavfi -i "testsrc2=size=1920x1080:rate=25" \
  -filter_complex "[0][1][2][3]amerge=inputs=4[a]" \
  -map "[a]" -map "4:v" \
  -c:a pcm_s16le -ar 48000 \
  -c:v libx264 -preset ultrafast \
  -f mpegts "srt://127.0.0.1:40100?mode=listener"
```

Audio content per pair:
- Ch 1+2: **440 Hz** (A4)
- Ch 3+4: **880 Hz** (A5 — one octave up)
- Ch 5+6: **1320 Hz** (E6)
- Ch 7+8: **1760 Hz** (A6)

### Test Route Config
- Source: `SRT`, URI = `srt://127.0.0.1:40100?mode=caller`
- Destination: `SDI`, device = `1` (free — BWF Court 1 slot), `audio_channel_pair` = `1`

### Available Free DeckLink Devices (as of 2026-06-09)
- **Device 1** ← recommended for testing (BWF Court 1 slot, BNC labelled)
- Device 2 (BWF Court 3 slot)
- Device 5 (BWF Court 2 slot)
- Device 6 (BWF Court 4 slot)

### Verification Steps
1. Connect DeckLink Device 1 SDI output → SWIT broadcast monitor (check channel count + levels)
2. Set `audio_channel_pair=1` → hear/see **440 Hz** on Ch 1+2
3. Change to `audio_channel_pair=2`, restart route → hear **880 Hz** on Ch 1+2
4. Change to `audio_channel_pair=3`, restart route → hear **1320 Hz** on Ch 1+2
5. Change to `audio_channel_pair=4`, restart route → hear **1760 Hz** on Ch 1+2
6. SWIT monitor should show 8 channels present, with audio level only on Ch 1+2 (others silent) ✅

---

## Constraints & Gotchas

- **Do NOT set `audiomixmatrix` matrix via string** — SIGSEGV on GStreamer 1.24. Use GValue API only.
- **Source channel count may be 2** (stereo RTMP): if `audio_channel_pair > 1`, the matrix rows will reference non-existent input channels — handle gracefully with fallback.
- **SRT sources (e.g. Premier League)** are the primary real-world use case. RTMP sources (Magna TV, NTV, BWF Courts) are stereo-only and this feature has no effect on them (pair=1 always).
- **Existing routes are unaffected** — default `audio_channel_pair=1` maps to `first-channels` equivalent behaviour.
