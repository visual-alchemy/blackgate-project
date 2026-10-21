# Rust Migration Status

Status: `IN_PROGRESS`

Target repository endpoint: `SDI_MANUAL_PENDING`  
Required platform: Ubuntu 24.04 LTS amd64  
Production engine: Rust `blackgate-engine` only

Last verified: 2026-10-20 (bare-metal Ubuntu 24.04.5 amd64, i7-4770, 15 GiB RAM)
Verified commit: `7deebf3c219d08f0fc63c47edc3cd692c92d1d39` plus the benchmark-harness change
described under "Bare-metal evidence run" below

## State definitions

- `IN_PROGRESS`: one or more required automated checks or evidence sets missing,
  failed, or inconclusive.
- `AUTOMATED_COMPLETE`: functional, release, Ubuntu 24.04, documentation, and
  no-regression performance gates all pass.
- `SDI_MANUAL_PENDING`: automated completion holds; physical DeckLink checklist
  is sole remaining gate. This is expected local repository endpoint.
- `PRODUCTION_COMPLETE`: signed physical SDI checklist passes on target gateway.

State transitions are monotonic only while supporting evidence remains valid.
Any failed/inconclusive rerun returns status to `IN_PROGRESS`.

## Automated evidence map

| Gate | Evidence / command | Current state |
| --- | --- | --- |
| Runtime boundary | guard unit tests, repository guard, release guard | PASS; production release contains only `blackgate-engine` |
| Toolchain | `scripts/check_toolchain_contract.sh` plus unit test | PASS; Rust 1.96.0, Elixir 1.18.2, OTP 27.0.1 |
| Rust quality | rustfmt, Clippy `-D warnings`, workspace tests | PASS; 45 tests (bare metal 2026-10-20) |
| IPC lifecycle | `native/rust/scripts/ipc_smoke.py` | PASS; private stats socket per run; SRT benchmark shutdown also exits 0 without forced stop |
| Khepri/backend | `mix compile --warnings-as-errors`, `mix test` | PASS; 121 tests (bare metal 2026-10-20) |
| Frontend | `npm --prefix web_app run build` | PASS; lint remains authorized pre-migration baseline: 110 errors, 8 warnings |
| Ubuntu runtime | production image plus release inspection | PASS; Ubuntu 24.04 amd64, image `sha256:5437f4b622ffbd3565c71cfe16c3871d47b1a8573d5060d60bda532e52c2722c` |
| Benchmark image | Noble C/Rust oracle image | PASS; linux/amd64 image `sha256:d2f0dabe7fc920a78f6bd1119c1e3dd10bde6f19e0ce410cf6a7e8334592296a` |
| Performance | `benchmarks/migration/results/baremetal-2026-10-20-fixed/20261020T154359Z/REPORT.md` | PARTIAL PASS on bare-metal amd64; 42/42 metrics pass, 4/6 workloads `pass`, 2 `inconclusive` on identified non-Rust causes (see below) |
| Non-SDI soak | `non-sdi-soak.json` | DEFERRED; full workload suite must pass first |
| ISO | Noble workflow and shell/contract checks | PASS locally; full ISO build remains Linux CI validation |
| Physical SDI | `SDI_MANUAL_SIGNOFF.md` | Manual pending after automated gates pass |

## Bare-metal evidence run (2026-10-20)

First C-versus-Rust comparison on the required platform: bare-metal Ubuntu 24.04.5 amd64
(Gigabyte B85M-HD3-A, i7-4770, 15 GiB RAM, `systemd-detect-virt` = none), governor `performance`,
turbo disabled, `rmem_max`/`wmem_max` 16 MB, no release running.

