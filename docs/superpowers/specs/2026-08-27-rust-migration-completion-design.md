# Rust Migration Completion Design

Date: 2026-08-27  
Branch scope: `rust-migration` only  
Required platform: Ubuntu 24.04 LTS amd64

## 1. Purpose

Finish Blackgate's native streaming-engine migration from C to Rust without
changing any other branch. Rust becomes the only production runtime. The final
C engine remains in this branch only as an immutable behavioral and performance
oracle.

Migration completion requires reproducible functional tests, no-regression
performance evidence, Ubuntu 24.04 build and runtime support, Rust-only release
artifacts, current documentation, and an explicit manual DeckLink/SDI sign-off
gate.

## 2. Goals

- Make `blackgate-engine` the sole production native engine.
- Preserve one frozen C engine snapshot for comparison only.
- Build and test production artifacts against Ubuntu 24.04 LTS.
- Prove Rust functional parity against frozen IPC and stats contracts.
- Prove no performance regression against the C oracle.
- Replace stale C, Ecto, React 18, Debian, Jammy, and Docker-appliance claims.
- Repair automated tests around the Khepri production path.
- Make CI detect any reintroduction of the C runtime.
- Leave physical DeckLink/SDI validation as a documented operator sign-off.

## 3. Non-goals

- No checkout, merge, rebase, rewrite, commit, or push on another branch.
- No feature work unrelated to the Rust migration.
- No remote gateway edits, builds, or restarts.
- No claim that untested future Ubuntu releases are supported.
- No automated claim of physical DeckLink compatibility without hardware proof.
- No broad refactor of the Phoenix application beyond migration blockers.

## 4. Branch and Worktree Safety

All work stays on the existing `rust-migration` branch. Existing uncommitted
changes in these files belong to the user and must be preserved:

- `lib/blackgate/application.ex`
- `lib/blackgate/db.ex`

Migration edits may touch those files only when a failing migration test proves
the need. Any such overlap must retain the user's OTP 29 and Khepri intent.

Commits stage explicit paths. Broad staging commands are forbidden. Other
branches may be inspected through immutable Git objects only when necessary;
their working trees and refs must not change.

## 5. Production Architecture

The production control and media path is:

```text
React UI
  -> Phoenix REST / WebSocket
  -> Blackgate.RouteHandler
  -> native/build/blackgate-engine
  -> Rust GStreamer pipeline
  -> Unix socket telemetry
  -> UnixSockHandler
  -> ETS / PubSub
  -> React live statistics
```

`native/Makefile`, `mix release`, Docker, ISO packaging, and runtime process
discovery must reference only `blackgate-engine`. No production artifact may
contain or launch `blackgate_pipeline` or `srt_proxy`.

## 6. Repository Layout

```text
native/
├── rust/                         # sole production engine
├── vendor/decklink-sdk/          # headers used to build GStreamer plugin
├── Makefile                      # Rust-only production build
├── build/blackgate-engine        # generated release artifact
└── archive/c-engine/             # immutable benchmark oracle
    ├── src/
    ├── include/
    ├── tests/
    ├── Makefile
    ├── MANIFEST.sha256
    └── README.md

benchmarks/migration/
├── workloads/
├── scripts/
├── Dockerfile.ubuntu-24.04
├── thresholds.json
└── results/
```

The C archive is built only by the migration benchmark harness. It is excluded
from normal compilation, release assembly, Docker runtime images, ISO runtime
payloads, and production documentation.

Before active C files are removed, the archive receives a deterministic SHA-256
manifest. Verification must prove every archived source and header matches its
active predecessor. Active `native/src`, `native/include`, `native/tests`, C
backup files, and duplicate SDK trees are removed only after that verification.

## 7. Canonical Toolchain

- Operating system: Ubuntu 24.04 LTS amd64
- Elixir: 1.18.2
- Erlang/OTP: 27.0.1
- Rust: 1.96.0, pinned by `rust-toolchain.toml`
- Node.js: 20 LTS
- GStreamer: Ubuntu Noble 1.24.x packages
- SRT: Ubuntu Noble 1.5.x packages

`.tool-versions`, Docker build stages, CI, ISO builder, documentation, and
benchmark metadata must agree on these versions. Patch-level GStreamer and SRT
updates supplied by Ubuntu 24.04 security repositories are allowed and recorded
in benchmark output.

Ubuntu 26.04 and later are outside the required support contract until their
full functional and performance matrices pass.

## 8. C Oracle Rules

The archived engine exists to answer two questions:

1. Does Rust preserve the C engine's external behavior?
2. Does Rust meet the approved no-regression performance thresholds?

The oracle is immutable after its checksum manifest is committed. Benchmark
scripts may compile and execute it, but production code cannot import, link, or
spawn it. A CI guard fails when production paths contain forbidden C binary
names or active C source references.

Changes to the C oracle require a new explicitly reviewed baseline version and
new benchmark evidence. Normal Rust work must never modify it.

## 9. Functional Verification

Automated validation includes:

- `cargo fmt --check`
- Clippy across the Rust workspace with warnings denied
- `cargo test --workspace`
- Rust release build on Ubuntu 24.04
- Elixir formatting and warnings-as-errors compilation
- Focused production-path Elixir tests
- Full Elixir suite after stale Ecto scaffolding is removed and equivalent
  Khepri tests are added
- React lint and production build
- IPC initialization and command contract tests
- Stats JSON schema and key-order compatibility tests
- Multi-sink configuration and telemetry tests
- Dual-ingest source switch, join, leave, and failure tests
- Thumbnail generation smoke test
- Release-content inspection
- Docker/ISO runtime smoke checks

