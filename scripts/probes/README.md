# Probe scripts

Harnesses used to find and prove the H.264 decode memory leak, and to compare GStreamer versions without
touching the running appliance. They are kept because the leak was invisible to valgrind and to the usual
obvious knobs, so the way it *was* measured is the valuable part — repeating these runs is how any future
"it leaks again" claim gets settled.

Nothing here starts a route, binds a live port (16000-20000), touches the DeckLink device, or writes to the
live stats socket. Each probe picks its own ports, its own stats socket, and pins itself away from the cores
the live engines decode on (`CPUS`, default `4-6`).

## Reading order

| Script | Question it answers | Result it produced (1.24.2) |
|---|---|---|
| `realtime-avdec.sh` | does a live-shaped feed (monotonic PTS, real time, CPU only) leak? | +5 MB / 15 min |
| `sdi-branch-probe.sh` | does the engine's SDI branch leak with the DeckLink sink replaced by fakesink? | +94 MB / 15 min, linear |
| `engine-gst-ab.sh` | does our engine binary run on another GStreamer version? | yes: maps 1.26.6, decode branch, stream flows, +3 MB / 20 min |
| `decode-bisect.sh` | which element holds it: parser or decoder? | h264parse flat, avdec_h264 grows ~10 MB/min |
| `decode-alt.sh` | do other decoders leak too? | vaapi flat (bit-identical pixels), openh264 +1900 MB, vulkan dead |
| `vaapi-verify.sh` | is the flat VA-API arm actually decoding? | 9 min flat at 105 MB, CPU 29% |
| `leak-isolate.sh` | is the looped-PTS queue artefact responsible? | no: queue2 / no-queue / buffer-queue all grow |
| `malloc-threshold-ab.sh` | is it glibc arena/trim/mmap-threshold retention? | no: base +41, pinned +37, arena1 +39, arena1t +42 MB / 300 s |
| `sdi-rss-map.sh` | which mapping class grows? | `[anon]` +101 MB, `[heap]` +0, shared libs +0 |
| `sdi-massif.sh` | does massif name the leaking stack? | no: heap +1.9 MB while RSS +15 MB — valgrind replaces malloc |
| `valgrind-probe.sh` | are pointers lost at all? | no: definitely lost 28 KB, heap flat over 20 min |
| `heaptrack-probe.sh` | does heaptrack name the stack? | no: segfaults on this pipeline, records only startup allocations |
| `live-smaps-census.sh` | read-only census of a live engine's mappings | arena-class mappings 1 -> 3 (+136 MB) |
| `ab-decode-probe.sh` | engine with preview on vs off, real SRT chain | harness for engine-level A/B |
| `sdi-shape-probe.sh` | first attempt at the SDI shape over SRT | superseded by `sdi-branch-probe.sh` |
| `sdi-bisect.sh` | branch bisect v0..v4 | v2 (decode) grows, v3 fails negotiation |
| `arena-watch.sh`, `soak-watch.sh` | long-run RSS sampling of live routes | baseline trends per route |

## The answer these produced

The leak is in the software decoder path, not in the appliance code:

- `gst-libav` 1.24.1 (Ubuntu 24.04) leaks roughly **233 bytes per decoded frame**, which is 20 MB/h for a
  bare decode chain and ~47 MB/h for a live SDI route.
- `gst-libav` 1.26.6 does not: the same SDI-shaped branch went from **+94 MB to +6 MB over 15 minutes**, with
  the curve flattening instead of rising, at the same CPU load (250%).
- The engine binary itself runs unmodified on 1.26.6 (ABI stable within GStreamer 1.x) — the prefix run maps
  `libgstreamer-1.0.so.0.2606.0` and builds its decode branch normally.

## Running against a newer GStreamer without installing it

`GST_PREFIX=<prefix>` works on `realtime-avdec.sh`, `sdi-branch-probe.sh` and `engine-gst-ab.sh`. It sets
`LD_LIBRARY_PATH`, `GST_PLUGIN_SYSTEM_PATH` and a private `GST_REGISTRY`, so the system packages the live
routes use are never touched.

Two traps, both hit for real:

- **Delete the registry when the prefix changes.** A registry written while a plugin was unresolvable keeps
  reporting it missing forever; `multifilesrc` "did not exist" purely because of a stale registry file.
- **A flat RSS with low CPU is a stalled pipeline, not a clean result.** Two early "flat" runs (66 MB, cpu 0%)
  were dead pipelines. Every probe here therefore prints CPU or a frame count — a number without proof of
  life is not evidence.

## Pitfalls found while building these

- The file loop restarts PTS every 20 s, which inflates the leak rate roughly 13x versus a real feed. Never
  quote a file-loop number as a live rate.
- A TS file with audio makes `tsdemux` expose a second pad that `gst-launch` cannot route, leaving the branch
  stalled. Use the video-only file.
- `num-buffers` on `multifilesrc` counts TS buffers, not video frames: a "60 frame" md5 test wrote 33 GB of raw
  video before it was killed. Bound by wall clock and divide by the frame size instead.
- `pkill -f` with a pattern that appears in the probe's own command line kills the caller's shell. Match on
  `-x gst-launch-1.0` and inspect `/proc/<pid>/cmdline` before signalling.
- An ffmpeg SRT listener serves exactly one caller; two receiver arms need two senders.
- `engine` reads its route JSON from stdin and exits on EOF: keep stdin open past the last sample.