A methodology defect was found and fixed in the harness before this run counted. The frozen C oracle
builds its thumbnail branch whenever `argv[1]` is non-empty (`gst_pipeline.c:884`) and has no
`preview` key at all, while the Rust engine builds its preview only for `"preview": true` — so every
earlier comparison ran C-with-thumbnail against Rust-without. Measured on this host, that branch
costs 50.7 MB RSS and ~2 CPU-% (21.5 MB / 6.0 % without it, 72.2 MB / 8.0 % with it) and its internal
state varied between runs. `benchmarks/migration/scripts/run_benchmark.py` now blanks the C's
route-id argument for workloads that do not set `"thumbnail": true`, sends `"preview": true` to the
Rust engine for the workloads that do, and asserts the branch exists exactly when requested. Results
recorded before this change (`dual-methodology-7`, `verdict-2026-10-17-local-vm`,
`baremetal-2026-10-20`) are not comparable with results after it.

Result: 42 of 42 metrics inside their gates, 0 metric failures; 4 of 6 workloads `pass`. The two
remaining are `inconclusive` for causes that are not Rust regressions and that no number of
repetitions removes:

| Workload | Cause |
| --- | --- |
| `udp-to-srt` | Rust `latency_ms` CV 0.156 on samples [0.0100, 0.0145, 0.0115] ms — a ~12 µs mean, i.e. measurement quantization, not jitter. Rust's latency is 0.261x the C's on that metric. |
| `srt-thumbnail` | The frozen C oracle's own thumbnail branch is nondeterministic: C RSS 68.9 / 39.2 / 72.4 MB (one run never allocated its decoder pool) while Rust held 71.9 / 72.3 / 72.2 MB. |

Engine parity wherever the pipelines are equivalent: throughput ratio 1.0000-1.0007, CPU 0.995-1.040,
peak RSS 0.938-1.049, latency 0.261-1.012, startup 0.9997-1.0001, failover gap 0.998-1.002,
packet-loss delta 0 on all six workloads. A route with a preview costs ~72 MB on both engines.

## No-regression policy

Comparison uses medians across repeated runs and rejects unstable samples.
Thresholds come only from `benchmarks/migration/thresholds.json`. Missing data,
excessive variation, engine crash, invalid lifecycle, packet-loss regression,
or threshold breach cannot be recorded as pass.

## Historical boundary

Legacy C implementation is immutable benchmark-only oracle at
`native/archive/c-engine/`. Manifest verification is mandatory. No production
build, release, compose, ISO, Elixir, or Makefile path may invoke it.

## Remaining work

1. Two workloads remain `inconclusive` for causes outside the Rust engine
   (`udp-to-srt`: `latency_ms` quantization on a ~12 µs value; `srt-thumbnail`:
   the frozen oracle's own nondeterministic thumbnail branch). Closing these
   needs a decision rather than another repetition — either a harness rule for
   sub-millisecond CV plus a versioned oracle with an explicit preview flag, or
   recording both as accepted, explained variance.
2. Run the one-hour-per-engine non-SDI soak (`non-sdi-soak.json`) on this host.
   It uses one repetition per engine, so the CV rule does not apply to it.
3. Set status to `SDI_MANUAL_PENDING` only when the performance and soak
   evidence are recorded and the two causes above are resolved or explicitly
   accepted.
4. Operator performs and signs the physical DeckLink/SDI checklist. The target
   card is present on this host (DeckLink Duo 2 at `01:00.0`), but Blackmagic
   Desktop Video is not installed and no `/dev/blackmagic/io*` exists yet.

## Historical performance evidence (pre-methodology-fix, not comparable)

Seven interleaved repetitions of `dual-ingest-failover` used a three-second
preflight, 30-second warm-up, and 120-second measurement per engine. Every
median no-regression threshold passed:

| Metric | Result | Gate |
| --- | ---: | ---: |
| Throughput ratio | 0.999852 | >= 0.99 |
| Packet-loss delta | 0.0 | <= 0.0 |
| CPU ratio | 0.971091 | <= 1.10 |
| Peak RSS ratio | 1.006059 | <= 1.15 |
| Latency ratio | 1.035714 | <= 1.10 |
| Startup ratio | 1.063382 | <= 1.10 |
| Failover-gap ratio | 0.973023 | <= 1.10 |

Decision remains `INCONCLUSIVE` because raw CPU, latency, and startup samples
exceed the fixed 5% variance limit. Evidence metadata identifies an Apple CPU
behind an x86_64 emulation kernel, so it cannot replace native amd64 sign-off.
