#!/usr/bin/env bash
# The heap a program actually holds stays flat (massif: 108.1 -> 108.9 MB) while RSS climbs ~9 MB/min.
# That is the signature of glibc's dynamic mmap threshold: the first big free raises the threshold, so
# later big allocations come from the main heap instead of mmap, and freed pages are never handed back
# to the kernel. It also explains why MALLOC_ARENA_MAX=2 / MALLOC_TRIM_THRESHOLD_ did nothing -- they do
# not stop the heap from taking those blocks in the first place.
#
# A/B on the same decode chain: arm "base" leaves malloc alone, arm "pinned" pins the mmap threshold low
# so every multi-megabyte video buffer is mmap'd and returned on free.
#
# Usage: bash malloc-threshold-ab.sh [seconds] [arm...]
set -uo pipefail
PER="${1:-300}"
ARMS="${2:-base pinned}"
TS="${TS:-/home/blackgate/.hermes/cache/scratch/int1080i-v.ts}"
CPUS="${CPUS:-4-6}"
OUT="${OUT:-/home/blackgate/blackgate-trend/valgrind/malloc-ab-$(date -u +%H%M%S).log}"
[ -f "$TS" ] || { echo "FAIL: no TS at $TS"; exit 2; }
SRC="multifilesrc location=$TS loop=true caps=video/mpegts"
Q2="queue2 use-buffering=false max-size-buffers=0 max-size-bytes=0 max-size-time=5000000000"
CHAIN="$SRC ! tsdemux ! $Q2 ! h264parse ! avdec_h264 ! fakesink sync=false"

run_arm() {
  local arm="$1" envs=""
  case "$arm" in
    pinned) envs="MALLOC_MMAP_THRESHOLD_=131072 MALLOC_TRIM_THRESHOLD_=131072 MALLOC_TOP_PAD_=0" ;;
    arena)  envs="MALLOC_ARENA_MAX=2" ;;
    both)   envs="MALLOC_MMAP_THRESHOLD_=131072 MALLOC_TRIM_THRESHOLD_=131072 MALLOC_ARENA_MAX=2" ;;
    arena1) envs="MALLOC_ARENA_MAX=1 MALLOC_TRIM_THRESHOLD_=131072" ;;
    arena1t) envs="MALLOC_ARENA_MAX=1 MALLOC_TRIM_THRESHOLD_=0" ;;
  esac
  echo "=== arm: $arm   env: ${envs:-none}"
  trap 'kill ${GPID:-} 2>/dev/null' EXIT INT TERM
  env $envs taskset -c "$CPUS" gst-launch-1.0 -e -q $CHAIN \
    >"/home/blackgate/blackgate-trend/valgrind/malloc-ab-$arm.log" 2>&1 &
  GPID=$!
  sleep 15
  kill -0 "$GPID" 2>/dev/null || { echo "    DEAD at startup"; return; }
  local r0 d0 r="" d="" t=0
  r0=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status")
  d0=$(awk '/VmData/{print int($2/1024)}' "/proc/$GPID/status")
  while [ "$t" -lt "$PER" ]; do
    kill -0 "$GPID" 2>/dev/null || break
    r=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status")
    d=$(awk '/VmData/{print int($2/1024)}' "/proc/$GPID/status")
    sleep 60; t=$(( t + 60 ))
  done
  kill "$GPID" 2>/dev/null; sleep 2; kill -9 "$GPID" 2>/dev/null
  printf '    rss %s -> %s MB (%+d)   vmdata %s -> %s MB (%+d)   over %ss\n' \
    "$r0" "$r" "$(( ${r:-0} - ${r0:-0} ))" "$d0" "$d" "$(( ${d:-0} - ${d0:-0} ))" "$PER"
  echo "$arm rss0=$r0 rssN=$r rss_delta=$(( ${r:-0} - ${r0:-0} )) vmdata0=$d0 vmdataN=$d vmdata_delta=$(( ${d:-0} - ${d0:-0} )) per=$PER" >>"$OUT"
}

for a in $ARMS; do run_arm "$a"; echo; done
echo "ringkasan ($OUT):"
sed 's/^/  /' "$OUT"
echo
echo "Baca: kalau delta RSS arm 'pinned' jauh lebih kecil dari 'base', penyebabnya ambang mmap glibc,"
echo "dan perbaikannya adalah env tetap di unit engine (atau mallopt di kode), bukan perubahan pipeline."
