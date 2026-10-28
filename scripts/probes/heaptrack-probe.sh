#!/usr/bin/env bash
# heaptrack the decode chain: which allocations are ALIVE and growing, at native allocator behaviour.
#
# Why heaptrack and not valgrind: valgrind replaces glibc's allocator, and under it the same pipeline
# showed a flat 109 MB heap while native RSS grew ~7-8 MB/min. heaptrack instead LD_PRELOADs an
# interposer, so glibc still does the allocating; it just records every malloc/free with a backtrace and
# can show the live set at any point in time. That is the instrument that matches the evidence.
#
# Requires: sudo apt-get install -y heaptrack
# Usage: bash heaptrack-probe.sh [seconds]
set -uo pipefail
DURATION="${1:-300}"
TS="${TS:-/home/blackgate/.hermes/cache/scratch/int1080i-v.ts}"
CPUS="${CPUS:-4-6}"
WORK="${WORK:-/home/blackgate/.hermes/cache/scratch}"
SRC="multifilesrc location=$TS loop=true caps=video/mpegts"
Q2="queue2 use-buffering=false max-size-buffers=0 max-size-bytes=0 max-size-time=5000000000"
CHAIN="$SRC ! tsdemux ! $Q2 ! h264parse ! avdec_h264 ! fakesink sync=false"
command -v heaptrack >/dev/null || { echo "FAIL: heaptrack belum terpasang (sudo apt-get install -y heaptrack)"; exit 2; }
rm -rf "$WORK"/heaptrack.*.gz "$WORK"/heaptrack.*.zst 2>/dev/null

echo "chain:  $CHAIN"
echo "run:    ${DURATION}s under heaptrack (overhead is far lower than valgrind: glibc still allocates)"
trap 'kill ${GPID:-} 2>/dev/null' EXIT INT TERM
taskset -c "$CPUS" heaptrack -o "$WORK/heaptrack-sdi" gst-launch-1.0 -e -q $CHAIN \
  >"$WORK/heaptrack-run.log" 2>&1 &
GPID=$!
sleep 20
kill -0 "$GPID" 2>/dev/null || { echo "FAIL: died at startup"; tail -5 "$WORK/heaptrack-run.log"; exit 3; }

t=0
while [ "$t" -lt "$DURATION" ]; do
  kill -0 "$GPID" 2>/dev/null || break
  rss=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status" 2>/dev/null)
  printf '  t=%-4s rss=%s MB\n' "${t}s" "${rss:-?}"
  sleep 60; t=$(( t + 60 ))
done
kill -TERM "$GPID" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$GPID" 2>/dev/null || break; sleep 3; done
kill -9 "$GPID" 2>/dev/null
sleep 5

FILE=$(ls -t "$WORK"/heaptrack-sdi*.zst "$WORK"/heaptrack-sdi*.gz 2>/dev/null | head -1)
[ -n "$FILE" ] || { echo "FAIL: no heaptrack output written"; exit 4; }
echo
echo "profile: $FILE"
echo
echo "=== top allocation sites by bytes still alive at exit ==="
heaptrack_print "$FILE" 2>/dev/null | awk '/^Most memory still allocated at program exit/,/^$/' | head -30
echo
echo "=== top allocation sites by total bytes allocated (churn) ==="
heaptrack_print "$FILE" 2>/dev/null | awk '/^Most allocations happened/,/^$/' | head -20
echo
echo "Baca: yang penting adalah 'still allocated at exit' — kalau di situ ada baris yang sesuai laju"
echo "pertumbuhan RSS, itu titik kebocorannya, lengkap dengan fungsi dan baris."
