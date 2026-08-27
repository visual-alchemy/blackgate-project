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

printf '%s\n' 'COPY native native' > "$fixture/Dockerfile"
if "$guard" --root "$fixture"; then
  echo "guard accepted broad native production copy" >&2
  exit 1
fi

printf '%s\n' 'COPY native/rust native/rust' > "$fixture/Dockerfile"
"$guard" --root "$fixture"

touch "$fixture/native/build/blackgate_pipeline"
if "$guard" --root "$fixture" --release "$fixture/native/build"; then
  echo "guard accepted forbidden C release binary" >&2
  exit 1
fi

require_pattern() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if [[ ! -f "$file" ]] || ! rg -q -- "$pattern" "$file"; then
    echo "missing workflow contract: $description" >&2
    exit 1
  fi
}

functional="$repo_root/.github/workflows/rust-migration-ci.yml"
performance="$repo_root/.github/workflows/rust-migration-performance.yml"

for contract in \
  'push:' \
  'pull_request:' \
  'rust-migration' \
  'ubuntu-24.04' \
  'cargo fmt' \
  'cargo clippy' \
  'cargo test' \
  'mix format --check-formatted' \
  'mix compile --warnings-as-errors' \
  'mix test' \
  'npm --prefix web_app run lint' \
  'npm --prefix web_app run build' \
  'ipc_smoke.py' \
  'check_rust_only_runtime.sh' \
  'check_toolchain_contract.sh' \
  'actions/upload-artifact@v4'; do
  require_pattern "$functional" "$contract" "$contract in functional workflow"
done

for contract in \
  'schedule:' \
  'workflow_dispatch:' \
  'Dockerfile.ubuntu-24.04' \
  'run_benchmark.py' \
  'render_report.py' \
  'actions/upload-artifact@v4' \
  'if: always()'; do
  require_pattern "$performance" "$contract" "$contract in performance workflow"
done

if rg -q '^[[:space:]]+(push|pull_request):' "$performance"; then
  echo "performance workflow must not run on push or pull request" >&2
  exit 1
fi
