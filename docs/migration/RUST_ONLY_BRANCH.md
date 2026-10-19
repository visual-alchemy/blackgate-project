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
- **The two load-bearing crates had almost no tests.** `engine-gst` had 1 and
  `blackgate-engine` 0, while the branch changed preview gating and queue bounds. Both now have
  unit tests for exactly those behaviours (`preview_requested`, `make_queue2` bounds,
  `parse_command`), so a regression fails `cargo test` instead of surfacing as a stuck route.

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
