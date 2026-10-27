---
name: gstreamer-pipeline-diagnostics
description: Use when a GStreamer pipeline crashes or output looks wrong.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [gstreamer, glib, rust, pipeline, media, debugging]
    related_skills: [systematic-debugging]
---

# GStreamer / glib-rs pipeline diagnostics

## When to Use

Triggers: the engine binary exits right after receiving its config, a route is refused
or loops in reconnect, the pipeline never reaches PLAYING, a telemetry key is always
exactly 0, a key is absent or visibly wrong (metadata showing N/A on a dashboard), an
output branch renders damaged frames (green tint, macroblocks, frozen preview), the
control plane reports a route running while no engine process exists, a newly added route
cannot receive while older routes stream fine, or a deploy/restart appears to have had no
effect.

## Always-on rules

- Reproduce the pipeline standalone before touching the control plane: pipe the exact
  init JSON the control plane sent into the engine binary —
  `printf '%s\n' '<init-json>' | ./<engine> <route-id>`. Copy that JSON verbatim from
  the control-plane log line that echoes what it received; a hand-reconstructed JSON
  omits the field that actually broke.
- Dispatch element-property writes on the property's VALUE type: `pspec.value_type()`.
  `pspec.type_()` returns the param-spec CLASS type (`GParamBoolean`, `GParamInt`), so
  every comparison against a value type misses and the fallback arm sets the wrong
  width — glib panics with `property 'x' of type 'Y' can't be set from the given type
  (expected: 'gboolean', got: 'gint')`. That kills the process at build time, so the
  pipeline never exists at all.
- A GstStructure field name is NOT the JSON wire key. Verify before trusting either:
  `gst-inspect-1.0 <element> | grep -A4 'stats'` for the fields at rest, and
  `strings /usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/gstreamer-1.0/libgst<plugin>.so | grep -E '^(bytes|packets|rtt|.*rate)'`
  for the full field table. Read the struct by field name, then rename on emit.
- A key that is present but permanently 0 while its siblings move is a lookup-name bug,
  not a source problem: `gst_structure_get_*` on a missing field returns 0 silently —
  no error, no warning.
- Before dismissing a zero-valued key, find its consumers. A "is data flowing?"
  fallback or a stall watchdog that reads it will restart a healthy route on a timer
  once the value is wrong; a green `health` string does not mean the key is unused.
- Fixing a field lookup changes only the lookup. Emitted JSON keys are the wire contract
  the control plane and UI read — rename at emit time, never in the wire format, and
  keep key order if a golden test pins it.
- A new telemetry key can break consumers by its VALUE SHAPE even when its name is fine: a
  recursive walker that treats every list as a list of nested stats maps raised `BadMapError`
  once per report as soon as a key holding a list of scalars (`audio-pids`) appeared. Before
  shipping a key whose shape differs from its siblings, grep the payload's consumers for
  recursion over values, and make the walker branch on the element type.
- A route status of started/playing is not proof the engine runs: the status is usually
  set when the config is accepted, before the pipeline is built. Verify with the process
  table and live telemetry instead — and check the telemetry is LIVE. A registry or dashboard
  that keeps the last message it received keeps reporting a plausible rate and `healthy` for a
  route whose engine died minutes ago, which reads as "the pipeline is fine, only the status is
  stale" and sends you into the state machine for a bug that is not there. Freshness (a recent
  timestamp) or a live engine process for that route id is what turns the number into evidence;
  `reconnecting` beside healthy-looking counters means the counters are stale, not the status
  machine is wrong. Fix the PRODUCER, not each reader: mark rows older than a few report
  intervals as stale (force health to disconnected and set an explicit stale flag) so a dead
  route cannot present its last report as live. Verify beside a live route — stopped reads
  stale/disconnected, the live one keeps reading fresh/healthy, and the stopped one recovers
  when restarted.
