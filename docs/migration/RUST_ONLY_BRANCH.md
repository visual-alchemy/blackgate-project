# The Rust-only branch

This file exists because `rust-migration` is not "another Blackgate branch": it is the branch
where the media engine is Rust and nothing else runs the stream. Read this before assuming
behaviour, build commands or file layout from the C-era branches (`blackgate-lite`,
`feat/decklink-duo2`, `feat/decklink-quad2`, `feat/srt-failover`) apply here.

## What is different from the C-era branches

| | C-era branches | `rust-migration` (here) |
| --- | --- | --- |
| Production engine | `native/build/blackgate_pipeline` (C, ~3.2k lines under `native/src/`) | `native/build/blackgate-engine` (Rust workspace, 8 crates) |
| C engine | the product | frozen, manifest-verified benchmark oracle at `native/archive/c-engine/`, never shipped, never invoked by a production path |
| Preview/thumbnail | in-process thumbnail chain in `gst_pipeline.c` | `engine-thumbnail` branch, built only when the init config asks (`"preview": true`) |
| Stats socket | shared `/tmp/hydra_unix_sock` only | `BLACKGATE_STATS_SOCKET`, per-env paths, live-listener guard, 5 s staleness marking |
| Control plane / UI | Elixir + React (unchanged) | Elixir + React (unchanged — the migration is engine-scoped by design) |

## What enforces the boundary

Run these before pushing; they are the reason a C reference cannot creep back in:

```bash
bash scripts/check_rust_only_runtime.sh --root .          # no production path to the C engine
bash scripts/check_rust_only_runtime.sh --root . --release _build/prod/rel/blackgate
bash scripts/check_toolchain_contract.sh                  # Elixir/Erlang/Node/Rust pins
make -C native/archive/c-engine verify                    # oracle integrity (MANIFEST.sha256)
```

`make -C native` builds Rust only. `native/rust/Cargo.toml` lists exactly the eight crates that
ship or are tested; migration-era binaries live under `native/rust/tools/` and are excluded from
the workspace on purpose.

## What this branch fixed, and why it matters operationally

These were found by measurement, not from a plan. Each one has a guard or a test behind it now.

- **A dev or test node could silently unbind the running appliance's stats socket.** `mix test`
  and a benchmark run both unlinked `/tmp/hydra_unix_sock`; the release kept its (now unlinked)
  inode while every engine it spawned died with `connect: No such file or directory` and
  crash-looped every 10 s. Now: per-environment socket paths, `BLACKGATE_STATS_SOCKET` read at
  runtime, a start-time refusal when the path already has a live listener, and a benchmark
  harness that owns its own socket and only unlinks a path it actually bound.
- **Stale stats could make a dead route look alive.** `RouteStatsRegistry.get_stats/1` now marks
  rows older than 5 s as `stale` with `health: "disconnected"`.
- **The C engine cannot report packet loss at all.** Its `build_source_stats_json` reads
  `srtsrc`'s `packets-received-lost/dropped/retransmitted` — stored as `int` (gint32) — with
  `gst_structure_get_int64`, so the type check fails, the FALSE return is ignored and the value
  stays 0 forever. A "Rust loses packets, C doesn't" report is almost always this bug: measured
  raw structures showed C 421 lost vs Rust 416 on the same source and window. Do not draw
  conclusions from a 0 from that engine, and note that `packet_loss_delta` therefore cannot
  detect a C-side regression.
- **The preview branch was the whole peak-RSS "regression".** The Rust engine built its
  thumbnail branch whenever `route_id` was non-empty, so every headless route and every
  benchmark run paid ~33 MB of H.264 decoder frame pool the C engine never allocates (it builds
  its thumbnail chain only on request). Measured with the benchmark's own init JSON: 51.9 MB
  with the branch, 19.3 MB without, C 26.1 MB. The branch now follows `"preview"`, and
  `route_handler` requests it for every real route so the dashboard preview is unchanged.
- **The sink `queue2` was never the culprit, but its bound was indefensible.** 50 MB / 3 s became
  2 MB / 0.5 s, with a compile-time assertion that it stays small. Shrinking it changed nothing
  measurable — the fix above did — but a destination that cannot keep up must not be able to
  grow tens of MB.
- **`make start` returned before the app could accept routes.** The node answers RPC while its
  supervision tree is still coming up, so routes started immediately after it died with
  `PartitionSupervisor` exits. `make start` now waits for `DynamicSupervisor` and
  `RouteStatsRegistry` and says so.
- **`make build` could leave an incomplete release** (8 apps, no `blackgate-1.0.0`) that booted
  with `load_failed` for core modules. It did not reproduce, so the cause is still unknown, but
  the build now verifies the blackgate app exists under the release's `lib/` and fails with the
  recovery command instead of deploying a broken artifact.
- **The RTMP/HTTP/HLS sidecar ran the source URL through a shell.** The URL was interpolated
  into a `Port.open({:spawn, cmd})` string — `/bin/sh` — inside double quotes, so
  `…?token=$ecret&name="quoted"` reached ffmpeg as `…?token=&name=quoted`: signed URLs broke
  silently and `$(…)`/backticks would have been executed. Now an argument list
  (`:spawn_executable` + `args`) with an ffmpeg-on-PATH preflight that names the real problem
  instead of "sidecar exited with status 127". `make install` and the appliance image both do
  install ffmpeg; the preflight is for misconfigured hosts.
