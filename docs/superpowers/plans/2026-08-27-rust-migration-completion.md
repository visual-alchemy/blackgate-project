# Rust Migration Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Rust the only Blackgate production streaming engine, prove functional and no-regression performance parity against a frozen C oracle on Ubuntu 24.04 LTS, and leave physical DeckLink validation as the only manual gate.

**Architecture:** Production builds and runtime use `native/rust` exclusively. The final C engine is checksum-frozen under `native/archive/c-engine` and can only be built by an Ubuntu 24.04 benchmark harness. Functional CI, release inspection, performance reports, and updated documentation enforce the boundary.

**Tech Stack:** Elixir 1.18.2, Erlang/OTP 27.0.1, Rust 1.96.0, GStreamer 1.24, SRT 1.5, React 19, Node 20, Ubuntu 24.04, Docker, GitHub Actions, Python 3 standard library.

---

## File Map

### Create

- `rust-toolchain.toml` — exact Rust toolchain pin.
- `scripts/check_rust_only_runtime.sh` — production-path and release-content guard.
- `test/scripts/check_rust_only_runtime_test.sh` — guard regression tests.
- `scripts/check_toolchain_contract.sh` — canonical-version consistency guard.
- `test/scripts/check_toolchain_contract_test.sh` — toolchain guard tests.
- `native/archive/c-engine/Makefile` — benchmark-only C build.
- `native/archive/c-engine/README.md` — immutable-oracle rules.
- `native/archive/c-engine/MANIFEST.sha256` — deterministic archive checksum.
- `test/blackgate/db_test.exs` — direct Khepri CRUD and nested-destination tests.
- `native/rust/scripts/ipc_smoke.py` — real Rust engine IPC/runtime smoke test.
- `benchmarks/migration/thresholds.json` — approved no-regression limits.
- `benchmarks/migration/workloads/*.json` — exact benchmark scenarios.
- `benchmarks/migration/scripts/result_model.py` — metrics, medians, variation, decisions.
- `benchmarks/migration/scripts/run_benchmark.py` — engine and workload orchestrator.
- `benchmarks/migration/scripts/render_report.py` — Markdown evidence renderer.
- `benchmarks/migration/tests/test_result_model.py` — comparator unit tests.
- `benchmarks/migration/tests/test_workloads.py` — workload contract tests.
- `benchmarks/migration/tests/test_runner_dry_run.py` — orchestrator lifecycle tests.
- `benchmarks/migration/Dockerfile.ubuntu-24.04` — identical C/Rust benchmark image.
- `benchmarks/migration/README.md` — benchmark usage and interpretation.
- `.github/workflows/rust-migration-ci.yml` — functional migration CI.
- `.github/workflows/rust-migration-performance.yml` — scheduled/manual benchmarks.
- `docs/migration/RUST_MIGRATION_STATUS.md` — evidence-driven completion state.
- `docs/migration/SDI_MANUAL_SIGNOFF.md` — physical DeckLink checklist.

### Move

- `native/archive/src` -> `native/archive/c-engine/src`.
- `native/archive/include` -> `native/archive/c-engine/include`.
- `native/tests` -> `native/archive/c-engine/tests`.
- `native/decklink-sdk` -> `native/vendor/decklink-sdk`.

### Modify

- `.tool-versions`, `.gitignore`, `Dockerfile`, `docker-compose.yml`.
- `mix.exs`, `mix.lock`, `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs`.
- `lib/blackgate/application.ex`, only to remove commented Ecto startup and preserve current Cachex/OTP changes.
- `lib/blackgate/db.ex`, only when Khepri tests expose contract defects.
- `lib/blackgate/release.ex`, `lib/blackgate_web/endpoint.ex`, `lib/blackgate_web/controllers/fallback_controller.ex`.
- `test/support/conn_case.ex`, route and destination controller tests.
- `native/Makefile`, `native/rust/Cargo.toml`, Rust workspace files touched by formatting/Clippy fixes.
- `iso-builder/build.sh`, `iso-builder/autoinstall/user-data`, ISO services and CI workflow.
- Root/subsystem AGENTS and README files plus active architecture/runbook documentation.

### Delete

- Active `native/src`, `native/include`, duplicate `native/archive/decklink-sdk`, and C backup files after checksum verification.
- `lib/blackgate/api.ex`, `lib/blackgate/api/`, `lib/blackgate/repo.ex`, `lib/blackgate/release.ex` when no release caller remains.
- `lib/blackgate_web/controllers/changeset_json.ex`, `route_json.ex`, `destination_json.ex`.
- `test/support/data_case.ex`, `test/support/fixtures/api_fixtures.ex`, `test/blackgate/api_test.exs`.
- Stale Ecto-based bodies in route/destination controller tests; files remain as Khepri tests.

---

### Task 1: Add Rust-only production guard

**Files:**
- Create: `scripts/check_rust_only_runtime.sh`
- Create: `test/scripts/check_rust_only_runtime_test.sh`