- Replacing the binary of a running engine fails with `Text file busy`. Stop the route,
  copy the binary, start the route; never swap a live executable in place.
- Fix the class, not the call site: when an accessor or lookup name is wrong, grep the
  workspace for every other use of it and fix them together.
- Prove the fix against the binary you just built before believing it failed. Whether the
  release target compiles the engine is repo-specific — read the release step instead of
  assuming (a `copy_native`-style step may run the engine build itself). An UNCHANGED `md5sum`
  after a rebuild is not evidence the build was skipped; it means the sources did not change,
  and the same holds for a binary whose timestamp merely looks old relative to the build —
  conclude "the release never built the engine" only after reading the release step, or you
  will report a build gap that does not exist. Either way a
  RUNNING app keeps executing the previous engine until its routes restart, so `md5sum` the
  release copy against the build output and confirm a string unique to the new code is in it
  (`grep -ac '<marker>' <binary>` — on a binary that is a presence check, 0 or 1, because the
  whole file counts as one line).
- Never add a give-up/attempt cap the reference implementation does not have. A counter
  incremented per TS packet expires in tens of milliseconds at 10-15 Mbps, long before
  the first SPS/IDR of a mid-GOP join, so the engine reports the stream type as unknown
  and metadata never appears. C/lite keep probing until the stream yields a header.
- Read the bytes at runtime instead of reasoning about the format: a temporary print of
  the offending packet's first bytes inside the parser, plus the same capture replayed
  through that exact parse path as a fixture, settles in one cycle what speculation does
  not. Print what the ENGINE parsed, not what a side capture of the same URL shows.
- Never judge stream health on a CUMULATIVE counter: the connection's startup burst stays in
  `lost/(received+lost)` for the whole life of the connection (measured: 3.2% cumulative
  while the last 20 s windows ran at 0.3-0.7%), so a route that settled long ago reports
  degraded forever. Publish the loss over the last report interval beside the cumulative
  value and judge on the window, falling back to cumulative only until a window exists.
  The same applies to any rate the UI derives from two absolute counters.
- To decide whether a defect belongs to the engine or to the host/network, run BOTH
  implementations against the same source on the SAME host, in the same window, with the
  same config, and compare their receive counters: the reference implementation is the
  control the path cannot explain away. Control the confounders or the result is worthless —
  launch order (swap it and re-run; a source listener is not obliged to favour its first
  caller), extra probe callers (they can exhaust the source listener's backlog and
  manufacture the loss you are measuring), and a window that includes the other process's
  startup burst. Clean the probes up with a bracketed pattern (`pkill -f 'engine-binar[y] probe'`):
  `pkill -f` matches the shell's OWN command line, so the plain pattern SIGTERMs the command
  you are running instead of the probes. Recipe: `references/engine-parity-comparison.md`.
- Read the OS's own UDP evidence before tuning a socket buffer: a FLAT `RcvbufErrors` in
  `/proc/net/snmp` while the receiver reports growing `lost` means those packets never
  reached the socket at all, so the buffers are not the problem. Per-socket `skmem` from
  `ss -u -a -m -p` shows the buffers libsrt actually got (`rb`/`tb`), which is how you prove
  a sysctl change took effect. Growing `SndbufErrors` while a destination has no connected
  caller is a sink draining to nobody, not a receive fault.
- Before treating a comparison target's value as ground truth, find the code path that
  produced it: a telemetry function with several branches can hardcode zeros for what it
  cannot measure (the C reference hardcodes 0 for lost/dropped/retransmitted/rtt in its
  transport-neutral branch), so a clean 0 may mean "this branch does not measure that". A
  nonzero value for a sibling field read from the same struct is what proves the real branch
  ran — check that before declaring the other implementation clean. Then check the GETTER
  itself, because a branch that does measure can still read nothing: the typed
  `gst_structure_get_*` calls type-check STRICTLY, so a `gint32` field read with
  `gst_structure_get_int64` returns FALSE and leaves the output variable at its initialiser —
  a permanent 0 indistinguishable from a clean link, while a `gint64` sibling read with that
  same call works and makes the zeros look credible. `gst_structure_to_string` prints field
  names AND types; `BLACKGATE_DUMP_STATS=1` prints the structure plus each typed getter's
  return value, and that pair of dumps settles name, type and branch in one run. Never discard
  a getter's return value, and match it to the type the dump shows.
