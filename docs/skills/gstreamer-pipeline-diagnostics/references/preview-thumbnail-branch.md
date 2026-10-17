# Preview / thumbnail branch — design, diagnosis, verification

A JPEG preview branch hung off the pipeline tee (dashboard "Live Preview"). The
reference implementations (the C engine branches) are the source of truth: read their
element set AND their comments, which carry the measured reason for every setting.

## Element set that survives a live stream

```
tee → queue (NO leak; max-size-buffers=0, max-size-bytes=64 MB, max-size-time=8 s) → tsdemux
     → [video pad] h264parse|h265parse → (H.264 only: drop DELTA_UNIT) → avdec_h264|avdec_h265
     → deinterlace → videoconvert → videoscale → capsfilter WxH
     → (1 fps PTS-gate probe) → jpegenc → appsink
```

- **Queue must not leak and must not be small.** On a 13 Mbps feed a branch queue with
  `leaky=downstream, max-size-buffers=2` holds ~2.6 kB ≈ 1.6 ms of transport stream, so
  nearly every packet is dropped before the demuxer: the demuxer/decoder then works on a
  shredded, non-contiguous stream. The reference uses no leak with 64 MB / 8 s limits and
  accepts back-pressure instead of packet loss.
- **H.264: keyframes only.** Drop buffers flagged `DELTA_UNIT` on the parser's src pad.
  A decoder joining a live transport stream mid-GOP has no references and emits
  macroblocks and green frames until the next IDR.
- **HEVC: never gate that way** (dropping inter pictures breaks reference continuity).
  Instead set `config-interval=-1` on h265parse so VPS/SPS/PPS repeat at IDRs, and
  `output-corrupt=FALSE` + `discard-corrupted-frames=TRUE` on avdec_h265 so a
  decoder-marked corrupt picture is rejected instead of written as a damaged JPEG.
  Guard each `set_property` with a `find_property` presence check — decoder builds differ.
- **Rate-limit with a PTS-gate probe in front of jpegenc, not `videorate`.** videorate
  asserts (`gstvideorate.c`, `GST_BUFFER_DURATION_IS_VALID`) on decoded frames that carry no
  duration — exactly what a source with an unknown framerate produces — and takes the whole
  pipeline down. Fall back to wall-clock when the PTS is invalid, and treat a backwards PTS
  as a new segment.
- **appsink: `sync=FALSE`, `async=FALSE`, `max-buffers=1`, `drop=TRUE`.** A preview may
  legitimately receive no frames (unsupported codec, long GOP) and must not hold preroll in
  PAUSED. Pull with a bounded timeout (`try_pull_sample` with ~1 s) so the writer thread
  still honours shutdown.
- `deinterlace` sits before videoconvert/videoscale; keep it even for progressive sources.

## Traps in the branch wiring

- **Do not build the chain with `decodebin`.** You cannot reach the parser/decoder it
  creates to set `config-interval` / `output-corrupt` / `discard-corrupted-frames`, and its
  decoder choice can be wrong: VA-API decoders rank above avdec_* and emit
  `interlace-mode="mixed"` for interlaced H.264, which videoconvert/videoscale cannot
  negotiate (`GST_FLOW_NOT_NEGOTIATED` loop). The reference demotes VA-API decoders to
  `GST_RANK_NONE` unless hardware decode is explicitly requested.
- **Drop-probe every demux pad you do not link.** An unlinked demux pad propagates
  `GST_FLOW_NOT_LINKED` back through the tee and stalls the whole pipeline.
- **Build the codec chain once.** In the pad-added handler, check the downstream sink pad is
  still unlinked before adding parser+decoder, add them to the pipeline, sync their state,
  then link; on any failure unlink and drop-probe the pad instead of leaving it half-linked.
- **Single-decode variant:** when the route already decodes the stream for a hardware
  output, tap the decoded frames (after videoconvert) instead of demuxing and decoding the
  same stream a second time.
- Element names must be unique inside the pipeline; the writer thread must hold the appsink
  weakly (a strong ref cycles and keeps the branch alive after teardown).

## Diagnosis

| Symptom | Cause |
| --- | --- |
| Uniform green / tinted frame | chroma never decoded — no keyframe gate and/or a leaky small queue |
| 16-px block grid, torn edges | decoding from a mid-GOP join or a shredded stream |
| Frozen preview, branch alive | PTS gate too strict, or the writer thread blocked on an unbounded pull |
| Preview never appears, pipeline stalls | unlinked demux pad, or an appsink holding preroll |

Confirm the branch built at all from the engine's own lines (`Thumbnail: Branch ready for
route ...`, `Thumbnail: linked video/x-h264 through avdec_h264`); a missing line means the
pad-added handler never ran.

## Verify objectively — and against a control

A text-only agent cannot look at the JPEG, so measure it. Render to raw RGB with ffmpeg and
compute the green share and the edge-step profile:

```bash
python3 scripts/preview_artifact_metrics.py /tmp/blackgate_preview_<route>.jpg
```

Then run the SAME measurement on a control frame decoded from the same source
(`ffmpeg -i "srt://..." -frames:v 1 -vf scale=320:180 -q:v 2 control.jpg`). This is the
step that decides the verdict:

- A **monotonically rising** step profile is content structure (large-scale detail), not
  blocks. A lone "high 16-px activity" number reads as macroblocks on perfectly good
  content — the same content through ffmpeg produced an identical profile, which is how the
  false alarm was caught.
- A green share matching the control is content (a greenish scene); a large green share with
  a near-zero chroma spread is the artifact.

Also confirm the file keeps refreshing on its cadence (`stat -c %Y <file>` twice) — a fixed
preview means the writer thread is stuck, not that the branch is fine.
