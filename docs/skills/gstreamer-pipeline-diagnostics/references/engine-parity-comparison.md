# Comparing a port against its reference implementation

Use when a port (Rust engine) and its reference implementation (C engine, another branch)
disagree on behaviour and you must decide which side owns the defect. Running the reference
on the SAME host as the port is what converts "the other machine looks fine" into a
measurement, because the network path and the OS are then identical for both.

Do not report a cross-machine comparison as a finding — two hosts differ in NIC, kernel,
switch path and caller history. Reproduce the difference on one host first.

## 1. Build the reference next to the port

Prefer the repo's FROZEN reference archive when it keeps one — a benchmark-only copy of the
reference engine is the intended oracle, needs no branch checkout, and its manifest gate must
pass BEFORE it is built. Verify, then build; never edit it (its immutability is what makes it
an oracle).

```bash
make -C native/archive/<ref-engine> verify   # mandatory checksum/manifest gate
make -C native/archive/<ref-engine>          # artifact name from the Makefile's MAIN_EXEC
```

With no archive, check out the reference branch into a throwaway worktree so that branch stays
untouched (and nothing lands in the port's git history).

```bash
git worktree add /tmp/<ref> origin/<reference-branch>
```

Build the C engine where its dev headers are missing. Install the one real dependency first
(`sudo apt-get install -y libcjson-dev`) and ask the user for that step rather than working
around it; only when no package can be installed, vendor the JSON library into the source tree
the wildcard already globs. The Makefile's `pkg-config` line also pulls in test-only deps, so
override both flag variables.

```bash
# cJSON is two files upstream; the .c goes in src/ (the Makefile globs src/*.c) and the
# .h in include/ (the compile line is -Iinclude, so <> cannot find it in src/)
curl -sSLo /tmp/<ref>/native/src/cJSON.c https://raw.githubusercontent.com/DaveGamble/cJSON/v1.7.18/cJSON.c
curl -sSLo /tmp/<ref>/native/include/cJSON.h https://raw.githubusercontent.com/DaveGamble/cJSON/v1.7.18/cJSON.h

cd /tmp/<ref>/native
make CFLAGS="-Wall -Wextra -g $(pkg-config --cflags gstreamer-1.0 gstreamer-app-1.0)" \
     LDFLAGS="$(pkg-config --libs gstreamer-1.0 gstreamer-app-1.0 gio-2.0) -lsrt-gnutls"
```

- Drop `cmocka` from the flags (tests only) and expect a `-lgnutls/-lnettle/-lhogweed`
failure: the SRT dev package is named `libsrt-gnutls` here and carries its own deps, so
`-lsrt-gnutls` alone links. A `pkg-config --cflags ... srt` invocation fails as a WHOLE when
one package in the list is unresolvable, printing nothing at all — ask for packages
separately so a missing `.pc` cannot silence the others.
- The C binary's name differs from the port's (`blackgate_pipeline` vs `blackgate-engine`);
check the Makefile's `MAIN_EXEC` instead of guessing.

## 2. Drive both standalone with the same config

Both engines read the init JSON from the first stdin line and take the route id as argv[1],
so one shape drives both. Keep stdin open for the whole run (a closed pipe makes the engine
shut down) and give each probe its own sink port and its own route id:

```bash
JSON='{"route_id":"ab-c","sinks":[{"latency":2000,"type":"srtsink","uri":"srt://0.0.0.0:12092?latency=2000&mode=listener"}],"source":{"type":"srtsrc","uri":"srt://<host>:<port>?latency=2000&mode=caller"}}'
( { printf '%s\n' "$JSON"; sleep 200; } | /tmp/<ref>/native/build/<ref-binary> ab-c > /tmp/ab_c.log 2>&1 & )
```

Clean probes up with a bracketed pattern (`pkill -f 'engine-binar[y] probe'`): `pkill -f`
matches the shell's OWN command line, so the plain pattern terminates the command you are
running instead of the probes, and the comparison dies mid-run.

Both engines talk to the control plane's stats socket, so a probe route id is enough: the
running app stores their telemetry under that id and you read it back with
`Blackgate.RouteStatsRegistry.get_stats/1` (see `blackgate-engine-diagnostics.md` for the RPC
wrapper). No app-side change is needed, and an unknown id is harmless.

## 3. Compare, then control the confounders

Sample both at the same moment and report the pair, never one side alone:

```
ref    recv=203815  lost=0     dropped=0     retrans=0     rate=13.44 Mbps  rtt=0.816
port   recv=203347  lost=5600  dropped=1074  retrans=4740  rate=13.41 Mbps  rtt=0.540
```

Confounders that will hand you a false attribution — each one is a re-run, not an argument:

- **Launch order.** Swap who connects first and repeat. A source listener can serve its first
  caller cleanly and degrade later ones, which looks exactly like a port defect. If the loss
  follows the engine and not the order, the port owns it.
- **Extra probe callers.** Every probe is another connection to the source. Several at once
  can exceed the source listener's backlog, which shows up as `Error on SRT socket:
  Listener's backlog exceeded` and manufactures loss on the very route you are measuring.
  Stop the live route under test and keep the probe count minimal, then re-read the error
  count for both sides before concluding anything.
- **Counter resets.** A source reconnect resets the srtsrc counters; a negative delta between
  two samples means you compared across a reconnect, not across a link condition.
- **Log volume / stdout back-pressure.** Redirect each engine's stdout to its own FILE when
  comparing, so neither can be slowed by a reader that is not draining it.
- **Same libraries.** `ldd` both binaries and confirm the same `libgst*.so` and the same
  `libgstsrt.so` plugin file, or the comparison is between two SRT builds.
- **Optional branches.** A peak-RSS (or CPU) delta is usually a branch one side builds and the
  other does not, not a buffer that grew. Price each branch separately: run the engine standalone
  with the exact init JSON and toggle one branch at a time (an env switch such as
  `BLACKGATE_NO_THUMBNAIL=1`, or an empty branch list), reading `VmHWM` from
  `/proc/<pid>/status` after the same warm-up. Measured on one config: preview on 51.9 MB,
  preview off 19.3 MB, reference 26.1 MB — the entire "3.1x memory regression" was one branch the
  reference's config never asked for, and resizing the sink queue (the first suspect) changed the
  ratio by 0.02. Then check what each side's CONFIG enables: an engine that infers the branch from
  an incidental field (a non-empty route id) builds it even for headless and benchmark plans.
  Recipe: `scripts/probe_engine_rss.sh`.

## 4. Prove element parity, then look elsewhere

When the pipelines and configs look identical, dump the effective element properties in both
and diff them rather than reading the config JSON again:

```bash
{ printf '%s\n' "$JSON"; sleep 14; } | BLACKGATE_DUMP_PROPS=1 <engine> <probe-id> 2>&1 \
  | grep '^PROP ' | sed 's/[[:space:]]*$//' | sort > /tmp/props_<engine>.txt
diff /tmp/props_c.txt /tmp/props_r.txt
```

The port prints `PROP name=value` from `dump_element_props` in `engine-gst/src/builder.rs`
(called from `make_source` once all properties are applied); add the matching block to the
reference's property-application function IN THE WORKTREE only. Expect only rendering
differences (`TRUE` vs `true`, quotes, type prefixes) and skip write-only properties: in
gstreamer-rs, filter on `pspec.flags().contains(glib::ParamFlags::READABLE)` or
`property_value()` panics on `passphrase` and the dump comes out empty.

Reading properties for this is legitimate in the source element; keep the same values in
view when writing the rule (latency, mode, auto-reconnect, keep-listening, poll-timeout,
wait-for-connection, uri) — if they match, configuration is no longer a hypothesis.

What parity does NOT prove: how the engine drives the element. Timing of state changes,
threading, and what the pipeline does around the source can still differ. When element
properties, config, libraries, socket buffers, branch presence and caller order are all
eliminated, the next diagnostic is the pipeline graph itself — dump both with
`GST_DEBUG_DUMP_DOT_DIR` and diff element/queue/thread structure (a `.dot` is text, so diff
it without graphviz). Inspect that directory with `ls -a` before concluding the dump failed:
files are written per state change and an unnamed pipeline yields a dotFILE, so a plain `ls` or
a `*.dot` glob reports zero files for a dump that actually worked.

## 5. Verify the instrument before trusting either side's numbers

A comparison is only as good as its two readers. Before concluding that one implementation
"loses nothing", dump the RAW structure each side reads and check the getter that produced the
reported value:

```bash
{ printf '%s\n' "$JSON"; sleep 45; } | BLACKGATE_DUMP_STATS=1 <engine> <probe-id> 2>&1 \
  | grep -E 'STATS_STRUCT|STATS_RAW|GET_'
```

```
STATS_STRUCT application/x-srt-statistics, packets-received=(gint64)3452,
  packets-received-lost=(int)421, packets-received-retransmitted=(int)421, ...
GET_INT64  packets-received=1  packets-received-lost=0  packets-received-retransmitted=0
GET_INT    ok_lost=1 lost=421  ok_retr=1 retransmitted=421
```

- `gst_structure_get_int64` on a `(int)` field FAILS: the typed getters check the GType
  strictly, return FALSE, and leave the output variable at its initialiser. Discard that return
  value and the field reports a permanent 0 — indistinguishable from a clean link — while a
  `(gint64)` sibling read with the same call succeeds, which is what makes the zeros credible.
  Match the getter to the type in the dump (`get_int` for `(int)`, `get_uint64` for
  `(guint64)`, `get_int64` for `(gint64)`) and never ignore a getter's return value.
- In gstreamer-rs use a tolerant chain (`get::<i64>` -> `i32` -> `u32` -> `u64` -> `f64`,
  defaulting to 0) so a field whose width differs from the port's assumption still reads. That
  is why the port read the same structure correctly while the reference reported 0.
- A wrong field NAME fails identically (a sink's retransmit counter is
  `packets-retransmitted`, not `packets-sent-retransmitted`), and `gst_structure_to_string`
  shows names and types together, so one dump settles both.
- Sample it LATE (after ~30 reports, not the first one): counters legitimately read 0 in the
  first seconds, and an early dump cannot distinguish "no loss yet" from "cannot read".
- Consequence for the report: when the clean side turns out to be blind, there was never a
  performance difference — say that plainly and move the fix to the side whose reader is
  broken. Expect the corrected reader to look like a regression (a dashboard that showed
  0.00% starts showing real loss); state that up front so it is not mistaken for a new fault.

## 6. Report the state honestly

Say which hypotheses were eliminated AND with what measurement, and say plainly which one is
still open. A long elimination list is a result; presenting the remaining suspect as the
cause is not. Check whether the user's visible symptom is even harmful before calling it a
regression — when the transport recovers the loss (`retrans` ≈ `lost`) the delivered stream
is intact and only the badge/percentage moves.

## 7. Automate the comparison

A repo harness that runs both engines over fixed workloads is the repeatable form of the manual
A/B, and the only thing worth trusting for an acceptance decision. Run it in this order so a
plumbing fault costs seconds instead of hours: `--dry-run` (validates the plan and the binary
paths), then the harness's short mode on ONE workload, then the full suite with real durations
and repetitions.

- Pass both binary paths (`--c-engine` / `--rust-engine`). When both engines already build on
  the host, the container image the harness ships with is not required.
- Write results to a scratch directory OUTSIDE the repo so a run cannot dirty the working tree.
- **The harness binds and UNLINKS the control plane's stats socket** to collect the engines it
  spawns, so running it on a host with a live release removes that release's socket path and
  every route it later starts dies on `connect: No such file or directory (os error 2)`. Stop
  the release (or point the harness at its own path and pass that path to the engines it
  spawns) before a suite run, and never treat a harness as read-only just because it only
  "measures". Its own results stay valid — it was self-consistent — but it leaves the host
  broken behind it. Fix it in two layers, because either alone is insufficient: (a) refuse to
  bind a path that already answers a connect, and (b) release only what you acquired — the
  cleanup path of a FAILED acquire must not unlink the shared file, or the guard fires and the
  socket still vanishes. Point the port at its own path through the env var the engine actually
  READS (grep the engine for the name: a harness exporting an unread variable silently keeps
  the hardcoded default, which is what forced the shared bind), and leave the reference on the
  default path when its `main()` hardcodes it. Acceptance test, run with the release UP: the
  harness fails fast with a clear message, the socket file's mtime is unchanged, and a bare
  connect still succeeds.
- Read the runner's exit code as a GATE result, not a crash: a non-zero exit with a complete
  report means at least one metric or variance gate failed. Results land in a TIMESTAMPED
  subdirectory of `--output`, so a missing `summary.json` at the output root means you looked
  one level too high, not that the run produced nothing. `--all` skips the long soak workload;
  that one is a separate, later run.
- Run it on a QUIET host: live routes and their engines compete for CPU and inflate the variance
  the contract measures.
- Medians all passing while the variance contract fails is the normal outcome on a VM or a
  loaded host. That is `INCONCLUSIVE`, not a regression — say so and re-run on bare metal
  instead of reporting the medians as a verdict.
- Report the metric tally BESIDE the workload tally. An overall `fail` with zero failed metrics
  (measured: 42 metrics, 42 pass, 0 fail, yet 1 workload `pass` and 5 `inconclusive`) is a
  statement about stability, not performance — give both counts and the gate each number
  passed, or "the suite failed" misrepresents a green comparison.
- Read a variance flag by ABSOLUTE magnitude and by SIDE before calling it instability. Two
  shapes are artifacts, not defects: a metric whose mean sits near the measurement floor
  (`latency_ms` of 0.015-0.058 ms turns a ±7 µs wobble into a 13-17% CV), and a baseline whose
  own CPU/RSS drifts run to run (5 of 7 flags in one suite were the REFERENCE's numbers — the
  heavier side is the one memory pressure moves). Quote the absolute spread next to the CV and
  name which side tripped.
- Never tune a gate so a run passes. When a gate is meaningless for a metric (a CV on a
  near-floor quantity), propose the gate change as its own clearly-labelled decision — state
  that it changes the gate and not the measurements — and leave the recorded run status alone.
- While a suite runs, answer progress questions with counts, not adjectives: runs completed of
  the total, elapsed time, and an ETA derived from the observed per-workload rate.
- A gate that compares against the reference inherits the reference's instrument bugs. A
  "packet-loss delta <= 0" gate measured against a reader that always reports 0 can never pass
  on an input that genuinely loses packets, so the port gets flagged for reporting the truth.
  Run section 5's instrument check against the baseline of EVERY gate before believing a FAIL.