- Prove element/property parity before blaming configuration: dump every readable property
  of the element in both implementations in one format and diff them (`BLACKGATE_DUMP_PROPS=1`
  prints `PROP name=value` in this repo). When the disagreement is about a COUNTER rather than
  a property, dump the stats structure instead (`BLACKGATE_DUMP_STATS=1`) — it carries the
  field types and the getter results that properties cannot show. Identical properties mean the difference is in how
  the engine DRIVES the pipeline, not in how it configures the element. In gstreamer-rs read
  properties only through the param spec's READABLE flag — `property_value()` on a write-only
  property (`passphrase`) panics and aborts the process, which looks like an empty dump.
- Prove a suspect branch by REMOVING it, not by reasoning about it: an env switch or an empty
  branch list that skips the preview or the sink turns "this queue back-pressures the tee"
  into a measured yes/no in one run. A ruled-out branch is a result — record it and stop
  suspecting it. Do not then "fix" receive loss by deleting the preview.
- Never let a preview/thumbnail branch shed compressed transport stream. A branch queue with
  `leaky=downstream, max-size-buffers=2` holds ~2.6 kB (~1.6 ms of a 13 Mbps feed), so nearly
  every packet is dropped before the demuxer and the preview decodes from a shredded,
  non-contiguous stream — a green tint or a 16-px block grid on the dashboard. Use a no-leak
  queue with generous byte/time limits, exactly like the reference branch.
- A non-leaky queue on a SINK branch is a memory commitment, not just a buffer: `queue2` with a
  large `max-size-bytes` grows its ring buffer up to that ceiling whenever the consumer lags.
  Size these queues from what the reference does, not from a round number — but never conclude a
  queue IS the cause of an RSS delta from its size alone: shrink or delete it and re-measure
  (measured: 50 MB -> 2 MB left the peak-RSS ratio unchanged at 3.12 -> 3.10). A peak-RSS delta in
  a parity harness is usually an OPTIONAL BRANCH only one side builds, so price each branch by
  running the engine standalone with and without it (an env switch like `BLACKGATE_NO_THUMBNAIL=1`
  or an empty branch list) and reading `VmHWM` from `/proc/<pid>/status`: the preview branch's
  H.264 decoder frame pool alone measured +32.6 MB (51.9 -> 19.3 MB RSS) on a config where the
  reference builds no preview at all. A delta that survives shrinking every buffer but vanishes
  with one branch disabled is a branch cost, not a buffering cost.
- An engine that infers an optional feature from an INCIDENTAL field builds it for every route,
  including headless and benchmark ones: this port keyed the preview branch off a non-empty
  `route_id`, while the reference builds its thumbnail chain only when the config asks for one.
  The comparison then charges the port for work the reference never does — a 3.1x peak-RSS
  "regression" that was purely an artifact of feature enablement, and a wrong fix (resizing
  queues) followed from believing it. Make enablement explicit in the wire config (a
  `preview`/`thumbnail` field, default OFF) and have the control plane set it, then confirm the
  feature still runs in production by checking the control plane actually sends that field —
  defaulting a live feature off without that step silently disables it. Before blaming a memory
  delta on any subsystem, ask what each side's config enables.
