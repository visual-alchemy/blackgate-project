#!/usr/bin/env bash
# Which element holds the memory: the H.264 parser, or the decoder, and does its thread pool matter?
#
# Established before this script: demux alone and demux+queue2 are flat; adding h264parse+avdec_h264 makes
# the process grow 8-9 MB/min at full speed, with or without a queue, and no malloc setting changes it.
# heaptrack cannot be used here (segfaults on this ffmpeg pipeline and records only startup allocations),
# so narrow it down by element instead of by allocator.
#
#   D  parse only         tsdemux ! h264parse ! fakesink
#   E  decode only        tsdemux ! avdec_h264 ! fakesink            (avdec has its own parser)
#   F  decode, 1 thread   tsdemux ! h264parse ! avdec_h264 max-threads=1 ! fakesink
#   G  baseline           tsdemux ! h264parse ! avdec_h264 ! fakesink
#
# Usage: bash decode-bisect.sh [seconds-per-arm]
set -uo pipefail
PER="${1:-240}"
TS="${TS:-/home/blackgate/.hermes/cache/scratch/int1080i-v.ts}"
CPUS="${CPUS:-4-6}"
WORK="${WORK:-/home/blackgate/.hermes/cache/scratch}"
OUT="${OUT:-/home/blackgate/blackgate-trend/valgrind/decode-bisect-$(date -u +%H%M%S).log}"
SRC="multifilesrc location=$TS loop=true caps=video/mpegts"

run_arm() {
  local tag="$1" desc="$2" chain="$3"
  echo "=== arm $tag: $desc"
  trap 'kill ${GPID:-} 2>/dev/null' EXIT INT TERM
  taskset -c "$CPUS" gst-launch-1.0 -e -q $chain >"$WORK/dec-$tag.log" 2>&1 &
  GPID=$!
  sleep 15
  kill -0 "$GPID" 2>/dev/null || { echo "    DEAD: $(tail -1 "$WORK/dec-$tag.log" | cut -c1-90)"; return; }
  local r0 r="" t=0
  r0=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status")
  while [ "$t" -lt "$PER" ]; do
    kill -0 "$GPID" 2>/dev/null || break
    sleep 60; t=$(( t + 60 ))
    r=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status")
    printf '      t=%-4s %s MB\n' "${t}s" "$r"
  done
  kill "$GPID" 2>/dev/null; sleep 2; kill -9 "$GPID" 2>/dev/null
  printf '    RESULT %s: %s -> %s MB (%+d in %ss)\n\n' "$tag" "$r0" "${r:-?}" "$(( ${r:-0} - r0 ))" "$PER"
  echo "$tag desc=$desc rss0=$r0 rssN=${r:-?} delta=$(( ${r:-0} - r0 )) per=$PER" >>"$OUT"
}

run_arm D "parse only"       "$SRC ! tsdemux ! h264parse ! fakesink sync=false"
run_arm E "decode only"      "$SRC ! tsdemux ! avdec_h264 ! fakesink sync=false"
run_arm F "decode 1 thread"  "$SRC ! tsdemux ! h264parse ! avdec_h264 max-threads=1 ! fakesink sync=false"
run_arm G "baseline"         "$SRC ! tsdemux ! h264parse ! avdec_h264 ! fakesink sync=false"

echo "ringkasan ($OUT):"
sed 's/^/  /' "$OUT"
echo
echo "D naik        -> h264parse menahan; E naik -> avdec_h264 sendiri sudah cukup."
echo "F datar       -> thread pool decoder yang jadi biang, bukan jalur parse."