- [ ] **Step 1: Write failing guard test**

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/scripts/check_rust_only_runtime.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/lib" "$fixture/native/build"
printf '%s\n' 'spawn blackgate_pipeline' > "$fixture/lib/runtime.txt"
if "$guard" --root "$fixture"; then
  echo "guard accepted forbidden C runtime reference" >&2
  exit 1
fi

printf '%s\n' 'spawn blackgate-engine' > "$fixture/lib/runtime.txt"
touch "$fixture/native/build/blackgate-engine"
"$guard" --root "$fixture"

touch "$fixture/native/build/blackgate_pipeline"
if "$guard" --root "$fixture" --release "$fixture/native/build"; then
  echo "guard accepted forbidden C release binary" >&2
  exit 1
fi
```

- [ ] **Step 2: Run test and verify missing guard fails**

Run: `rtk bash test/scripts/check_rust_only_runtime_test.sh`  
Expected: FAIL because `scripts/check_rust_only_runtime.sh` does not exist.

- [ ] **Step 3: Implement guard**

```bash
#!/usr/bin/env bash
set -euo pipefail

root="."
release_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --release) release_dir="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

paths=()
for path in mix.exs Makefile Dockerfile docker-compose.yml lib rel iso-builder; do
  [[ -e "$root/$path" ]] && paths+=("$root/$path")
done