- A live preview must not feed a decoder mid-GOP: gate H.264 to keyframes (drop buffers
  flagged `DELTA_UNIT` on the parser's src pad) so the first decoded picture has its
  references. Do NOT gate HEVC that way (it breaks reference continuity) — repeat its
  parameter sets (`config-interval=-1`) and reject corrupt output instead
  (`output-corrupt=FALSE`, `discard-corrupted-frames=TRUE`). Rate-limit with a PTS-gate
  probe, never `videorate`, which asserts on frames without duration and kills the pipeline.
  Element set, wiring traps and the reference branch's rationale:
  `references/preview-thumbnail-branch.md`.
- Build the preview chain explicitly (`tsdemux` → parser → decoder), not with `decodebin`:
  the parser/decoder settings above live on elements you cannot reach through decodebin, and
  its decoder choice can fail negotiation (VA-API emits `interlace-mode="mixed"`).
  Drop-probe every demux pad you do not link — an unlinked demux pad propagates
  `GST_FLOW_NOT_LINKED` back through the tee and stalls the pipeline.
- Verify an image artifact against a CONTROL decode of the same source before claiming a fix:
  run the same metric (green share, edge-step profile) on an ffmpeg frame from the same URL.
  A monotonically rising step profile is content, not blocks — a lone "16-px activity"
  number reads as macroblocks on perfectly good content. Script:
  `scripts/preview_artifact_metrics.py`.
- Work on the branch the user names, and only that one. A reference implementation kept on
  another branch (or in a frozen archive) is READ-ONLY learning material: read it, diff it,
  build it in a throwaway location to measure against it, but never propose or apply changes
  there, and keep the answer free of the other branches' concerns. When the user scopes the
  work, scoping drift is the fastest way to lose their trust.
- Report the mechanism, the measurement and the still-open unknowns BEFORE changing code, and
  get agreement first: this user asks for exactly that ("we must know precisely before we fix
  something"), and the moment a symptom matches a familiar bug class is when a fix-first answer
  is most likely to be wrong — the status that looked stale was telling the truth while the
  counters were the stale ones. When he asks what an open item IS or what it is FOR rather than
  asking for a fix, answer in plain language for a non-developer — what it costs, what breaks if
  it is skipped, which item to do first — with no code and no jargon, and wait for the go-ahead
  before touching anything.

## Procedure

1. Establish process state first: `ps -o pid,etime,rss,cmd -C <engine>` plus the control
   plane's exit-status and reconnect lines. Alive / crash-looping / absent are three
   different problems with three different causes.
2. Grep the log for `panicked at` and the exit code before theorising about the input
   stream — a build-time panic means the input never mattered. Grep EVERY rotated log
   file: these logs rotate by SIZE, so a grep limited to the newest one can return zero
   hits for an event that did happen, which reads as "no restarts occurred".
3. Take the last init JSON from the log and reproduce standalone; read the panic.
4. Fix the root cause and re-run the standalone repro until it reaches PAUSED/PLAYING.
5. Rebuild; stop the route, copy the binary into the release, start the route.
6. Verify with live telemetry counters, not status strings.
7. Watch one full watchdog period (grace + stall threshold) with the process pid
   unchanged to prove no false restart, and confirm no new panic/reconnect lines.
8. When telemetry "looks wrong" rather than absent, sample the stored stats repeatedly and
   check the KEY SHAPE, not only the values: a slot holding another message type's keys
   (e.g. `sink-index`/`bytes-sent-total` inside the source slot) is a framing bug, and every
   consumer of the now-missing key silently reads 0 or nil.

## Pitfalls

- Any process that boots the control plane binds its IPC socket path and UNLINKS the
  existing file first (`/tmp/hydra_unix_sock`), so a dev or test instance running beside a
  live release silently removes the live listener's path: only NEW engine connections fail
  (`connect: Connection refused (os error 111)` -> routes crash-loop) while already-connected
  routes keep streaming and the control plane still answers RPC. Seen from, in order of how
  often it bites: `mix test` (it boots the app in-process), the IPC smoke harness, a second
  release node racing the first at boot, and a benchmark/parity harness that binds the same
  path to collect the engines IT spawns. Two flavours of one outage, pointing at different
  remedies: `connect: Connection refused (os error 111)` means the file exists but nobody
  listens (the listener died), while `connect: No such file or directory (os error 2)` means
  the path itself was unlinked — the live listener keeps accepting on an inode nothing can
  name, so only restarting the node re-creates the path, and every engine the app spawns dies
  instantly on a ~10 s reconnect cadence meanwhile. The socket file's mtime names the culprit —
  it matches the clobbering run, not the node's boot time. While it lasts the affected routes'
  CACHED telemetry still reads healthy, so diagnose from the process table and the engine's own
  log lines, never from the last stored counters. Make the path configurable per
  environment (app config + env var handed to the spawned engine's port env, a per-run path
  in the test config) and assert in a test that the test path is never the production one;
  hardcoding it on both sides guarantees a recurrence. Then verify the spawned process READS
  the variable you set — grep its source for the env name. A harness that exports a name nobody
  reads silently falls back to the hardcoded default, which is exactly what forces it to bind
  the shared path and clobber the live one. Bind only after proving no live
  listener answers on the path (`:gen_tcp.connect({:local, path}, 0, [:binary], 200)`), then
  raise with the path and the remedy — a second node must fail loudly instead of silently
  unbinding a healthy one, while a leftover file with NO listener must still be accepted
  (probe by connecting, never `File.exists?`). Acceptance test for the fix: re-run the former
  clobberer (`mix test`, a dev-env boot) against the live node and assert the socket file's
  mtime is unchanged, a bare connect still succeeds, and a freshly started route logs zero
  `Connection refused` — a new engine connection is precisely what the outage refused. Assert
  the mtime AND that nothing undoes it: a guard that refuses to bind is not enough while the
  same object's teardown unlinks the path anyway — release only what you acquired (an
  `owns_path` flag set after a successful bind). Measured: the guard fired, and the live socket
  was still deleted by the cleanup path of the failed acquire.
  Recovery: stop every node, remove the stale file, start clean.
- Replacing the engine binary inside a running release can hit `Text file busy` even with
  the route stopped if a stale engine process survives; confirm no engine process remains
  (`pgrep -f blackgate-engine`) before copying, and prefer a clean release build.
- A standalone repro whose stdin closes early ENDS the run: this engine treats stdin EOF as a
  shutdown request (`stdin closed (cond=0x10), shutting down pipeline`), so `<<< "$JSON"` and a
  heredoc kill it before you can measure anything — pipe from a producer that stays alive
  (`{ printf '%s\n' "$JSON"; sleep 90; } | ./<engine> <route-id>`). A standalone engine also needs
  a reachable stats socket: point the stats-socket env var at a path with a dummy listener (a
  few-line AF_UNIX accept loop) or its connect fails and it exits. Ready-made probe:
  `scripts/probe_engine_rss.sh`. Standalone sink-stats probe with its own socket:
  `~/.hermes/cache/scratch/srt-sink-probe2.sh` (scratch, may be pruned — reconstruct from this bullet).
  A probe engine also takes its route id as the FIRST argv: omit it and it runs as `unknown`
  (`Argument 1: unknown`), which combined with a non-overridden stats socket injects records into
  the LIVE registry under the wrong route id. Always pass an id AND export the socket path.
- A **listener** srtsink reports only `bytes-sent-total` at the top level; every per-connection
  figure — `packets-sent`, `packets-sent-lost`, `packets-retransmitted`, `rtt-ms`,
  `send-rate-mbps`, `bandwidth-mbps`, `negotiated-latency-ms` — lives inside `callers[]`. Measured
  on the production engine with one connected client: top level `packets-sent` 0, `rtt-ms` 0.0,
  `send-rate-mbps` 0.0; the same instant inside `callers[0]`: 2138, 0.068, 1.662. Anything that
  reads the top level of a listener leg therefore measures NOTHING, and it fails silently — the
  dashboard showed `0 Mbps` / `0.0 ms` next to a growing byte total, and the egress-loss verdict
  computed `0/(0+0)`, so the Egress Loss badge could never fire: its green was vacuous, not clean.
  `build_source_stats` (engine-stats) carried this exact caller fallback for srtsrc from the start;
  the sink path (`build_sink_stats`) was never given it. Aggregate the callers — sum counters and
  rates, MAX the RTT and negotiated latency (a per-path figure: the worst client is what a verdict
  must see) — and only when the top level is empty, so a sink in caller mode keeps GStreamer's own
  totals. Every egress listener route here hits this.
- `Pipeline construction is invalid, please add queues` plus a paired `clock problem` are
  ONE condition, not two bugs: `gstbasesink.c` posts `GST_ELEMENT_WARNING(sink, CORE, CLOCK,
  ...)` when the sink's `processing_deadline` cannot fit the upstream latency window
  (`min + deadline > max`), clamps `min = max`, and the resulting `max < min` makes
  `gstpipeline.c` post a second warning whose NULL message renders as the core default
  "GStreamer error: clock problem." (`gsterror.c`). A live source reporting `min == max`
  (srtsrc reports its configured latency as both) guarantees it. Confirm the values with
  `GST_DEBUG=basesink:6` before believing the advice — when queues already exist on every
  tee branch, the bound comes from the source and another queue changes nothing. Compare
  the construction against the reference implementation first: if it is identical, the
  warning is inherited, not a regression, and "fixing" it means deviating from parity.
- Telemetry framing: a newline-terminated record written as separate `prefix` + `json` +
  `newline` sends can be split by the reader's chunk boundary between prefix and payload.
  The orphaned JSON then matches the generic "starts with {" clause and is parsed as the
  WRONG message type — sink stats silently overwrote the source stats slot, health flapped
  to `disconnected`, and the stall watchdog read the byte counter as 0. Write each record in
  ONE call (identical bytes, no contract change) and make the reader remember a dangling
  prefix. Do NOT reach for full line-buffering when the handshake record has no trailing
  newline (`route_id:<id>`): that protocol is prefix-delimited, and buffering swallows
  the handshake until the next newline arrives.
- A TS packet walker that steps a fixed 188 bytes from byte 0 silently reads garbage when
  an SRT payload boundary falls mid-packet: every packet lands on a payload byte, and the
  occasional `0x47` there passes the sync check, yielding a bogus PAT/PMT (a live stream
  reported video PID 65 instead of 256, and a "PMT" packet with PID 32 and a 140-byte
  adaptation field). Resync to the first `0x47` whose byte 188 further on is also a sync
  byte before stepping; the reference source probe does the same. See
  `references/mpegts-psi-parsing.md`.
- Strip emulation-prevention bytes (`00 00 03`) from a NAL before bit-parsing it: encoders
  insert the `0x03` so an RBSP can never contain a start code, and a parser reading the raw
  NAL consumes it as data, shifting EVERY field after the first escape. The signature is a
  value that is wildly wrong but not zero while the fields parsed earlier are correct — a
  live High-profile SPS with two escapes reported a framerate of 2^24 (16777216) with
  `inferred = false`, while width/height/profile/level (read before the VUI) were right.
  The reference strips it for both H.264 and HEVC. See
  `references/mpegts-psi-parsing.md`.
- A side capture of the same URL is not ground truth for PSI values — and the usual reason is the
  tool that wrote the file. `ffmpeg -c copy -f mpegts` does NOT pass packets through: the reader
  demuxes and the mpegts MUXER re-muxes, assigning its own PIDs (program 1, PMT PID 4096, video
  `0x100`, audio `0x102`, `0x103`, ...). Every "disagreement" with such a file is a description of
  ffmpeg's muxer, not of the source: an ffmpeg capture showed PMT 4096 / video 256 while the engine's
  own parse of the same source reported video 52 / audio [53,55,56] — the engine was right, and the
  file was ffmpeg's own output. Capture RAW bytes (python `socket.recv` on a udpsink, `socat
  UDP-RECV`, or read the sink's socket) and decode them with `scripts/ts_pid_histogram.py`, or replay
  them through the engine's own parser via the `ts_probe_real_capture` test with
  `TS_PROBE_FIXTURE=<capture>`. Only then compare — and never "correct" the engine to match a file.
  A corollary worth remembering: three audio PIDs whose values are the ASCII codes of the digits the
  previous session recorded (`[53,55,56]` for `"578"`) look like a string split into bytes, and were
  not — `inspect(v, charlists: :as_lists)` reveals the real integers, but it does NOT make them wrong.
- Run the rebuild -> restart -> verify sequence as separate commands with a printed marker
  per step, not as one `&&` chain. A transient failure in an early gate aborts the chain and
  silently skips the middle steps, so the state you then debug belongs to a step that never
  ran (one flaky formatting check skipped the stop/rebuild half and made a working stop look
  broken), while any `;`-separated steps after it still execute and produce a half-applied
  state that no single step explains.
- Never truncate a build's output (`| tail -2`): a build that fails part-way leaves a
  HALF-POPULATED artifact and the line explaining it is the one you cut. Verify the artifact's
  completeness before starting it — a release that dies with `load_failed` for CORE modules
  (kernel, lists, supervisor) is missing its own lib directory, not a broken toolchain. Count
  the apps under the release's `lib/` (a full Phoenix release has dozens; the broken one had 8
  and none of its own) and rebuild explicitly — compile, then release — when the count is low.
- `Pipeline exited with status 1, entering reconnect mode` repeating on a ~10 s cadence,
  with `pipeline: connect: Connection refused (os error 111)` among the engine's own lines,
  is the engine failing to reach the control plane's stats socket — not a stream, pipeline
  or parser fault. The control plane can still look healthy (RPC answers, an
  already-connected route keeps streaming) because only NEW connections are refused, so
  check the socket path itself before touching the pipeline. See
  `references/blackgate-engine-diagnostics.md`.

## Support files

- `references/blackgate-engine-diagnostics.md` — log paths, live-state rpc queries, stats
  key meanings and the deploy sequence for the blackgate SRT gateway.
- `references/mpegts-psi-parsing.md` — PAT/PMT byte arithmetic, PSI section_length
  composition, stream-type tables, framerate-in-SPS ground truth, fixture test recipe.
- `scripts/ts_pid_histogram.py` — PID histogram + PAT/PMT decode for a capture, without
  a GStreamer session.
- `references/preview-thumbnail-branch.md` — the element set a preview/thumbnail branch
  needs (no-leak queue, keyframe gate, HEVC parameter-set repetition, PTS gate), the wiring
  traps, and how to verify a preview objectively against a control decode.
- `scripts/preview_artifact_metrics.py` — green share + edge-step profile for a preview
  JPEG, optionally diffed against a control decode frame.
- `references/engine-parity-comparison.md` — how to run a port and its reference
  implementation side by side on one host (build the reference from the repo's frozen,
  manifest-verified archive, or from a throwaway worktree when there is none; drive both
  standalone; compare telemetry), the confounders to control (including optional branches and
  peak-RSS pricing), and what element parity does and
  does not prove. Ends with the instrument check (dump the raw stats structure with its field
  types and the getter results before believing either side's counters), how to automate the
  comparison with a benchmark harness, and how to read a variance/`inconclusive` result without
  reporting it as a regression.
- `scripts/probe_engine_rss.sh` — run one engine standalone against the exact init JSON and
  print its peak RSS (`VmHWM`), for pricing an optional branch or comparing memory without a
  full harness run.
