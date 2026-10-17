# Blackgate SRT gateway — engine route diagnostics

Concrete commands for the class-level rules in SKILL.md. Engine: Rust workspace at
`native/rust/`, built by `make -C native` to `native/build/blackgate-engine`. The Elixir
control plane spawns it as an Erlang Port (argv `<engine> <route_id>`), writes the init
JSON to stdin, and receives stats back over `/tmp/hydra_unix_sock`.

## Logs

- Release log, rotating: `_build/prod/rel/blackgate/tmp/log/erlang.log.N` — newest is
  `.1`. Engine output arrives prefixed `RouteHandler: pipeline:`.
- The control plane echoes the config it received (`Received JSON: {...}`) — copy that
  line verbatim for a standalone repro.
- Old rows survive restarts, so count occurrences (`grep -ac`) rather than reading the
  tail when judging whether a failure still happens — and bound that count to the restart
  timestamp (grep the `HH:MM:SS` prefix across EVERY rotated file) when you are declaring a
  restart clean: a whole-history count carries pre-restart failures into the verdict, so a
  non-zero total after a healthy restart is expected, not a finding.

## Live state (release running)

```bash
export RELEASE_COOKIE=blackgate_production_cookie   # matches `make start`
BIN=_build/prod/rel/blackgate/bin/blackgate

$BIN rpc 'IO.puts(inspect(Blackgate.Db.get_all_routes(true)))'
$BIN rpc 'IO.puts(inspect(Blackgate.RouteStatsRegistry.get_stats("<route_id>")))'
$BIN rpc 'IO.puts(inspect(Blackgate.RouteStatsRegistry.get_all_sink_stats("<route_id>")))'
$BIN rpc 'IO.puts(inspect(Blackgate.stop_route("<route_id>")))'
$BIN rpc 'IO.puts(inspect(Blackgate.start_route("<route_id>")))'
```

Always wrap the result in `IO.puts(inspect(...))`: a bare expression evaluates silently and
prints nothing, so a blank screen means "the IO call is missing", not "no data". Values
come back wrapped and string-keyed: `get_all_routes/1` yields
`{:ok, [%{"name" => ..., "status" => ...}]}` (address with `&1["name"]`; an atom key
raises `KeyError`) and `get_stats/1` yields `%{stats: ..., updated_at: ...}`, so read
`[:stats]` before asking for a telemetry key.

Routes do not auto-start on boot: after a restart the stored `status` is stale, so check
`ps` for the engine before believing it.

## Standalone repro

```bash
printf '%s\n' '<init-json-from-log>' | timeout 8 ./native/build/blackgate-engine <route-id>
```

The engine still connects to `/tmp/hydra_unix_sock`; with the app running it shows up in
that log as an unknown `route_id`, which is harmless.

## Deploy a rebuilt engine into a running release

The release bundles the engine at
`_build/prod/rel/blackgate/lib/blackgate-<vsn>/priv/native/build/blackgate-engine`.
Copying over it while a route runs fails with `Text file busy`:

```bash
$BIN rpc 'Blackgate.stop_route("<route_id>")'      # then confirm no engine in `ps`
cp native/build/blackgate-engine <release>/lib/blackgate-<vsn>/priv/native/build/blackgate-engine
$BIN rpc 'Blackgate.start_route("<route_id>")'
```

`make build` DOES compile the engine: its `mix release` step runs `mix.exs copy_native/1`,
which shells out to `make -C native` and copies `native/build/rust/release/blackgate-engine`
into the release priv (it raises when that binary is missing). What it does not do is restart
anything — a running app keeps executing the previous engine until its routes restart, so a
deployed fix can look absent. Prove the artifact with `md5sum <release copy>
native/build/blackgate-engine` (must match) plus `grep -ac '<marker unique to the new code>'
<release copy>` (non-zero; on a binary that is a presence check, not a count), then restart
the routes before measuring. A matching md5 proves only that both copies are the same build;
to show the deployed engine matches the CURRENT code, confirm no Rust source is newer than
it: `find native/rust -name '*.rs' -newer <release copy>` must print nothing.

The restart itself can silently no-op: `make build` WIPES `_build/prod/rel/blackgate` while
the app keeps running from the deleted files, so `bin/blackgate stop` can no longer reach
that node (its pid file went with the directory) and the OLD engine keeps serving. Every
measurement then describes stale code and the trap reads exactly like "the fix did nothing"
— the md5 check above is what exposes it. `make stop` now falls back to killing surviving
release nodes by pid, and after any stop+build+start confirm the engine processes are newer
than the build before trusting a result:

```bash
ps -eo pid,lstart,cmd -C blackgate-engine   # start time must postdate `make build`
```

## Restart the release without a node-name race

`make restart` (stop then start) can fail with
`Protocol 'inet_tcp': the name blackgate@dvls seems to be in use by another Erlang node`:
the daemon starts before the old node released the name, exits, and then the old node
finishes dying — leaving nothing running, which reads later as `RPC failed with reason
:noconnection`. Stop, wait for the node to disappear, then start:

```bash
make stop
for i in $(seq 1 30); do pgrep -x beam.smp >/dev/null || break; sleep 1; done
make start
```

Probe with `pgrep -x beam.smp` (process name), never `pgrep -f 'beam.smp.*blackgate'`:
the `-f` pattern matches the command line of the shell wrapper running your own command,
so it keeps reporting the node alive after it is gone — and the same `-f` pattern passed to
`pkill` terminates that wrapper (your own shell) instead of the target. Match on the
process name, or kill explicit pids from `pgrep -x`. When you must match the command line
(probe engines all share one process name), keep the pattern from matching itself with a
character class and verify with the counting form:

```bash
pkill -f 'blackgate-engin[e] probe'      # the [e] stops pkill matching its own argv
pgrep -fc 'blackgate-engin[e] probe'     # 0 when they are gone
```

`make start` now refuses to run while a node answers (`blackgate pid`) and removes a
leftover socket file first; `make restart` waits for the old node itself. Prefer those over
hand-rolled stop/wait/start sequences.

## Stats socket pointing at a dead node (routes crash-loop, RPC still fine)

Symptom: one route runs happily while every OTHER route loops
`Pipeline exited with status 1, entering reconnect mode` every ~10 s, each attempt preceded
by `pipeline: connect: Connection refused (os error 111)` in the engine's own output. The
control plane answers RPC, `:ranch.get_status(:hydra_unix_sock)` says `:running`, and the
socket file exists — the live listener's socket was unlinked out from under it, so the path
resolves to a dead socket: only NEW connections fail, while the connection made at boot keeps
streaming. Culprits, in order of how often they bite: a `mix test` run (it boots the app
in-process and binds the same hardcoded path), the IPC smoke harness, and a second release
node that raced the first at boot. The socket file's mtime names the culprit — it matches the
clobbering run, not the node's boot time:

```bash
ls -la --time-style=+%H:%M:%S /tmp/hydra_unix_sock   # vs ps -eo lstart,cmd -C beam.smp
```

Confirm it independently of the app (a bare connect, not a GStreamer session):

```bash
python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.connect('/tmp/hydra_unix_sock')"
# [Errno 111] Connection refused -> the path is stale; CONNECT OK -> look elsewhere
```

Fix by removing every node and the stale path, then starting clean:

```bash
for p in $(pgrep -x beam.smp); do kill "$p"; done   # then confirm none remain
rm -f /tmp/hydra_unix_sock
make start
# routes do not auto-start: start each one with start_route/1
```

The durable fix is a configurable path, so a dev or test instance can never bind the
release's socket: `Blackgate.stats_socket_path/0` (config `:blackgate, :stats_socket_path`,
overridable with `BLACKGATE_STATS_SOCKET`) is what the Ranch listener binds AND what the
release puts into each engine port's `env`; the engine reads `BLACKGATE_STATS_SOCKET`
(default `/tmp/hydra_unix_sock`) and prints the path it failed to reach; `config/test.exs`
binds `/tmp/blackgate_stats_<os pid>.sock`, `config/dev.exs` binds
`/tmp/blackgate_stats_dev.sock`, and a regression test asserts the test path is never the
production one. Without that test the next `mix test` re-creates the outage.

Read the effective path per environment without booting anything, to confirm the
environments really are separated:

```bash
for env in dev test prod; do printf '%-5s -> ' "$env"; \
  API_AUTH_USERNAME=x API_AUTH_PASSWORD=x MIX_ENV=$env mix run --no-start \
  -e 'IO.puts(Application.get_env(:blackgate, :stats_socket_path))'; done
```

`runtime.exs` raises when `API_AUTH_USERNAME` is unset outside test, so a cross-env `mix run`
without it dies before the app starts — a missing env var, not a socket problem. `--no-start`
skips the boot when you only want the configured value.

Belt and braces, because a hand-started node with a DIFFERENT name never hits the node-name
race: `Blackgate.Application.assert_stats_socket_free!/1` probes the path with
`:gen_tcp.connect({:local, path}, 0, [:binary], 200)` before Ranch binds it and raises with
the path and the remedy when a live listener answers. A leftover file with no listener must
still be accepted (Ranch unlinks it when binding), so probe by CONNECTING, never by
`File.exists?`.

Acceptance test for the whole class — re-run the former clobberer against the live node and
assert the RESOURCE, not just the symptom:

```bash
stat -c %Y /tmp/hydra_unix_sock                 # before
mix test                                        # the run that used to break it
stat -c %Y /tmp/hydra_unix_sock                 # same mtime => the listener was untouched
python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.connect('/tmp/hydra_unix_sock'); print('OK')"
$BIN rpc 'IO.puts(inspect(Blackgate.stop_route("<route_id>")))'; sleep 4
$BIN rpc 'IO.puts(inspect(Blackgate.start_route("<route_id>")))'
grep -ho 'Connection refused' _build/prod/rel/blackgate/tmp/log/erlang.log.* | wc -l  # must not grow
```

Rule the source out before investigating the route's config — it takes one command, and a
healthy source answers with program/stream info even while the engine cannot connect:

```bash
ffprobe -hide_banner -show_streams -show_programs -of compact \
  'srt://<host>:<port>?mode=caller&latency=2000'          # add the route's passphrase/pbkeylen if it has one
```

`decode_slice_header error` / `non-existing PPS 0 referenced` in that output is expected on a
mid-GOP join (no parameter sets yet) — it is not a source fault.

## Stats keys that matter

- `bytes-received` (source) — the control plane's "is data flowing?" fallback
  (`route_connected?/1` in `route_controller.ex`).
- `total-bytes-received` (source) — read by the route watchdog
  (`get_total_bytes_received/1` in `route_handler.ex`); stuck at 0 causes false stall
  restarts of a healthy route.
- `packets-received` / `-lost` / `-retransmitted`, `rtt-ms`, `receive-rate-mbps`,
  `bandwidth-mbps`, `negotiated-latency-ms` — from the srtsrc `stats` GstStructure.
- Sink side: `bytes-sent-total`, `packets-sent*`, `send-rate-mbps`, `connected-callers`.
- Video metadata (source slot, present only once the TS probe parsed PAT + PMT + SPS):
  `video-width`, `video-height`, `video-framerate-num`/`-den`, `video-framerate-inferred`
  (true = the SPS carried no timing info, so the rate is the reference's 25/1 default and
  the UI prefixes it with `~`), `video-interlace-mode`, `video-codec`, `video-profile`,
  `video-level-idc`, `video-chroma-format`, `video-bit-depth`, `video-sar-num`/`-den`,
  `video-pid`, `audio-pids`. All of them are ABSENT (not zero) when the probe fails, which
  is why a dashboard shows N/A — the parser and its failure modes are in
  `references/mpegts-psi-parsing.md`.

Wire keys ≠ struct fields: srtsrc's structure field is `bytes-received-total` while the
emitted JSON key is `total-bytes-received`; the sink's is `bytes-sent-total` on both
sides. `srtsink`'s `bytes-received` is its own inbound count, not the source's.

## Judging SRT loss on a supposedly local link

A route can sit at `warning` with RTT under 1 ms: the trigger is the loss ratio, not the
path. Read the counters as a delta, never as absolutes:

```bash
# one rpc call: sample twice, subtract
$BIN rpc 'f = fn id -> s = (Blackgate.RouteStatsRegistry.get_stats(id) || %{})[:stats] || %{}; {s["packets-received"] || 0, s["packets-received-lost"] || 0, s["packets-received-dropped"] || 0} end; a = f.("<route_id>"); Process.sleep(20000); b = f.("<route_id>"); IO.inspect({a, b})'
```

- A NEGATIVE delta means the srtsrc counters reset inside the window, i.e. the source
  connection reconnected — look for `pipeline: SOURCE_INVALID` in the log. Do not read it as
  "the counter is per-report".
- `packets-received-lost` is what the receiver detected as missing (SRT recovers most of it:
  compare `packets-received-retransmitted`); `packets-received-dropped` is what the receiver
  itself discarded, so a growing `-dropped` points at the local receive buffer rather than
  the path.
- The thresholds live in `route_health.ex` (loss >= 2% or RTT >= 300 ms -> `warning`;
  10% / 500 ms -> `critical`). The UI tooltip is a separate copy and drifts — it claimed
  150 ms while the code used 300.
- Judge the ratio on a WINDOW, not on the lifetime counters. `lost/(received+lost)` keeps
  the startup burst in the ratio until the connection ends: a route measured 3.18%
  cumulative while its 20 s windows ran at 0.30-0.70%, so the badge stayed `warning` for
  hours after the link settled. `RouteStatsRegistry` publishes `loss-window-pct` (delta
  against the previous report, like the existing `drops_per_sec`) and `route_health`
  prefers it, falling back to the cumulative ratio only until a window exists. When
  reporting a loss fix, quote per-window deltas — cumulative percentages hide the fix.
- Check the host's UDP socket buffers before blaming the link
  (`sysctl net.core.rmem_max net.core.wmem_max`): they cap what libsrt may request, AGENTS.md
  carries the required values, and the source appliance needs the same on its sender side.

## Reporting

- Keep the original technical vocabulary; do not translate jargon (the user pushed back on
  "cabang" for "branch"). Findings are expected as fixes with measured before/after numbers,
  not as a plan.
- Any step that needs sudo comes back as a copy-pasteable command for the user to run (sudo
  is password-gated on the dev host), followed by a re-measurement once they report it done.
- "Will this happen again if I add another route?" is answered in three parts, in this order:
  the direct verdict, the mechanism that now makes the failure impossible plus the test or
  command that enforces it, and the causes that are NOT code and can still produce the same
  visible symptom (a lossy source, a wrong URI or passphrase, a stopped sender). Name the
  residue explicitly — it is what stops the next report from being a regression hunt.

An idle destination listener (`bytes-sent-total: 0`, `connected-callers: 0`) means no
consumer is pulling the output yet — not a pipeline fault. Confirm the port is bound
with `ss -lunp | grep <port>`.