Ecto/SQLite CRUD modules, fixtures, aliases, and sandbox tests that no longer
exercise production behavior are removed. Khepri remains the sole production
persistence path and receives equivalent CRUD/controller coverage.

## 10. Performance Workloads

Both engines run sequentially inside the same Ubuntu 24.04 environment with the
same media, ports, GStreamer packages, SRT properties, resource limits, and
measurement tools.

Required workloads:

1. SRT to SRT, 1080p25, 5 Mbps.
2. SRT to SRT, 1080p50, 25 Mbps.
3. SRT input to three destinations: one SRT caller, one SRT listener, and one
   UDP sink.
4. UDP input to SRT output.
5. Dual-ingest SRT failover and switchback.
6. SRT route with thumbnail branch enabled.
7. One-hour non-SDI stability soak.

Each measured workload uses:

- 30-second warm-up.
- 120-second measurement window.
- Three repetitions per engine.
- Alternating C-first and Rust-first ordering.
- Median result for the decision.
- Additional repetitions when coefficient of variation exceeds 5%.

Results with more than 5% variation remain inconclusive until stable evidence
exists. Inconclusive never counts as pass.

CPU and peak RSS come from cgroup and `/proc` samples for the engine process.
Throughput and packet loss come from matched sender, engine, and receiver SRT
statistics. Steady forwarding latency comes from matching MPEG-TS PCR/PTS values
between timestamped ingress and egress captures. Startup time runs from process
spawn to the first valid output transport-stream packet. Failover interruption
is the largest gap between consecutive valid output packet timestamps during a
forced source switch.

## 11. No-regression Gates

| Metric | Rust requirement |
|---|---|
| Throughput | At least 99% of C |
| Packet loss | No higher than C; zero expected locally |
| CPU | At most 110% of C |
| Peak RSS | At most 115% of C |
| Steady forwarding latency | At most 110% of C |
| Startup to first output | At most 110% of C |
| Failover interruption | At most 110% of C |

The harness produces one JSON record per run, a summarized JSON decision file,
a Markdown report, raw engine logs, toolchain versions, image digest, host CPU,
kernel, and workload configuration.

A failed workload blocks automated migration completion. A benchmark tool
failure is reported separately from an engine regression and includes enough
diagnostics for reproduction.

## 12. CI Design

### Functional workflow

Runs on pushes to `rust-migration`, pull requests targeting `rust-migration`,
and manual dispatch using Ubuntu 24.04. It performs formatting, Clippy, Rust
tests, Elixir tests, frontend lint/build, release assembly, content inspection,
and a short runtime smoke test.

### Performance workflow

Runs through manual dispatch and a schedule. Shared runners can be noisy, so
their performance results are evidence and regression alerts, not ordinary PR
gates. The authoritative no-regression report is produced on a stable Ubuntu
24.04 host using the same harness and stored with machine metadata.

### ISO workflow

Builds from Ubuntu 24.04 Noble media, packages the actual bare-metal OTP
release, and publishes accurate release notes. Jammy and Docker-appliance claims
are removed.

## 13. Documentation Cleanup

The following documentation families must describe current reality:

- Root `README.md` and `AGENTS.md`
- `native/README.md` and `native/AGENTS.md`
- `lib/AGENTS.md`
- `web_app/AGENTS.md`
- `iso-builder/README.md` and `iso-builder/AGENTS.md`
- Architecture and technical-analysis documents
- User guide, troubleshooting guide, and failover runbook
- Migration status and performance report

Required terminology is Rust engine, React 19, Khepri, Ubuntu 24.04, and
bare-metal OTP release. Historical documents may retain C references only when
clearly labeled historical or archived.

## 14. Failure Handling

- Missing dependencies stop setup with exact package and command guidance.
- C oracle checksum mismatch stops archive cleanup.
- Contract mismatch reports the differing field, value, and raw message.
- Functional test failure blocks release assembly.
- Performance failure names workload, metric, threshold, C value, Rust value,
  and deviation.
- Excessive measurement variance triggers more runs and remains inconclusive.
- Missing DeckLink hardware never produces an automated SDI pass.
- Release inspection fails if a C binary or forbidden production reference is
  found.

## 15. Completion States

### `AUTOMATED_COMPLETE`

All functional checks, release checks, Ubuntu 24.04 smoke tests, and no-regression
benchmarks pass. Documentation and repository cleanup are complete.

### `SDI_MANUAL_PENDING`

Automated completion holds, but physical DeckLink validation is not yet signed.
This is the expected local-repository endpoint.

### `PRODUCTION_COMPLETE`

An operator records successful DeckLink video, eight-channel audio, mode
auto-detection, failover behavior, audio-silence recovery, and one-hour hardware
stability on the gateway.

## 16. Acceptance Criteria

- Only Rust engine is reachable from production build and runtime paths.
- Frozen C oracle is checksum-verified and benchmark-only.
- Ubuntu 24.04 LTS is the documented and tested required platform.
- Canonical toolchain versions agree across configuration and docs.
- All functional checks pass from a clean checkout.
- All required performance workloads meet no-regression gates.
- Full machine-readable and human-readable benchmark evidence exists.
- Active C sources, duplicate SDK files, backup files, and stale build paths are
  absent.
- Khepri tests replace stale Ecto production scaffolding.
- CI and ISO workflows match actual deployment behavior.
- Documentation contains no unlabeled active-runtime C claims.
- Migration status is `SDI_MANUAL_PENDING` until physical sign-off is recorded.
