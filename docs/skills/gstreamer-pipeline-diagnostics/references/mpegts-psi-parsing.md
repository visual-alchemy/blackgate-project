# MPEG-TS PSI parsing (PAT/PMT) and video metadata probes

Byte arithmetic for a probe that reads PAT/PMT and a video header out of a raw TS stream.
Verified against a live H.264 + AAC source and the C reference implementation.

## Section offsets

Offsets below are from the first byte of the SECTION (the `table_id`). A section starts at
`payload_start + 1 + pointer_field`, where the payload starts after the header (4 bytes)
and, when `af_control` is 2 or 3, after `1 + adaptation_field_length` more.

PAT (`table_id` 0x00, always PID 0):

| +0 table_id | +1..2 section_length | +3..4 transport_stream_id | +5 version |
| +6 section_number | +7 last_section_number | +8.. entries of 4 bytes | CRC 4 |

PMT (`table_id` 0x02, PID from the PAT):

| +0 table_id | +1..2 section_length | +3..4 program_number | +5 version |
| +6 section_number | +7 last_section_number | +8..9 PCR_PID | +10..11 program_info_length |
| +12..12+program_info_length program_info | stream entries | CRC 4 |

Stream entry: `stream_type(1)`, `elementary_PID(2)`, `ES_info_length(2)`, `ES_info`.

When walking with a cursor that has already consumed `table_id` and `section_length`, the
PMT must skip **five** bytes (program_number 2 + version 1 + section_number 1 +
last_section_number 1) before PCR_PID — not four. Skipping four reads
`program_info_length` one byte early (the low byte of PCR_PID, e.g. 0xF0 -> 240), the
stream loop then jumps past the end of the packet and EVERY PMT parse fails silently: no
video PID, no stream type, no metadata keys at all. The PAT's own skip is 5 as well
(transport_stream_id 2 + version 1 + section_number 1 + last_section_number 1).

`section_length` counts everything after the length field: the fields above + program_info
+ stream entries + the 4-byte CRC. Once the cursor sits at the first stream entry, the
section ends `section_length - 13 - program_info_length` bytes further on (13 = 5 + 2 +
2 + 4); clamp that to the packet size before looping, and stop the loop at that point so
the CRC is not read as a stream entry.

## Stream types

- Video: H.264 0x1B, HEVC 0x24, MPEG-2 video 0x02.
- Audio: MPEG-1 0x03, MPEG-2 0x04, AAC-ADTS 0x0F, AAC-LATM 0x11, AC-3 0x81, E-AC-3 0x87.

Collect the audio PIDs while scanning the SAME PMT: do not return at the first video
entry, because the audio entry normally follows it and a `break`/early return loses it.
Keep the first video entry seen (that is the elementary PID to scan for a header) and push
every audio entry into the list that becomes the emitted `audio-pids`.

## Framerate is usually NOT in the SPS

Before "fixing" a framerate parser, check whether the stream even carries it:

```bash
ffmpeg -hide_banner -loglevel trace -i capture.ts -c:v copy -bsf:v trace_headers -f null - \
  2>&1 | grep -iE 'timing_info_present|num_units_in_tick|time_scale|sar_'
```

A live H.264 source reported `timing_info_present_flag = 0` — no rate exists in the SPS
(the 24 fps visible to ffprobe comes from PES timestamps). The reference defaults to
25/1 with an `inferred` flag and the UI renders it with a `~` prefix; keep that rather
than inventing a rate. `trace_headers` also settles SAR, `frame_mbs_only_flag`
(interlacing) and chroma without guessing.

## Emulation-prevention bytes

H.264 and HEVC insert a `0x03` after every `00 00` pair so an RBSP can never contain a start
code. Remove them BEFORE bit-parsing, or every field after the first escape is read from the
wrong bit position:

- strip from the RBSP only — H.264 after the 1-byte NAL header, HEVC after the 2-byte one;
- the rule is `zero_run >= 2 && byte == 0x03 -> drop it and reset the zero run`; a dropped
  escape is not itself a zero byte, so resetting the counter is part of the rule;
- a real High-profile SPS with two escapes parsed as `fps_num = 16777216` (2^24 — the `1` of
  `num_units_in_tick` shifted 24 bits) with `inferred = false`, while every field read before
  the VUI stayed correct. A wrong-but-not-zero value is the signature; a missing key is not;
- ground truth from the capture: `trace_headers` prints `num_units_in_tick` and `time_scale`,
  and for H.264 progressive `fps = time_scale / (2 * num_units)` (50/1 -> 25 fps). ffprobe's
  `r_frame_rate` shows `time_scale / num_units` (50/1) while `avg_frame_rate` shows the real
  25/1 — do not "fix" the parser to match `r_frame_rate`;
- keep the bytes: pull the SPS NAL (`00 00 00 01` + NAL type 7, reassembled from the video
  PID's PES payload) out of a capture and assert the parsed values in a unit test. It fails on
  the unescaped path and passes once the escapes are dropped. Extract using the capture's own
  PID (`ffprobe -show_streams ... id=`), which can differ from the PID the engine reports for
  the same URL.

## Probe rules

- No give-up cap (see SKILL.md). Probe until a header is parsed; the engine joins mid-GOP.
- Resync packet boundaries per buffer (see SKILL.md): SRT payloads are not TS-aligned.
- Accumulate the elementary PID's PES payload, then scan it for `00 00 00 01` + NAL type 7
  (H.264 SPS) / the HEVC equivalent; PES boundaries are not start codes.

## Fixture test recipe

```bash
ffmpeg -hide_banner -i 'srt://<host>:<port>?mode=caller&latency=2000' -c copy -t 4 /tmp/capture.ts
TS_PROBE_FIXTURE=/tmp/capture.ts cargo test -p <crate> -- --nocapture <probe test>
```

Feed the file in 1316-byte chunks (7 x 188 = a typical SRT payload) AND in a second pass
starting a few bytes in (`data[100..]`) so the resync path is exercised — an aligned-only
feed passes even with a broken stride. Assert on the parsed VALUES (dimensions, PIDs,
profile) rather than printing "detected", so a regression fails the run instead of
producing a plausible line. A capture that starts on a keyframe hides mid-GOP behaviour:
the first video packet carries the SPS, so attempt-count bugs only show up live.
