# Native pull pilot — HLS and RTMP (2026-10-21)

Status: **pilot passed**. This document records the measurements that decide whether the ffmpeg
sidecar can be replaced by native pulling code. Nothing in the codebase was changed to produce it.

## The question

For `rust-migration`, the ffmpeg sidecar currently remuxes `RTMP`/`HTTP`/`HLS` sources into MPEG-TS
over SRT on loopback (`lib/AGENTS.md` §2). Two things had to be true before writing native code:

1. Can GStreamer pull these sources on this appliance image, at realtime, without stalling?
2. Does `blackgate-engine` accept the resulting TS — its own timestamps, PAT and PMT — or does it
   only work with what the sidecar produces?

## Method

Read-only pilot against the operator's real production URLs. Per stream we measure the **largest PTS
gap** (not byte totals — totals hide stalls), sample the output size every 30 s and report the
**minimum** 30-second delta (a stream that runs two minutes then stalls shows up as a zero-delta
window), plus process RSS. Live routes were never touched: a `mode=listener` SRT socket accepts one
caller, so connecting to it would steal the running engine's socket.

Harnesses: `benchmarks/migration/scripts/native-pull-pilot/`.

## Result 1 — HLS pull, native: pass

`https://cdnw-pull.tvri.go.id/stream/ASEAN_GAMES/playlist.m3u8` via
`souphttpsrc ! hlsdemux ! tsparse`, 12 minutes:

```
samples           23 @ 30 s, final 333.7 MB
delta per 30 s    min 13.46 MB, max 15.43 MB   (≈ realtime, matches BANDWIDTH=4074000)
stall windows     0 of 22
RSS               2.0 MB flat (start / end / peak)
pipeline log      empty
final probe       h264 1920x1080@50 + aac 48000
PTS continuity    audio max gap 0.021 s, video max gap 0.020 s
```

