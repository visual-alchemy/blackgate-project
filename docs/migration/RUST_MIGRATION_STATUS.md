# Rust Migration Status

Status: `IN_PROGRESS`

Target repository endpoint: `SDI_MANUAL_PENDING`  
Required platform: Ubuntu 24.04 LTS amd64  
Production engine: Rust `blackgate-engine` only

Last verified: 2026-08-28
Verified commit: `6cb052d3050e1d4426898214d5ec3845f41bf059`

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
| Rust quality | rustfmt, Clippy `-D warnings`, workspace tests | PASS; 27 tests |
| IPC lifecycle | `native/rust/scripts/ipc_smoke.py` | PASS; SRT benchmark shutdown also exits 0 without forced stop |
| Khepri/backend | `mix compile --warnings-as-errors`, `mix test` | PASS; 101 tests |
| Frontend | `npm --prefix web_app run build` | PASS; lint remains authorized pre-migration baseline: 110 errors, 8 warnings |
| Ubuntu runtime | production image plus release inspection | PASS; Ubuntu 24.04 amd64, image `sha256:5437f4b622ffbd3565c71cfe16c3871d47b1a8573d5060d60bda532e52c2722c` |
| Benchmark image | Noble C/Rust oracle image | PASS; linux/amd64 image `sha256:d2f0dabe7fc920a78f6bd1119c1e3dd10bde6f19e0ce410cf6a7e8334592296a` |
| Performance | `benchmarks/migration/results/dual-methodology-7/REPORT.md` | INCONCLUSIVE; all medians pass, variance fails on Apple-hosted amd64 emulation |
| Non-SDI soak | `non-sdi-soak.json` | DEFERRED; full workload suite must pass first |
| ISO | Noble workflow and shell/contract checks | PASS locally; full ISO build remains Linux CI validation |
| Physical SDI | `SDI_MANUAL_SIGNOFF.md` | Manual pending after automated gates pass |

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

1. Run the six-workload suite on a native Ubuntu 24.04 amd64 host. Current
   Apple-hosted amd64 emulation produced coefficient-of-variation values from
   8.9% to 77.9%, above the 5% contract, even after seven repetitions.
2. Confirm every workload is `pass`, then run the one-hour-per-engine non-SDI
   soak. Do not override an inconclusive decision.
3. Set status to `SDI_MANUAL_PENDING` only when full performance and soak
   evidence pass.
4. Operator performs and signs the physical DeckLink/SDI checklist.

## Latest performance evidence

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