if [[ ${#paths[@]} -gt 0 ]] && rg -n 'blackgate_pipeline|srt_proxy|native/(src|include|tests)' "${paths[@]}"; then
  echo "forbidden C runtime reference found" >&2
  exit 1
fi

if [[ -n "$release_dir" ]] && find "$release_dir" -type f \( -name blackgate_pipeline -o -name srt_proxy \) | grep -q .; then
  echo "forbidden C binary found in release" >&2
  exit 1
fi

echo "Rust-only runtime guard passed"
```

- [ ] **Step 4: Run guard tests**

Run: `rtk bash test/scripts/check_rust_only_runtime_test.sh`  
Expected: PASS with `Rust-only runtime guard passed` for valid fixture.

- [ ] **Step 5: Commit guard**

```bash
rtk git add scripts/check_rust_only_runtime.sh test/scripts/check_rust_only_runtime_test.sh
rtk git commit -m "test(build): guard Rust-only runtime"
```

### Task 2: Freeze C oracle and remove active C tree

**Files:**
- Move: `native/archive/src`, `native/archive/include`, `native/tests`, `native/decklink-sdk`
- Create: `native/archive/c-engine/Makefile`
- Create: `native/archive/c-engine/README.md`
- Create: `native/archive/c-engine/MANIFEST.sha256`
- Modify: `Dockerfile`
- Delete: `native/src`, `native/include`, `native/archive/decklink-sdk`

- [ ] **Step 1: Verify existing copies before moving**

```bash
rtk diff -qr native/src native/archive/src
rtk diff -qr native/include native/archive/include
rtk diff -qr native/decklink-sdk native/archive/decklink-sdk
```

Expected: only `native/src/gst_pipeline.c.bak` differs; source, headers, and SDK content otherwise match.

- [ ] **Step 2: Move frozen sources and production SDK**

```bash
rtk mkdir -p native/archive/c-engine native/vendor
rtk git mv native/archive/src native/archive/c-engine/src
rtk git mv native/archive/include native/archive/c-engine/include
rtk git mv native/tests native/archive/c-engine/tests
rtk git mv native/decklink-sdk native/vendor/decklink-sdk
```

Expected: Git records moves; no other branch changes.

- [ ] **Step 3: Add benchmark-only C Makefile**

```make
CC ?= gcc
PKGS := gstreamer-1.0 gstreamer-app-1.0 gio-2.0 libcjson srt
CFLAGS ?= -O2 -g -Wall -Wextra
CFLAGS += $(shell pkg-config --cflags $(PKGS)) -Iinclude
LDLIBS += $(shell pkg-config --libs $(PKGS)) -lpthread
SRC := $(wildcard src/*.c)
OBJ := $(patsubst src/%.c,build/%.o,$(SRC))
BIN := build/blackgate_pipeline

.PHONY: all clean verify
all: $(BIN)

$(BIN): $(OBJ)
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

build/%.o: src/%.c | build
	$(CC) $(CFLAGS) -c $< -o $@

build:
	mkdir -p build

verify:
	sha256sum -c MANIFEST.sha256

clean:
	rm -rf build
```

- [ ] **Step 4: Add oracle README**

Document: immutable snapshot, benchmark-only build, Ubuntu 24.04 packages, `make verify`, `make`, no production imports, and baseline commit `b7da650^`.

- [ ] **Step 5: Generate deterministic manifest**

Run from `native/archive/c-engine`:

```bash
rtk find src include tests -type f -print0
rtk sh -c 'find src include tests -type f -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256'
rtk sha256sum -c MANIFEST.sha256
```

Expected: every archived file reports `OK`.

- [ ] **Step 6: Update DeckLink SDK production path**

Change Dockerfile copy source:

```dockerfile
COPY native/vendor/decklink-sdk /usr/include/decklink
```

- [ ] **Step 7: Remove verified duplicate active C content**

```bash
rtk git rm -r native/src native/include native/archive/decklink-sdk
```

Expected: active C tree and backup file removed; oracle and vendor SDK remain.

- [ ] **Step 8: Verify Rust-only boundary and C oracle build**

```bash
rtk bash scripts/check_rust_only_runtime.sh --root .
rtk docker run --rm -v "$PWD:/workspace" -w /workspace/native/archive/c-engine ubuntu:24.04 bash -lc 'apt-get update && apt-get install -y build-essential pkg-config libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libcjson-dev libsrt-openssl-dev && make verify && make'
```

Expected: guard passes; archive checksum passes; `build/blackgate_pipeline` exists inside container-mounted tree.

- [ ] **Step 9: Commit archive transition**

```bash
rtk git add Dockerfile native/archive/c-engine/Makefile native/archive/c-engine/README.md native/archive/c-engine/MANIFEST.sha256
rtk git add native/archive/c-engine/src native/archive/c-engine/include native/archive/c-engine/tests native/vendor/decklink-sdk
rtk git add -u native/src native/include native/tests native/decklink-sdk native/archive
rtk git commit -m "refactor(native): freeze C benchmark oracle"
```

### Task 3: Pin Ubuntu 24.04 toolchain

**Files:**
- Create: `rust-toolchain.toml`
- Create: `scripts/check_toolchain_contract.sh`
- Create: `test/scripts/check_toolchain_contract_test.sh`
- Modify: `.tool-versions`
- Modify: `Dockerfile`

- [ ] **Step 1: Write failing toolchain contract test**

Test copies repository configuration into a temporary directory, invokes the checker, expects current mismatched versions to fail, then writes canonical values and expects success.

Canonical assertions:

```text
elixir 1.18.2-otp-27
erlang 27.0.1
nodejs 20.19.0
channel = "1.96.0"
ubuntu:24.04
1.18.2-erlang-27.0.1-ubuntu-noble-20260509.1
```

- [ ] **Step 2: Run test and verify failure**

Run: `rtk bash test/scripts/check_toolchain_contract_test.sh`  
Expected: FAIL against current `.tool-versions` and Debian Docker image.

- [ ] **Step 3: Add exact toolchain files**

`.tool-versions`:

```text
elixir 1.18.2-otp-27
erlang 27.0.1
nodejs 20.19.0
```

`rust-toolchain.toml`:

```toml
[toolchain]
channel = "1.96.0"
components = ["clippy", "rustfmt"]
profile = "minimal"
```

- [ ] **Step 4: Convert Docker images and packages to Noble**

Use:

```dockerfile
ARG BUILDER_IMAGE="hexpm/elixir:1.18.2-erlang-27.0.1-ubuntu-noble-20260509.1"
ARG RUNNER_IMAGE="ubuntu:24.04"
ARG NODE_VERSION="20.19.0"
ARG GST_VERSION="1.24.2"
```

Replace NodeSource setup with pinned Node tarball installation. Replace GStreamer source tag `1.22.0` with `1.24.2`. Replace Debian-only runtime packages with Noble packages: `libncurses6`, `libssl3t64`, `libsrt1.5-gnutls`, GStreamer good/bad/libav/vaapi, `libgstreamer1.0-0`, and `libgstreamer-plugins-base1.0-0`.

- [ ] **Step 5: Implement and run contract checker**

Checker reads `.tool-versions`, `rust-toolchain.toml`, and Dockerfile with `rg -F`; any missing canonical string exits 1.

Run:

```bash
rtk bash test/scripts/check_toolchain_contract_test.sh
rtk bash scripts/check_toolchain_contract.sh
```

Expected: both PASS.

- [ ] **Step 6: Build Noble production image**

Run: `rtk docker build --progress=plain -t blackgate:rust-migration-noble .`  
Expected: exit 0; builder and runner report Ubuntu Noble packages.

- [ ] **Step 7: Commit toolchain alignment**

```bash
rtk git add .tool-versions rust-toolchain.toml Dockerfile scripts/check_toolchain_contract.sh test/scripts/check_toolchain_contract_test.sh
rtk git commit -m "build: target Ubuntu 24.04 toolchain"
```

### Task 4: Replace Ecto scaffold with Khepri coverage

**Files:**
- Create: `test/blackgate/db_test.exs`
- Modify: `test/support/conn_case.ex`
- Rewrite: `test/blackgate_web/controllers/route_controller_test.exs`
- Rewrite: `test/blackgate_web/controllers/destination_controller_test.exs`
- Modify: `mix.exs`, `config/*.exs`, endpoint, fallback controller, application comments
- Delete: stale Ecto modules and support files listed in File Map

- [ ] **Step 1: Write direct Khepri CRUD tests**

Tests use unique UUID route IDs and delete their subtree on exit. Required assertions:

```elixir
test "create_route stores destinations below route and returns hydrated route" do
  route_id = UUID.uuid4()
  destination = %{"schema" => "UDP", "schema_options" => %{"address" => "127.0.0.1", "port" => 9001}}

  assert {:ok, route} = Db.create_route(%{"name" => "Khepri route", "destinations" => [destination]}, route_id)
  assert route["id"] == route_id
  assert [%{"route_id" => ^route_id}] = route["destinations"]
  assert {:ok, stored} = :khepri.get(["routes", route_id])
  refute Map.has_key?(stored, "destinations")
end

test "update and delete route preserve Khepri contracts" do
  route_id = UUID.uuid4()
  assert {:ok, _} = Db.create_route(%{"name" => "before"}, route_id)
  assert {:ok, %{"name" => "after"}} = Db.update_route(route_id, %{"name" => "after"})
  assert [:ok, :ok] = Db.delete_route(route_id)
  assert {:error, :not_found} = Db.get_route(route_id)
end
```

- [ ] **Step 2: Run Khepri tests and capture failures**

Run: `rtk mix test test/blackgate/db_test.exs`  
Expected: at least missing-route contract fails because `get_route/2` currently calls `:khepri.get!/1`.

- [ ] **Step 3: Make minimal Db contract fixes**

Change `get_route/2` and `get_destination/2` to return `{:error, :not_found}` instead of raising. Preserve current nested-destination creation and non-transactional OTP 29 changes. Propagate destination-creation failures from `create_route/2` and delete partially created route data before returning the error.

- [ ] **Step 4: Remove SQL sandbox from ConnCase**

`ConnCase` setup creates a unique bearer token in Cachex, places it in the request header, and deletes it on exit. It does not call `DataCase`.

- [ ] **Step 5: Rewrite controller CRUD tests around Khepri**

Route tests exercise authenticated index/create/show/update/delete with map payloads and unique IDs. Destination tests use nested routes `/api/routes/:route_id/destinations/:dest_id`, assert route restart metadata, and clean Khepri paths on exit.

- [ ] **Step 6: Run rewritten tests before deleting Ecto**

Run:

```bash
rtk mix test test/blackgate/db_test.exs test/blackgate_web/controllers/route_controller_test.exs test/blackgate_web/controllers/destination_controller_test.exs
```

Expected: PASS with zero Ecto sandbox startup.

- [ ] **Step 7: Remove Ecto code and configuration**

Remove `phoenix_ecto`, `ecto_sql`, `ecto_sqlite3`; replace Mix aliases with direct `deps.get` and `test`; remove `ecto_repos`; remove dev/test Repo config; remove endpoint `Phoenix.Ecto.CheckRepoStatus`; remove Ecto fallback clause and ChangesetJSON; remove Repo, schemas, generated context, migrator module, DataCase, fixtures, and Ecto API tests.

- [ ] **Step 8: Refresh dependency lock**

Run:

```bash
rtk mix deps.unlock phoenix_ecto ecto_sql ecto_sqlite3 ecto exqlite db_connection decimal
rtk mix deps.get
rtk rg -n 'Blackgate\.Repo|Blackgate\.Api|Ecto|ecto_' lib test config mix.exs mix.lock
```

Expected: dependency refresh succeeds; final search has no active Ecto references.

- [ ] **Step 9: Run full Elixir verification**

```bash
rtk mix format --check-formatted
rtk mix compile --warnings-as-errors
rtk mix test
```

Expected: all commands exit 0.

- [ ] **Step 10: Commit Khepri-only test path**

Stage explicit touched Elixir/config/test files, then:

```bash
rtk git commit -m "test(core): replace Ecto scaffold with Khepri"
```

### Task 5: Harden Rust contract and workspace checks

**Files:**
- Create: `native/rust/scripts/ipc_smoke.py`
- Modify: Rust files only when fresh formatting, Clippy, or smoke failures prove defects

- [ ] **Step 1: Add failing IPC smoke harness**

Harness creates `/tmp/hydra_unix_sock`, starts `blackgate-engine <route-id>`, asserts `route_id:<id>`, sends deterministic SRT-to-UDP init JSON, waits for PLAYING/PAUSED state, sends `stop-route`, and requires exit 0 plus `Socket closed.`. It records stdout, stderr, and socket frames on failure.

- [ ] **Step 2: Run smoke before implementation is complete**

Run: `rtk python3 native/rust/scripts/ipc_smoke.py --engine native/build/blackgate-engine --check-only`  
Expected: FAIL until CLI and socket harness are complete.

- [ ] **Step 3: Complete harness and make it deterministic**

Use only Python standard library: `socket`, `subprocess`, `threading`, `tempfile`, `selectors`, `json`, and `time`. Clean socket and child process in `finally`. Reserve UDP ports through bound sockets before spawning.

- [ ] **Step 4: Run Rust quality gates**

```bash
rtk cargo fmt --manifest-path native/rust/Cargo.toml --all -- --check
rtk cargo clippy --manifest-path native/rust/Cargo.toml --workspace --all-targets -- -D warnings
rtk cargo test --manifest-path native/rust/Cargo.toml --workspace
rtk cargo build --manifest-path native/rust/Cargo.toml --release
rtk make -C native
rtk python3 native/rust/scripts/ipc_smoke.py --engine native/build/blackgate-engine
```

Expected: formatting clean, zero Clippy warnings, 25 or more tests pass, release build succeeds, smoke exits 0.

- [ ] **Step 5: Commit smoke and proven Rust fixes**

```bash
rtk git add native/rust/scripts/ipc_smoke.py
rtk git commit -m "test(native): add Rust engine IPC smoke"
```

### Task 6: Build benchmark result model with TDD

**Files:**
- Create: `benchmarks/migration/thresholds.json`
- Create: `benchmarks/migration/scripts/result_model.py`
- Create: `benchmarks/migration/tests/test_result_model.py`

- [ ] **Step 1: Write comparator tests**

Tests cover median selection, coefficient of variation, pass, regression, and inconclusive states. Approved thresholds:

```json
{
  "throughput_ratio_min": 0.99,
  "packet_loss_delta_max": 0.0,
  "cpu_ratio_max": 1.10,
  "peak_rss_ratio_max": 1.15,
  "latency_ratio_max": 1.10,
  "startup_ratio_max": 1.10,
  "failover_gap_ratio_max": 1.10,
  "coefficient_of_variation_max": 0.05
}
```

- [ ] **Step 2: Run tests and verify missing model fails**

Run: `rtk python3 -m unittest discover -s benchmarks/migration/tests -p 'test_result_model.py' -v`  
Expected: import failure for `result_model`.

- [ ] **Step 3: Implement result model**

Expose these exact functions:

```text
median_metrics(runs: list[dict]) -> dict
coefficient_of_variation(values: list[float]) -> float
compare(c_runs: list[dict], rust_runs: list[dict], thresholds: dict) -> dict
```

`median_metrics` returns medians for `throughput_mbps`, `packet_loss`,
`cpu_percent`, `peak_rss_bytes`, `latency_ms`, `startup_ms`, and
`failover_gap_ms`. `coefficient_of_variation` returns zero for fewer than two
values and otherwise population standard deviation divided by absolute mean.
`compare` evaluates throughput as Rust/C minimum ratio, packet loss as absolute
Rust-minus-C delta, and all remaining metrics as Rust/C maximum ratios.

Decision schema:

```json
{
  "status": "pass|fail|inconclusive",
  "metrics": {
    "cpu_ratio": {"c": 0.0, "rust": 0.0, "ratio": 0.0, "pass": true}
  },
  "reasons": []
}
```

- [ ] **Step 4: Run comparator tests**

Run: `rtk python3 -m unittest discover -s benchmarks/migration/tests -p 'test_result_model.py' -v`  
Expected: all tests PASS.

- [ ] **Step 5: Commit comparator**

```bash
rtk git add benchmarks/migration/thresholds.json benchmarks/migration/scripts/result_model.py benchmarks/migration/tests/test_result_model.py
rtk git commit -m "test(bench): enforce no-regression gates"
```

### Task 7: Define benchmark workloads and validation

**Files:**
- Create: `benchmarks/migration/workloads/*.json`
- Create: `benchmarks/migration/tests/test_workloads.py`

- [ ] **Step 1: Write workload schema tests**

Require unique workload IDs, source/sink protocols, width, height, FPS numerator/denominator, bitrate, warm-up 30 seconds, measurement 120 seconds, repetitions 3, and metric list. Require these IDs:

```text
srt-1080p25-5m
srt-1080p50-25m
srt-three-destinations
udp-to-srt
dual-ingest-failover
srt-thumbnail
non-sdi-soak
```

- [ ] **Step 2: Run tests and verify workload files are missing**

Run: `rtk python3 -m unittest discover -s benchmarks/migration/tests -p 'test_workloads.py' -v`  
Expected: FAIL because required workload files do not exist.

- [ ] **Step 3: Add exact workload JSON files**

Every normal workload uses 30-second warm-up, 120-second measurement, and three repetitions. Soak uses zero warm-up, 3600-second measurement, and one repetition. Three-destination workload uses one SRT caller, one SRT listener, and one UDP sink. Failover workload forces secondary at second 60 and primary at second 90.

- [ ] **Step 4: Run workload tests**

Run: `rtk python3 -m unittest discover -s benchmarks/migration/tests -p 'test_workloads.py' -v`  
Expected: PASS for all seven workloads.

- [ ] **Step 5: Commit workloads**

```bash
rtk git add benchmarks/migration/workloads benchmarks/migration/tests/test_workloads.py
rtk git commit -m "test(bench): define migration workloads"
```

### Task 8: Implement benchmark orchestrator and report

**Files:**
- Create: `benchmarks/migration/scripts/run_benchmark.py`
- Create: `benchmarks/migration/scripts/render_report.py`
- Create: `benchmarks/migration/tests/test_runner_dry_run.py`
- Create: `benchmarks/migration/README.md`

- [ ] **Step 1: Write dry-run lifecycle test**

Fake engine reads one init line, creates synthetic stats JSON, sleeps briefly, and exits on `stop-route`. Test requires orchestrator command planning, cleanup, result schema, and nonzero exit when child fails.

- [ ] **Step 2: Run dry-run test and verify failure**

Run: `rtk python3 -m unittest discover -s benchmarks/migration/tests -p 'test_runner_dry_run.py' -v`  
Expected: import failure for benchmark runner.

- [ ] **Step 3: Implement orchestrator interface**

```text
run_benchmark.py \
  --c-engine native/archive/c-engine/build/blackgate_pipeline \
  --rust-engine native/build/blackgate-engine \
  --workload benchmarks/migration/workloads/srt-1080p25-5m.json \
  --output benchmarks/migration/results/20260827T120000Z \
  [--dry-run] [--quick]
```

Orchestrator responsibilities: reserve ports, create Unix socket collector,
launch receiver, engine, and FFmpeg sender, apply failover commands, sample the
engine PID through `/proc/$engine_pid/stat` and `/proc/$engine_pid/status`,
collect engine/SRT stats, terminate process groups, write one JSON per run,
invoke comparator, and exit nonzero on fail/inconclusive.

- [ ] **Step 4: Implement report renderer**

Renderer produces one table per workload with C median, Rust median, ratio, threshold, and decision. Header includes Ubuntu image digest, kernel, CPU, toolchain versions, Git commit, start/end time, and overall state.

- [ ] **Step 5: Run Python test suite**

Run: `rtk python3 -m unittest discover -s benchmarks/migration/tests -v`  
Expected: comparator, workload, and dry-run tests all PASS.

- [ ] **Step 6: Run quick real benchmark smoke**

Run:

```bash
rtk python3 benchmarks/migration/scripts/run_benchmark.py --c-engine native/archive/c-engine/build/blackgate_pipeline --rust-engine native/build/blackgate-engine --workload benchmarks/migration/workloads/srt-1080p25-5m.json --output /tmp/blackgate-bench-smoke --quick
```

Expected: C and Rust each produce valid result JSON; report renders; exit status reflects comparison.

- [ ] **Step 7: Commit orchestrator**

```bash
rtk git add benchmarks/migration/scripts benchmarks/migration/tests/test_runner_dry_run.py benchmarks/migration/README.md
rtk git commit -m "perf: add C versus Rust benchmark harness"
```

### Task 9: Add Ubuntu 24.04 benchmark image

**Files:**
- Create: `benchmarks/migration/Dockerfile.ubuntu-24.04`
- Modify: `benchmarks/migration/README.md`

- [ ] **Step 1: Add image contract test to workload suite**

Assert Dockerfile starts with `ubuntu:24.04`, installs build/runtime GStreamer, SRT, FFmpeg, Python, `procps`, `sysstat`, Rust, and copies no production secrets.

- [ ] **Step 2: Run image contract test and verify failure**

Run: `rtk python3 -m unittest discover -s benchmarks/migration/tests -p 'test_workloads.py' -v`  
Expected: FAIL because Dockerfile is absent.

- [ ] **Step 3: Create benchmark Dockerfile**

Image builds C oracle and Rust release in separate layers, copies both into `/opt/blackgate/engines`, copies workloads/scripts, and uses the benchmark runner as entrypoint. Install Noble GStreamer 1.24 and SRT 1.5 packages from Ubuntu repositories.

- [ ] **Step 4: Build and inspect image**

```bash
rtk docker build -f benchmarks/migration/Dockerfile.ubuntu-24.04 -t blackgate-migration-bench:ubuntu-24.04 .
rtk docker run --rm blackgate-migration-bench:ubuntu-24.04 --help
rtk docker inspect blackgate-migration-bench:ubuntu-24.04
```

Expected: build exits 0; runner help exits 0; inspect reports Ubuntu image lineage.

- [ ] **Step 5: Commit benchmark image**

```bash
rtk git add benchmarks/migration/Dockerfile.ubuntu-24.04 benchmarks/migration/README.md benchmarks/migration/tests/test_workloads.py
rtk git commit -m "build(bench): add Ubuntu 24.04 image"
```

### Task 10: Add functional and performance CI

**Files:**
- Create: `.github/workflows/rust-migration-ci.yml`
- Create: `.github/workflows/rust-migration-performance.yml`

- [ ] **Step 1: Write workflow assertions in runtime guard test**

Require functional workflow triggers on pushes to and pull requests targeting `rust-migration`, uses `ubuntu-24.04`, runs Rust/Elixir/frontend/release guards, and uploads logs on failure. Require performance workflow only on schedule/manual dispatch and uploads JSON/Markdown artifacts.

- [ ] **Step 2: Run workflow test and verify failure**

Run: `rtk bash test/scripts/check_rust_only_runtime_test.sh`  
Expected: FAIL because migration workflows are absent.

- [ ] **Step 3: Add functional workflow**

Jobs: Rust quality, Elixir quality, frontend lint/build, Noble Docker build, release inspection, and short IPC smoke. Pin `actions/checkout@v4`, `actions/setup-node@v4` with Node 20.19.0, and `actions/upload-artifact@v4`.

- [ ] **Step 4: Add performance workflow**

Triggers: weekly schedule and workflow dispatch with `quick` input. Build benchmark image, run selected or full workloads, render report, upload all results even on comparison failure, then propagate benchmark exit status.

- [ ] **Step 5: Validate workflow syntax and guards**

```bash
rtk bash test/scripts/check_rust_only_runtime_test.sh
rtk rg -n 'ubuntu-(latest|22\.04)|jammy|blackgate_pipeline' .github/workflows/rust-migration-ci.yml .github/workflows/rust-migration-performance.yml
```

Expected: guard passes; search returns only permitted C-oracle benchmark arguments, never production runtime references.

- [ ] **Step 6: Commit workflows**

```bash
rtk git add .github/workflows/rust-migration-ci.yml .github/workflows/rust-migration-performance.yml test/scripts/check_rust_only_runtime_test.sh
rtk git commit -m "ci: verify Rust migration on Ubuntu 24.04"
```

### Task 11: Upgrade ISO builder to Ubuntu 24.04

**Files:**
- Modify: `iso-builder/build.sh`
- Modify: `iso-builder/autoinstall/user-data`
- Modify: `.github/workflows/build-iso.yml`
- Modify: ISO README/AGENTS and service environment

- [ ] **Step 1: Add ISO contract assertions to toolchain test**

Require `ubuntu-24.04.4-live-server-amd64.iso`, Noble CI container, `libssl3t64`, GStreamer 1.24 packages, bundled ERTS release, and no Docker-appliance claim.

- [ ] **Step 2: Run test and verify Jammy failure**

Run: `rtk bash test/scripts/check_toolchain_contract_test.sh`  
Expected: FAIL on current Jammy ISO path and workflow text.

- [ ] **Step 3: Update builder and autoinstall packages**

Change ISO input to `ubuntu-24.04.4-live-server-amd64.iso`. Use Noble package names and keep UDP sysctl settings. Preserve bare-metal systemd deployment and Blackgate user ownership.

- [ ] **Step 4: Correct ISO workflow**

Use `runs-on: ubuntu-24.04`, build with Noble dependencies, package bare-metal OTP release, and rewrite release notes. Remove Jammy, Docker-container, and host-networking claims that do not match scripts.

- [ ] **Step 5: Verify ISO preflight without building full image**

Run:

```bash
rtk bash -n iso-builder/build.sh
rtk bash -n iso-builder/files/blackgate-firstboot.sh
rtk bash test/scripts/check_toolchain_contract_test.sh
```

Expected: shell syntax and contract tests PASS. Full ISO build remains CI/Linux verification because macOS lacks required boot tooling.

- [ ] **Step 6: Commit Noble ISO support**

```bash
rtk git add iso-builder .github/workflows/build-iso.yml test/scripts/check_toolchain_contract_test.sh
rtk git commit -m "build(iso): target Ubuntu 24.04 Noble"
```

### Task 12: Update active documentation

**Files:**
- Modify: root/subsystem README and AGENTS files
- Modify: active architecture, user guide, troubleshooting, and failover documents
- Create: migration status and SDI sign-off documents

- [ ] **Step 1: Capture stale active-runtime claims**

Run:

```bash
rtk rg -n 'Native C|blackgate_pipeline|srt_proxy|React 18|Debian 12|Bookworm|Ubuntu 22\.04|Jammy|Docker Appliance' README.md AGENTS.md native lib web_app iso-builder docs --glob '!docs/memory/**' --glob '!docs/superpowers/**' --glob '!native/archive/**'
```

Expected: current stale claims listed for replacement.

- [ ] **Step 2: Rewrite architecture and subsystem docs**

Required facts: Rust engine, React 19, Khepri-only persistence, Ubuntu 24.04 LTS, bare-metal OTP release, C oracle archive, benchmark commands, no-regression thresholds, and manual SDI gate. Historical C discussion must be labeled historical.

- [ ] **Step 3: Add migration status document**

Initial state is `IN_PROGRESS`. Document evidence paths and exact transition rules to `AUTOMATED_COMPLETE`, `SDI_MANUAL_PENDING`, and `PRODUCTION_COMPLETE`.

- [ ] **Step 4: Add physical SDI sign-off checklist**

Checklist records gateway identifier, Ubuntu version, Desktop Video version, DeckLink model, video modes, eight-channel audio, auto-detect, silence recovery, failover, one-hour stability, operator, date, logs, and result.

- [ ] **Step 5: Verify active docs contain no stale runtime claims**

Run the Step 1 search again.  
Expected: no unlabeled active-runtime C/Jammy/React 18/Debian claims outside archive/history.

- [ ] **Step 6: Commit documentation**

```bash
rtk git add README.md AGENTS.md native/README.md native/AGENTS.md lib/AGENTS.md web_app/AGENTS.md iso-builder/README.md iso-builder/AGENTS.md
rtk git add docs/BLACKGATE_TECHNICAL_ANALYSIS.md docs/USER_GUIDE.md docs/TROUBLESHOOTING.md docs/failover-runbook.md
rtk git add docs/migration/RUST_MIGRATION_STATUS.md docs/migration/SDI_MANUAL_SIGNOFF.md
rtk git commit -m "docs: document Rust-only Noble platform"
```

### Task 13: Run full automated verification

**Files:**
- Modify only when verification exposes a migration defect

- [ ] **Step 1: Verify worktree scope**

```bash
rtk git branch --show-current
rtk git status --short
```

Expected: branch is `rust-migration`; user-owned edits remain identifiable.

- [ ] **Step 2: Run static and unit checks**

```bash
rtk bash test/scripts/check_rust_only_runtime_test.sh
rtk bash test/scripts/check_toolchain_contract_test.sh
rtk bash scripts/check_rust_only_runtime.sh --root .
rtk bash scripts/check_toolchain_contract.sh
rtk cargo fmt --manifest-path native/rust/Cargo.toml --all -- --check
rtk cargo clippy --manifest-path native/rust/Cargo.toml --workspace --all-targets -- -D warnings
rtk cargo test --manifest-path native/rust/Cargo.toml --workspace
rtk mix format --check-formatted
rtk mix compile --warnings-as-errors
rtk mix test
rtk npm --prefix web_app run lint
rtk npm --prefix web_app run build
rtk python3 -m unittest discover -s benchmarks/migration/tests -v
```

Expected: every command exits 0.

- [ ] **Step 3: Run build and runtime checks**

```bash
rtk make -C native
rtk python3 native/rust/scripts/ipc_smoke.py --engine native/build/blackgate-engine
rtk env MIX_ENV=prod mix release --overwrite
rtk docker build -t blackgate:rust-migration-noble .
rtk docker build -f benchmarks/migration/Dockerfile.ubuntu-24.04 -t blackgate-migration-bench:ubuntu-24.04 .
rtk bash scripts/check_rust_only_runtime.sh --root . --release _build/prod/rel/blackgate
```

Expected: native build, smoke, images, and release inspection PASS.

- [ ] **Step 4: Fix only evidenced defects and rerun failed command**

For each failure, record command and error, apply minimal fix, rerun the exact failing command, then rerun its containing verification group.

- [ ] **Step 5: Commit verified fixes**

Use one focused commit per defect with tests proving regression coverage.

### Task 14: Run no-regression performance suite

**Files:**
- Create: `benchmarks/migration/results/$run_id/*`, where `$run_id` is the UTC
  basic timestamp generated by the harness
- Modify: `docs/migration/RUST_MIGRATION_STATUS.md`

- [ ] **Step 1: Run all six normal workloads in Ubuntu image**

```bash
rtk docker run --rm --network host --privileged -v "$PWD/benchmarks/migration/results:/results" blackgate-migration-bench:ubuntu-24.04 --all --output /results
```

Expected: each engine gets three measured repetitions per workload; JSON and Markdown evidence written.

- [ ] **Step 2: Inspect variance and decisions**

Run: `rtk python3 benchmarks/migration/scripts/render_report.py benchmarks/migration/results/$run_id`  
Expected: every workload `pass`; any `inconclusive` triggers additional repetitions, never manual override.

- [ ] **Step 3: Run one-hour non-SDI soak**

Run benchmark image with `non-sdi-soak.json` for C and Rust.  
Expected: both complete 3600 seconds; Rust meets throughput, loss, CPU, RSS, and latency gates.

- [ ] **Step 4: Update migration status from evidence**

If every functional and performance check passed, set status to `SDI_MANUAL_PENDING`, link report directory, record commit and image digest, and list physical SDI as sole remaining gate. Otherwise retain `IN_PROGRESS` and list exact failed/inconclusive metrics.

- [ ] **Step 5: Commit benchmark evidence and status**

```bash
rtk git add benchmarks/migration/results docs/migration/RUST_MIGRATION_STATUS.md
rtk git commit -m "perf: record C versus Rust migration baseline"
```

### Task 15: Final review and handoff

**Files:**
- Review all migration commits and status documents

- [ ] **Step 1: Run final fresh verification**

Repeat Task 13 Steps 2-3 against final HEAD. Do not reuse prior output.

- [ ] **Step 2: Review branch diff and forbidden scope**

```bash
rtk git log --oneline origin/rust-migration..HEAD
rtk git diff --stat origin/rust-migration...HEAD
rtk git diff --check origin/rust-migration...HEAD
rtk git status --short --branch
```

Expected: only `rust-migration` changed; diff check clean; user-owned files intentionally preserved or explicitly included with tests.

- [ ] **Step 3: Request code review**

Invoke `requesting-code-review`, resolve findings using `receiving-code-review`, and rerun affected verification.

- [ ] **Step 4: Report honest completion state**

Report command evidence, benchmark ratios, commits, remaining user-owned changes, and status. Never claim `PRODUCTION_COMPLETE` until signed physical SDI checklist exists.