The playlist is live (`#EXT-X-MEDIA-SEQUENCE:112`, 2 s segments, `.ts` — so it lands directly in the
engine's TS world with no re-mux). `hlsdemux`, `souphttpsrc`, `rtmp2src` and `glib-networking` are all
present on the appliance image. Note: the master playlist is a token indirection to another CDN host
and every segment carries `wsSession`; `hlsdemux` refreshes per segment, but the master→variant
indirection should be watched over hours, not minutes.

## Result 2 — RTMP pull, native: pass

`rtmp2src → flvdemux → h264parse/aacparse → mpegtsmux`, pulling from a local RTMP server, 7 minutes:

```
samples           14 @ 30 s, final 134.7 MB
delta per 30 s    min 7.45 MB, max 9.90 MB     (publisher at 2.5 Mbps = realtime)
stall windows     0 of 13
final probe       h264 1280x720@25 + aac 44100
PTS continuity    audio max gap 0.025 s, video max gap 0.040 s (= one frame at 25 fps)
pipeline log      empty
```

This is `lib/AGENTS.md`'s documented risk area ("GStreamer FLV demuxing and live RTMP inputs
deadlock or drift") and it held for seven minutes — but that note is the reason RTMP must be soaked
in hours before it replaces anything. `rtmp2src` requires a **two-segment** path: `rtmp://kunci`
fails with the misleading `Failed to connect: Host is not set`, while `rtmp://host:port/live/key`
works. That is also the shape OBS defaults to, and the shape the RTMP push phase must use.

## Result 3 — the engine accepts native TS: pass

Native HLS TS fed into the real engine (`preview: true`), output drained at the sink:

```
sink output       12 320 768 bytes in ~25 s (≈ realtime)
engine stats      "video-pid":256, "audio-pids":[257]   ← the CDN's own PAT/PMT, parsed as-is
engine log        Thumbnail: linked video/x-h264 through avdec_h264
```

So the CDN's own timestamps, PAT and PMT are fine: **the native path needs no timestamp rebase**, and
the sidecar's `-mpegts_copyts 0` is not required for correctness. For HLS the helper can therefore
pass TS fragments through verbatim, which also preserves the audio continuity that a demux/remux hop
breaks — the root cause the SDI audio-desync auto-restart in `route_handler.ex` works around.

## Method limitations found (all harness, not engine)

- **A standalone engine run cannot exercise an SRT source.** The SRT socket stat (`bytes-received`)
  grew at full rate while no TS buffer ever reached the tee: no PMT, no `video-pid`, nothing at the
  sink. This reproduced in seven variants — benchmark and application payloads, correct and
  incorrect argv, `preview` on and off, native and ffmpeg-rebased feeds. Carrying the *same* native
  TS over **UDP** is what proved the engine side. The SRT-carrier leg is covered by the real gateway,
  where these sources work today.
- **The benchmark probe is not a faithful model of the application.** `probe_engine_rss.sh` sends
  `"primary_source"` + `"type":"init"` and passes a socket path as argv; the application sends
  `"source"` (no `type`) and passes **only the route id** (`route_handler.ex:1213`), with the socket
  from `BLACKGATE_STATS_SOCKET`. Modelling the pilot on the probe cost an afternoon.
- Run third-party binaries with the working directory inside the scratch dir: a mediamtx run with the
  repo as cwd wrote `auto.crt`/`auto.key` into the repo root (removed; never committed).

## Recorded, not blocking

- `total-bytes-received` stays `0` while `bytes-received` advances.
- A `double free or corruption` abort appeared once during shutdown, in a standalone config with no
  preview and a direct `tee → sink`. It did not recur with the production shape and **no rotated
  release log contains `double free`, `corruption`, `SIGABRT` or `SOURCE_INVALID`** — latent, not live.
- `Pipeline construction is invalid, please add queues` appears 3× in the release logs too, and
  production is healthy, so it is a benign warning (the sink branch does get a `queue2`).

## Soak result — 60 minutes per leg: pass

`benchmarks/migration/scripts/native-pull-pilot/soak_long_native_pull.sh`, sampled every 60 s and
scored by stall window:

```
HLS   59 samples / 60 min : 1705 MB, delta 27.84-29.86 MB/min, STALL 0/58, log empty   → pass
RTMP  22 samples / 22 min : 431 MB,  delta 19.53-19.68 MB/min, STALL 0/21, log empty   → pass
```

Two honest qualifications:

- **The HLS RSS figure reported earlier was wrong.** The first runs reported "2.0 MB flat" from a
  sampler that matched the wrong process. The real number over an hour is **31.1 → 37.0 MB (peak
  37.6)** — bounded but *slowly rising* (~6 MB/hour), which is worth watching but never stalled.
  RTMP's RSS is genuinely flat: 21.3 MB start, end and peak.
- **The RTMP leg's pull ended after 22 minutes, cleanly** (empty pipeline log, i.e. end of stream,
  not a crash) — the publisher/server side ended the stream, not the pull. So RTMP is proven for
  ~30 minutes total across runs rather than a full hour. Re-run with `RTMP_MIN=60` once the
  publisher's own lifetime is fixed if a full hour of RTMP evidence is wanted.

## Not yet proven (the real gate)

- A **source-drop / reconnect test**: the sidecar's ffmpeg has `-reconnect`, so the native path must
  match it before it can replace it.
- **The handoff to the engine.** The pull legs above are proven; delivery into `blackgate-engine` is
  not. GStreamer's `srtsink` never completed a handshake in the **listener** role (ffmpeg and the
  engine's own `srtsrc` both failed against it), so the roles were flipped — helper as *caller*,
  engine's SRT source as *listener*. That removed the handshake error entirely (the engine now
  reaches PLAYING with no SRT error and the helper pulls the operator's real RTMP source without
  logging one), but **no data reaches the engine's sink yet**: the failure moved from "handshake
  rejected" to "connected but nothing flows". The open question is whether to keep debugging that
  or hand the stream over UDP, which the engine has already proven end to end.
- RTMP push (encoders pushing into the gateway). Deferred deliberately until the pull legs are done.
