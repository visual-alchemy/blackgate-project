# Rust Migration Status

Status: `IN_PROGRESS`

Target repository endpoint: `SDI_MANUAL_PENDING`  
Required platform: Ubuntu 24.04 LTS amd64  
Production engine: Rust `blackgate-engine` only

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
| Runtime boundary | `scripts/check_rust_only_runtime.sh` | Implemented; final rerun pending |
| Toolchain | `scripts/check_toolchain_contract.sh` | Implemented; final rerun pending |
| Rust quality | rustfmt, Clippy, workspace tests | Implemented; final rerun pending |
| IPC lifecycle | `native/rust/scripts/ipc_smoke.py` | Implemented; final rerun pending |
| Khepri/backend | `mix compile --warnings-as-errors`, `mix test` | Implemented; final rerun pending |
| Frontend | `npm --prefix web_app run build` | Implemented; final rerun pending |
| Ubuntu runtime | Noble Docker build plus release inspection | Pending final image build |
| Performance | `benchmarks/migration/results/REPORT.md` | Pending benchmark run |
| ISO | Noble workflow and shell/contract checks | Implemented; full ISO delegated to Linux CI |
| Physical SDI | `SDI_MANUAL_SIGNOFF.md` | Manual pending |

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

1. Run full automated verification from current `rust-migration` commit.
2. Build/inspect Ubuntu 24.04 runtime and benchmark images.
3. Run benchmark workloads and commit machine/human-readable evidence.
4. Set status to `SDI_MANUAL_PENDING` only if every automated gate passes.
5. Operator performs and signs physical SDI checklist.
