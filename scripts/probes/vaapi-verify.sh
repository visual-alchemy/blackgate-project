#!/usr/bin/env bash
# Verify vaapih264dec two ways before trusting it: does it really decode, and does it stay flat longer?
#
# The 3-minute arm was flat (+2 MB) while avdec_h264 grew +43 MB over a comparable run. A flat RSS with low
# CPU can also mean "decoded nothing", so this run puts fpsdisplaysink in the chain: it prints measured fps
# every second. A real 1080i50 decode shows ~25-50 fps; a stalled one shows 0.
#
# Usage: bash vaapi-verify.sh [seconds]
set -uo pipefail
DURATION="${1:-540}"
TS="${TS:-/home/blackgate/.hermes/cache/scratch/int1080i-v.ts}"
CPUS="${CPUS:-4-6}"
WORK="${WORK:-/home/blackgate/.hermes/cache/scratch}"
LOG="$WORK/vaapi-verify.log"

echo "chain: multifilesrc(loop) ! tsdemux ! h264parse ! vaapih264dec ! videoconvert ! fpsdisplaysink"
echo "run:   ${DURATION}s, pinned to cores $CPUS"
trap 'kill ${GPID:-} 2>/dev/null' EXIT INT TERM
taskset -c "$CPUS" gst-launch-1.0 -e \
  multifilesrc location="$TS" loop=true caps="video/mpegts" \
  ! tsdemux ! h264parse ! vaapih264dec ! videoconvert \
  ! fpsdisplaysink video-sink=fakesink text-overlay=false signal-fps-measurements=true \
  >"$LOG" 2>&1 &
GPID=$!
sleep 20
kill -0 "$GPID" 2>/dev/null || { echo "FAIL: died at startup"; tail -6 "$LOG"; exit 3; }

t=0
while [ "$t" -lt "$DURATION" ]; do
  kill -0 "$GPID" 2>/dev/null || break
  sleep 60; t=$(( t + 60 ))
  rss=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status")
  printf '  t=%-4s rss=%s MB\n' "${t}s" "$rss"
done
kill "$GPID" 2>/dev/null; sleep 2; kill -9 "$GPID" 2>/dev/null

echo
echo "=== fps terakhir yang dilaporkan (bukti benar-benar decode) ==="
grep -aoE "average: [0-9.]+|last-message = rendered: [0-9]+" "$LOG" | tail -4 | sed 's/^/  /'
grep -aoE "\([0-9]+\.[0-9]+ fps\)" "$LOG" | tail -3 | sed 's/^/  /'
echo
echo "=== error/warning dari pipeline ==="
grep -aiE "error|warning|not-negotiated|failed" "$LOG" | tail -5 | cut -c1-150 | sed 's/^/  /'
echo "  (kosong = tidak ada masalah)"
