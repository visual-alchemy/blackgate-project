#!/usr/bin/env bash
set -euo pipefail

root="."
release_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      root="$2"
      shift 2
      ;;
    --release)
      release_dir="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

paths=()
for path in mix.exs Makefile Dockerfile docker-compose.yml lib rel iso-builder; do
  [[ -e "$root/$path" ]] && paths+=("$root/$path")
done

if [[ ${#paths[@]} -gt 0 ]] &&
  rg -n 'blackgate_pipeline|srt_proxy|native/(src|include|tests)|COPY[[:space:]]+native[[:space:]]+native' "${paths[@]}"; then
  echo "forbidden C runtime reference found" >&2
  exit 1
fi

if [[ -n "$release_dir" ]] &&
  find "$release_dir" -type f \( -name blackgate_pipeline -o -name srt_proxy \) | grep -q .; then
  echo "forbidden C binary found in release" >&2
  exit 1
fi

echo "Rust-only runtime guard passed"
