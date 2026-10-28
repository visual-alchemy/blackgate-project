#!/usr/bin/env bash
# Which element in the SDI branch keeps memory? Bisect the chain, one variant at a time.
#
# The full branch (with fakesink instead of decklinkvideosink) grew 184 -> 278 MB in 15 minutes while
# decoding at 270% CPU, so the DeckLink plugin is not involved and no device or route is needed. Each
# variant below adds one more element than the previous, runs the same 1080i50 file looped through it,
# and reports its own RSS delta. The first variant that grows is the element that holds the memory.
#
# Usage: bash sdi-bisect.sh [seconds-per-variant] [start-variant] [end-variant]
set -uo pipefail
PER="${1:-240}"
FROM="${2:-0}"
TO="${3:-4}"
TS="${TS:-/home/blackgate/.hermes/cache/scratch/int1080i-v.ts}"
CPUS="${CPUS:-4-6}"
OUT="${OUT:-/home/blackgate/blackgate-trend/valgrind/bisect-$(date -u +%H%M%S).log}"
[ -f "$TS" ] || { echo "FAIL: no TS at $TS"; exit 2; }

run_variant() {
  local idx="$1" name="$2" chain="$3"
  local log="/home/blackgate/blackgate-trend/valgrind/bisect-v$idx.log"
  echo "=== v$idx: $name"
  echo "    chain: $chain"
  trap 'kill ${GPID:-} 2>/dev/null' EXIT INT TERM
  eval "taskset -c $CPUS gst-launch-1.0 -e -q $chain >\"$log\" 2>&1 &"
  GPID=$!
  sleep 12
  if ! kill -0 "$GPID" 2>/dev/null; then
    echo "    DEAD at startup: $(tail -2 "$log" | tr '\n' ' ')"
    return
  fi
  local first="" last="" ct0="" ct1="" t=0
  first=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status" 2>/dev/null)
  ct0=$(awk '{print $14+$15}' "/proc/$GPID/stat" 2>/dev/null)
  while [ "$t" -lt "$PER" ]; do
    kill -0 "$GPID" 2>/dev/null || { echo "    exited early"; break; }
    last=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status" 2>/dev/null)
    sleep 30; t=$(( t + 30 ))
  done
  ct1=$(awk '{print $14+$15}' "/proc/$GPID/stat" 2>/dev/null)
  local cpu=$(( (${ct1:-0} - ${ct0:-0}) * 100 / PER / $(getconf CLK_TCK) ))
  kill "$GPID" 2>/dev/null; sleep 2; kill -9 "$GPID" 2>/dev/null
  local delta=$(( ${last:-0} - ${first:-0} ))
  local ppm=$(( delta * 60 / PER ))
  printf '    rss %s -> %s MB   delta %+d MB in %ss   (+%d MB/min)   cpu %s%%\n' \
    "${first:-?}" "${last:-?}" "$delta" "$PER" "$ppm" "$cpu"
  echo "    verdict: $([ "$delta" -ge 20 ] && echo GROWS || echo flat-at-this-scale)"
  echo
  echo "v$idx $name  first=${first:-?} last=${last:-?} delta=$delta cpu=$cpu% per_min=$ppm" >>"$OUT"
}

SRC="multifilesrc location=$TS loop=true caps=video/mpegts"
Q2="queue2 use-buffering=false max-size-buffers=0 max-size-bytes=0 max-size-time=5000000000"
UYVY="capsfilter caps=video/x-raw,format=UYVY,width=1920,height=1080,framerate=25/1"

[ "$FROM" -le 0 ] && [ "$TO" -ge 0 ] && run_variant 0 "demux only"        "$SRC ! tsdemux ! fakesink sync=false"
[ "$FROM" -le 1 ] && [ "$TO" -ge 1 ] && run_variant 1 "queue2 5s"          "$SRC ! tsdemux ! $Q2 ! fakesink sync=false"
[ "$FROM" -le 2 ] && [ "$TO" -ge 2 ] && run_variant 2 "decode"             "$SRC ! tsdemux ! $Q2 ! h264parse ! avdec_h264 ! fakesink sync=false"
[ "$FROM" -le 3 ] && [ "$TO" -ge 3 ] && run_variant 3 "decode+convert"     "$SRC ! tsdemux ! $Q2 ! h264parse ! avdec_h264 ! queue ! videoconvert ! $UYVY ! fakesink sync=false"
[ "$FROM" -le 4 ] && [ "$TO" -ge 4 ] && run_variant 4 "full branch"        "$SRC ! tsdemux ! $Q2 ! h264parse ! avdec_h264 ! queue max-size-time=5000000000 ! videoconvert ! videorate skip-to-first=true ! videoscale ! $UYVY ! identity sync=false ! fakesink sync=false"

echo "ringkasan: $OUT"
sort -t= -k5 -n "$OUT" 2>/dev/null | sed 's/^/  /'
