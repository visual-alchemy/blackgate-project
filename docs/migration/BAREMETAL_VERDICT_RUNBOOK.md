# Bare-metal performance verdict runbook

How to reproduce the C-vs-Rust performance verdict on a bare-metal Ubuntu 24.04 amd64
machine, and how to read the result against the baseline recorded on the local dev VM.

The migration's remaining gate is native performance evidence: `docs/migration/RUST_MIGRATION_STATUS.md`
requires the comparison to run on bare metal, not on a VM, because the stability rule
(every metric's coefficient of variation must stay <= 5%) cannot be met reliably on a
shared or memory-starved guest.

## What travels through git, and what does not

Travels with the repository (clone and you have it):

- All engine, control-plane and harness code, plus the benchmark workloads.
- The project memory: `docs/memory/01-LOGS/` (session logs) and `docs/skills/project-memory/`.
- The engine diagnostics skills: `docs/skills/gstreamer-pipeline-diagnostics/`
  (includes `scripts/probe_engine_rss.sh`) and `docs/skills/pinned-toolchain-bootstrap/`.
  To use them with an agent on the new machine, copy each directory into
  `~/.hermes/skills/software-development/`.
- The baseline verdict: `benchmarks/migration/results/verdict-2026-10-17-local-vm/`.

Does NOT travel (re-create on the new machine):

- **Route definitions** — they live in Khepri at `DATABASE_DATA_DIR`, defaulting to
  `<cwd>/khepri#<node>` (the appliance uses `/var/lib/blackgate/khepri`). Re-create the
  routes through the UI/API, or copy that directory. The PLTV source passphrase is not in
  the repo and must be typed in again.
- **`scripts/sudoers.d/blackgate-dev`** — machine-specific, intentionally not committed.
  `sudo` on the new machine will be password-gated the same way.
- **sysctl buffers** — set them on the new machine (below). The appliance's
  `iso-builder/files/blackgate-firstboot.sh` already does this persistently.

## Steps

```bash
git clone <repo> blackgate-project && cd blackgate-project
git checkout rust-migration

# 1. Toolchain + system packages. Pins OTP 27.0.1 / Elixir 1.18.2 / Node 20.19.0 /
#    Rust 1.96.0 under ~/.blackgate/toolchain and installs the GStreamer, SRT and
#    cJSON dev packages the engines need. Needs sudo.
make install

# 2. SRT receive/send buffers: without this, high-bitrate SRT drops packets.
sudo sysctl -w net.core.rmem_max=16777216 net.core.wmem_max=16777216

# 3. Build both engines. The C oracle is the archived blackgate-lite engine; `verify`
#    checks its MANIFEST.sha256 before compiling.
make -C native
make -C native/archive/c-engine verify && make -C native/archive/c-engine

# 4. The harness refuses to run against a live release's stats socket, so stop it first.
make stop

# 5. Run the full comparison (~90 minutes, 6 workloads x 3 repetitions x 2 engines).
python3 benchmarks/migration/scripts/run_benchmark.py \
  --c-engine native/archive/c-engine/build/blackgate_pipeline \
  --rust-engine native/build/blackgate-engine \
  --all --output benchmarks/migration/results/baremetal-$(date +%F)

# 6. Bring the gateway back.
make build && make start    # start now waits until the supervision tree is up
```

`--quick` runs one short repetition per workload when you only want a smoke test.
`--repetitions N` overrides the repetition count if you need tighter statistics.

## Reading the result

A workload is `pass` only when every metric is inside its gate **and** every metric's CV is
<= 5%. Metrics per workload: `throughput_ratio` (>= 0.99), `cpu_ratio`, `peak_rss_ratio`,
`latency_ratio`, `startup_ratio`, `failover_gap_ratio` (all <= 1.1), `packet_loss_delta`
(<= 0.0).

Baseline from the local dev VM (`verdict-2026-10-17-local-vm/`, KVM, 4 vCPU, 3 GB RAM):
42 metrics, 42 PASS, 0 FAIL; 1 workload `pass`, 5 `inconclusive` purely on CV. Rust used
less CPU (0.73-0.96x) and less memory (0.26-0.88x) than C everywhere; throughput matched to
0.9998-1.0001x; packet loss delta was 0. On bare metal, expect the same ratios with CVs
under 5% — that is the whole point of moving off the VM.

Two known measurement artifacts to keep in mind when reading CV failures:

- `latency_ms` sits at 0.015-0.058 ms, so a ~7 microsecond wobble reads as 13-17% CV. Rust
  is *better* than C on those workloads; the relative figure is meaningless at that scale.
- The C reference's own `cpu_percent` / `peak_rss_bytes` varied 8.7-23.8% on the 3 GB VM
  (Rust 19-30 MB vs C 67-90 MB RSS, so the C is the one under memory pressure).

## Gotchas learned the hard way

- **A live release and the harness cannot share a stats socket.** The harness refuses to
  bind a path with a live listener; do not work around it by deleting the socket.
- **`make build` now fails loudly if the release is incomplete** (no `blackgate` app under
  `_build/prod/rel/blackgate/lib`). Recovery: `MIX_ENV=prod mix compile && MIX_ENV=prod mix release --overwrite`.
- **`make start` now waits for readiness.** Starting routes before the supervision tree is
  up fails with `PartitionSupervisor` exits.
- **Benchmarks intentionally omit `"preview"`** from the init JSON, so the engine runs as a
  pure streaming engine — the same thing the C engine measures. Real routes send
  `"preview": true` (see `lib/blackgate/route_handler.ex`); the preview branch costs about
  33 MB of decoder frame pool and is written to `/tmp/blackgate_preview_<route_id>.jpg`.
- **Keep the machine quiet** during the run: no builds, no `mix test`, no other streaming.
- A standalone engine exits when its stdin reaches EOF, so a manual probe must keep stdin
  open: `{ echo "$INIT"; sleep 90; } | native/build/blackgate-engine <sock> <route_id>`.
  Give it a private stats socket and a dummy Unix listener (see
  `docs/skills/gstreamer-pipeline-diagnostics/scripts/probe_engine_rss.sh`).

## What "done" looks like

1. `summary.json` with every workload `pass` (or `inconclusive` only for reasons you can
   explain as measurement noise on a verified-quiet box).
2. The ratios above reproduced or beaten, saved under `benchmarks/migration/results/`.
3. Then the two remaining gates in `docs/migration/RUST_MIGRATION_STATUS.md`: the non-SDI
   soak and the manual physical DeckLink sign-off.
