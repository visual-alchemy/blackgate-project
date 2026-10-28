#!/usr/bin/env bash
# Is the growth real, or is it my own probe looping timestamps into a time-limited queue?
#
# The 20-minute run grew linearly (162 -> 263 MB) in large anonymous mappings with [heap] flat and every
# malloc knob ineffective. That is what a QUEUE holding buffers looks like, not an allocator problem.
# The probe loops a 20 s TS file, so the PTS restarts every loop; queue2's limit here is max-size-time,
# and a queue that never sees time advance never reports full.
#
# Three arms, same decode, different queueing:
#   A  queue2 max-size-time=5s      (what the SDI branch in builder.rs uses -- the suspect)
#   B  no queue at all              (if this is flat, the queue is the whole story)
#   C  queue max-size-buffers=100   (bounded by count, immune to timestamp resets)
#
# Usage: bash leak-isolate.sh [seconds-per-arm]
set -uo pipefail
PER="${1:-300}"
TS="${TS:-/home/blackgate/.hermes/cache/scratch/int1080i-v.ts}"
CPUS="${CPUS:-4-6}"
WORK="${WORK:-/home/blackgate/.hermes/cache/scratch}"
OUT="${OUT:-/home/blackgate/blackgate-trend/valgrind/leak-isolate-$(date -u +%H%M%S).log}"
SRC="multifilesrc location=$TS loop=true caps=video/mpegts"
Q2="queue2 use-buffering=false max-size-buffers=0 max-size-bytes=0 max-size-time=5000000000"

run_arm() {
  local tag="$1" desc="$2" chain="$3"
  echo "=== arm $tag: $desc"
  trap 'kill ${GPID:-} 2>/dev/null' EXIT INT TERM
  taskset -c "$CPUS" gst-launch-1.0 -e -q $chain >"$WORK/leak-$tag.log" 2>&1 &
  GPID=$!
  sleep 15
  kill -0 "$GPID" 2>/dev/null || { echo "    DEAD: $(tail -1 "$WORK/leak-$tag.log" | cut -c1-100)"; return; }
  local r0=0 r="" t=0
  r0=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status")
  echo "    mulai ${r0} MB"
  while [ "$t" -lt "$PER" ]; do
    kill -0 "$GPID" 2>/dev/null || break
    sleep 60; t=$(( t + 60 ))
    r=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status")
    printf '      t=%-4s %s MB\n' "${t}s" "$r"
  done
  kill "$GPID" 2>/dev/null; sleep 2; kill -9 "$GPID" 2>/dev/null
  printf '    RESULT %s: %s -> %s MB  (%+d MB in %ss)\n\n' "$tag" "$r0" "${r:-?}" "$(( ${r:-0} - r0 ))" "$PER"
  echo "$tag desc=$desc rss0=$r0 rssN=${r:-?} delta=$(( ${r:-0} - r0 )) per=$PER" >>"$OUT"
}

run_arm A "queue2 max-size-time 5s"      "$SRC ! tsdemux ! $Q2 ! h264parse ! avdec_h264 ! fakesink sync=false"
run_arm B "tanpa queue"                  "$SRC ! tsdemux ! h264parse ! avdec_h264 ! fakesink sync=false"
run_arm C "queue max-size-buffers=100"   "$SRC ! tsdemux ! queue max-size-buffers=100 ! h264parse ! avdec_h264 ! fakesink sync=false"

echo "ringkasan ($OUT):"
sed 's/^/  /' "$OUT"
echo
echo "Kalau B dan C datar sementara A naik: pertumbuhannya artefak queue2 + timestamp yang diulang,"
echo "bukan kebocoran di kode engine. Kalau ketiganya naik: memang ada kebocoran di jalur decode."
