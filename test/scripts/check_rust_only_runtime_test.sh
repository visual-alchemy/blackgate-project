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
