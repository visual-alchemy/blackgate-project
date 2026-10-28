#!/usr/bin/env bash
# Massif the variant that leaks, and name the functions holding the memory.
#
# The bisect nailed the stage: v2 (demux ! queue2 ! h264parse ! avdec_h264 ! fakesink) grew 161 -> 199 MB
# in 4 minutes at 270% CPU, while demux alone and demux+queue2 stayed flat. So the memory is held in the
# H.264 decode stage, not in conversion, scaling or the DeckLink sink.
#
# Massif records the heap composition over time; comparing its detailed snapshots shows which allocation
# stack grew. That is the difference between "decode leaks" and "this avcodec buffer pool in this
# function is never released".
#
# Usage: bash sdi-massif.sh [seconds]
set -uo pipefail
DURATION="${1:-300}"
TS="${TS:-/home/blackgate/.hermes/cache/scratch/int1080i-v.ts}"
CPUS="${CPUS:-4-6}"
WORK="${WORK:-/home/blackgate/blackgate-trend/valgrind}"
OUT="$WORK/massif.out"
LOG="$WORK/massif-run.log"
[ -f "$TS" ] || { echo "FAIL: no TS at $TS"; exit 2; }
rm -f "$OUT"

SRC="multifilesrc location=$TS loop=true caps=video/mpegts"
Q2="queue2 use-buffering=false max-size-buffers=0 max-size-bytes=0 max-size-time=5000000000"
CHAIN="$SRC ! tsdemux ! $Q2 ! h264parse ! avdec_h264 ! fakesink sync=false"

echo "chain: $CHAIN"
echo "run:   ${DURATION}s under valgrind massif (expect ~10x slower than the 270%-CPU native run)"
echo "out:   $OUT"

trap 'kill ${VPID:-} 2>/dev/null' EXIT INT TERM
# --threshold=0.01 (not the 1% default): the leak is a few MB against a 108 MB steady-state heap, and at
# 1% every candidate was collapsed into "all below massif's threshold" -- which is exactly how a real
# leak hides. --depth=16 keeps the trees small enough to diff.
taskset -c "$CPUS" valgrind --tool=massif --detailed-freq=1 --max-snapshots=200 \
  --threshold=0.01 --depth=16 \
  --massif-out-file="$OUT" \
  gst-launch-1.0 -e -q $CHAIN >"$LOG" 2>&1 &
VPID=$!
sleep 20
kill -0 "$VPID" 2>/dev/null || { echo "FAIL: died at startup:"; tail -5 "$LOG"; exit 3; }

t=0
while [ "$t" -lt "$DURATION" ]; do
  rss=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$VPID/status" 2>/dev/null)
  printf '  t=%-4s rss=%s MB  snapshots=%s\n' "${t}s" "${rss:-?}" "$(grep -c '^snapshot=' "$OUT" 2>/dev/null)"
  sleep 30; t=$(( t + 30 ))
done

echo "stopping the pipeline so massif writes its final snapshot..."
kill -TERM "$VPID" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$VPID" 2>/dev/null || break; sleep 3; done
kill -9 "$VPID" 2>/dev/null

echo
echo "=== heap composition: first detailed snapshot vs last ==="
python3 - "$OUT" <<'PY'
import re, sys
snaps, cur = [], None
for line in open(sys.argv[1], errors="replace"):
    if line.startswith("snapshot="):
        cur = {"id": int(line.split("=")[1]), "time": None, "mem": None, "tree": [], "detailed": False}
        snaps.append(cur)
    elif cur is None:
        continue
    elif line.startswith("time=") and cur["time"] is None:
        cur["time"] = int(line.split("=")[1])
    elif line.startswith("mem_heap_B="):
        cur["mem"] = int(line.split("=")[1])
    elif line.startswith("heap_tree=detailed"):
        cur["detailed"] = True
    elif cur["detailed"] and re.match(r"^\s*n\d+:", line):
        cur["tree"].append(line.rstrip())
snaps = [s for s in snaps if s["detailed"] and s["tree"]]
if not snaps:
    print("  no detailed snapshots found"); sys.exit()
first, last = snaps[0], snaps[-1]
print(f"  snapshots: {len(snaps)}   first at t={first['time']} ({first['mem']/1048576:.1f} MB)   last at t={last['time']} ({last['mem']/1048576:.1f} MB)")
print(f"  heap delta over the window: {(last['mem']-first['mem'])/1048576:+.1f} MB")
print()
print("  last detailed snapshot, biggest branches:")
for row in last["tree"][:14]:
    m = re.match(r"^(\s*)n\d+: (\d+) \(([\d.]+)%\) (.*)$", row)
    if not m:
        continue
    depth, b, pct, label = len(m.group(1)), int(m.group(2)), m.group(3), m.group(4)
    if b < 100_000:
        continue
    print(f"    {'  '*min(depth,6)}{b/1048576:6.2f} MB ({pct}%)  {label[:110]}")
PY
echo
echo "full report: ms_print $OUT | less"