- **The two load-bearing crates had almost no tests.** `engine-gst` had 1 and
  `blackgate-engine` 0, while the branch changed preview gating and queue bounds. Both now have
  unit tests for exactly those behaviours (`preview_requested`, `make_queue2` bounds,
  `parse_command`), so a regression fails `cargo test` instead of surfacing as a stuck route.

- **The IPC smoke test owned the production stats socket.** `native/rust/scripts/ipc_smoke.py`
  bound and unlinked `/tmp/hydra_unix_sock` — the path a running release listens on — and never
  passed `BLACKGATE_STATS_SOCKET` to the engine it spawns, so it *had* to. `native/AGENTS.md`
  requires running that smoke after behaviour changes, so following the docs with a release up
  broke every live route exactly the way the benchmark harness did. It now uses a private path
  per run, hands it to the child, refuses a path that already has a live listener, and unlinks
  only what it bound. Verified with the release running: the smoke passes, the release socket's
  mtime and inode are unchanged, and pointing the smoke at the live socket fails with a clear
  message instead of unlinking it.

## Rules for working here

- Never add a production reference to `native/archive/c-engine/`. The oracle is immutable and
  manifest-verified; its `verify` target must stay green.
- A feature that costs memory or CPU must be requested by the config, not inferred from an id.
- Keep the stats socket isolated: one path per environment, never bind a path with a live
  listener, never unlink a socket you did not create.
- Measure before believing a comparison against the oracle — check process boundaries and what
  the config actually asked for (see `docs/skills/gstreamer-pipeline-diagnostics/`).
- The `preview` init field is part of the engine contract: any tool that starts the engine itself
  must send `"preview": true` to get a preview, and benchmarks deliberately do not.
- Never bind a stats-socket path that might belong to a running release: pass
  `BLACKGATE_STATS_SOCKET` to every engine you spawn, use a private path per run, refuse a path
  that already has a live listener, and unlink only what you bound. Three tools got this wrong
  (the benchmark harness, the IPC smoke, and the smoke's child env) and each one crash-looped the
  live routes with `connect: No such file or directory (os error 2)`.

## Operating the gateway (notes that live in no one's memory)

```bash
make start        # returns only once the supervision tree is up, so routes can start immediately
make stop         # stops the release node and removes a stale stats socket
make restart

# Ask the running release anything (node blackgate@dvls, HTTP :4000)
RELEASE_COOKIE=blackgate_production_cookie _build/prod/rel/blackgate/bin/blackgate rpc \
  'IO.puts(inspect(Blackgate.Db.get_all_routes() |> elem(1) |> Enum.map(&{&1["name"], &1["status"]})))'

RELEASE_COOKIE=blackgate_production_cookie _build/prod/rel/blackgate/bin/blackgate rpc \
  'Blackgate.start_route("<route-id>")'   # Blackgate.stop_route/1 to stop it
```

- Logs: `_build/prod/rel/blackgate/tmp/log/erlang.log.*`, **rotated by size** — grep all of
  them, because a zero-hit grep on the newest file can be a rotation artifact.
- Stats sockets: release `/tmp/hydra_unix_sock` (or `BLACKGATE_STATS_SOCKET`), dev
  `/tmp/blackgate_stats_dev.sock`, test per-run, benchmark and IPC smoke private per run. Route
  stats older than 5 s are reported `stale: true` with `health: "disconnected"`.
- Engine stdout arrives in the release log as `RouteHandler: pipeline: …`.
- `pkill -f <pattern>` also matches the shell running it — use a bracketed pattern
  (`blackgate-engin[e]`) or pgrep + kill.
- SRT needs `net.core.rmem_max` / `wmem_max` >= 16 MB (README has the one-liner; the appliance
  sets it at first boot).
- A route whose engine builds a preview pays ~33 MB extra RSS while the preview is enabled.

## What is still open

The engine code is complete; the remaining work is evidence, from
`docs/migration/RUST_MIGRATION_STATUS.md`:

1. Six-workload performance suite on native Ubuntu 24.04 amd64, every workload `pass`
   (see `docs/migration/BAREMETAL_VERDICT_RUNBOOK.md`; the local VM run passed 42/42 metrics but
   5 of 6 workloads stayed inconclusive on the CV <= 5% stability rule).
2. The one-hour-per-engine non-SDI soak (`non-sdi-soak.json`).
3. Physical DeckLink sign-off (`docs/migration/SDI_MANUAL_SIGNOFF.md`) on the target gateway.

Open decisions and follow-ups are tracked as Task 16 in
`docs/superpowers/plans/2026-08-27-rust-migration-completion.md`, including the choice between
documenting the oracle's blind loss metric and versioning the oracle.

## Where the knowledge lives

- `docs/memory/01-LOGS/` — session history, including the measurements quoted above.
- `docs/migration/RUST_MIGRATION_STATUS.md` — the authoritative completion state.
- `docs/migration/BAREMETAL_VERDICT_RUNBOOK.md` — how to reproduce the verdict elsewhere.
- `docs/skills/project-memory/`, `docs/skills/gstreamer-pipeline-diagnostics/`,
  `docs/skills/pinned-toolchain-bootstrap/` — the agent-facing procedures and pitfalls.
