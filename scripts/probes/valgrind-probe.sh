#!/usr/bin/env bash
# Heap profile of ONE engine under valgrind: who allocates what, and what is never given back.
#
# Why: RSS grows 35-56 MB/h on every engine that decodes, and every hypothesis so far (decoder, malloc
# arenas, DeckLink driver, dashboard polling) has been ruled out or falsified by measurement. Valgrind
# answers the question those measurements cannot: WHICH allocation site holds the memory. It does that by
# intercepting every malloc/free and, at exit, reporting each unreleased block with the stack that asked
# for it.
#
# Cost: the engine runs 10-30x slower than real time, so this never touches the live routes. One probe
# chain, its own ports (feed 19851, sink 19852), its own stats socket, synthetic feed.
#
# The leak is expected to be a block that is still REACHABLE at exit (a buffer, list or cache that just
# keeps growing), so "still reachable" matters as much as "definitely lost" here. Because those totals
# also carry GLib/GStreamer globals, run it twice at different lengths (e.g. 300 and 900 s) and compare:
# the stacks whose bytes SCALE with runtime are the leak, everything else is startup noise.
#
# Usage:  bash valgrind-probe.sh [seconds] [label]
#         bash valgrind-probe.sh 300 short      # smoke + fast signal
#         bash valgrind-probe.sh 900 long       # the real read
# Then:   bash valgrind-probe.sh --compare short long
set -uo pipefail

WORK="${WORK:-/home/blackgate/blackgate-trend/valgrind}"
ROOT="${BLACKGATE_ROOT:-/home/blackgate/blackgate-project}"
ENGINE="$ROOT/native/build/blackgate-engine"
FEED=19851
SINK=19852
SOCK="$WORK/stats.sock"
mkdir -p "$WORK"

# ---- --compare mode: read two reports and name the stacks that grow with runtime -------------------
if [ "${1:-}" = "--compare" ]; then
  python3 - "$WORK/valgrind-${2:-short}.log" "$WORK/valgrind-${3:-long}.log" <<'PY'
import re, sys
def parse(path):
    recs, cur = [], None
    for line in open(path, errors="replace"):
        m = re.match(r"==\d+== ([\d,]+) bytes in ([\d,]+) blocks are (\w[\w \-]*?) in loss record", line)
        if m:
            cur = {"bytes": int(m.group(1).replace(",", "")),
                   "blocks": int(m.group(2).replace(",", "")),
                   "kind": m.group(3).strip(), "frames": []}
            recs.append(cur); continue
        m = re.match(r"==\d+==\s+(?:at|by) 0x[0-9A-F]+: (.*)", line)
        if m and cur is not None:
            f = m.group(1)
            f = re.sub(r"\s*\([^)]*\)\s*$", "", f)          # drop offsets/line numbers
            if f not in cur["frames"]:
                cur["frames"].append(f)
        elif line.startswith("==\d+==") is False:
            cur = None
    return recs
def key(r):
    return " <- ".join(r["frames"][:4]) or "(no stack)"
def tot(recs):
    d = {}
    for r in recs:
        if r["kind"].lower().startswith(("definitely", "indirectly", "possibly", "still reachable")):
            d[key(r)] = d.get(key(r), 0) + r["bytes"]
    return d
a, b = parse(sys.argv[1]), parse(sys.argv[2])
ta, tb = tot(a), tot(b)
rows = [(tb.get(k, 0) - ta.get(k, 0), tb.get(k, 0), ta.get(k, 0), k) for k in set(ta) | set(tb)]
rows.sort(reverse=True)
print(f"{'GROWTH':>10} {'long':>10} {'short':>10}  stack (first 4 frames)")
for g, lb, sb, k in rows[:15]:
    if g < 200_000:   # under 200 kB of growth is noise at these runtimes
        continue
    print(f"{g/1024:>9.0f}K {lb/1024:>9.0f}K {sb/1024:>9.0f}K  {k}")
print()
print("Stacks near the top are where per-hour memory goes. A stack that grows ~linearly with runtime")
print("IS the leak; identical totals in both runs mean it is startup state, not growth.")
PY
  exit 0
fi

DURATION="${1:-900}"
LABEL="${2:-run}"
LOG="$WORK/valgrind-$LABEL.log"
ECSV="$WORK/engine-$LABEL.log"
trap 'kill ${PIDS[@]:-} 2>/dev/null; rm -f "$SOCK"' EXIT INT TERM

[ -x "$ENGINE" ] || { echo "FAIL: no engine at $ENGINE"; exit 2; }
command -v valgrind >/dev/null || { echo "FAIL: valgrind not installed"; exit 2; }
command -v ffmpeg >/dev/null || { echo "FAIL: ffmpeg not on PATH"; exit 2; }
ss -lun 2>/dev/null | awk '$4 ~ /:(19851|19852)$/' | grep -q . && { echo "FAIL: probe ports busy"; exit 2; }
rm -f "$LOG" "$SOCK"

echo "mode:     ${MODE:-progressive}"
echo "engine:   $ENGINE  sha256=$(sha256sum "$ENGINE" | cut -c1-16)"
echo "valgrind: $(valgrind --version)"
echo "run:      ${DURATION}s under memcheck  (expect ~10-30x slower than real time)"
echo "log:      $LOG"

PIDS=()
python3 - "$SOCK" <<'PY' &
import os, socket, sys
p = sys.argv[1]
try: os.unlink(p)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(p); s.listen(8)
while True:
    try: c, _ = s.accept()
    except OSError: break
    while True:
        try:
            if not c.recv(65536): break
        except OSError: break
    c.close()
PY
PIDS+=($!)

# MODE=interlaced matches the live sources: 1080i50, field-coded H.264 (frame_mbs_only_flag=0), which is
# what the SDI auto-detect path reports as meta_interlaced:1. MODE=progressive is the cheap control.
MODE="${MODE:-progressive}"
if [ "$MODE" = "interlaced" ]; then
  VF=(-vf "interlace=scan=tff:lowpass=1" -flags +ilme+ildct -top 1)
  BR=(-b:v 9000k -maxrate 9000k -bufsize 9000k)
else
  VF=(); BR=(-b:v 6000k)
fi
ffmpeg -hide_banner -loglevel error -re \
  -f lavfi -i "testsrc2=size=1920x1080:rate=25" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
  "${VF[@]}" \
  -c:v libx264 -preset ultrafast -tune zerolatency "${BR[@]}" -g 50 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -shortest \
  -f mpegts "srt://127.0.0.1:$FEED?mode=listener&latency=2000" >"$WORK/feed-$LABEL.log" 2>&1 &
PIDS+=($!)
sleep 3

INIT="{\"route_id\":\"vg-$LABEL\",\"preview\":true,\"source\":{\"type\":\"srtsrc\",\"uri\":\"srt://127.0.0.1:$FEED?latency=2000&mode=caller\"},\"sinks\":[{\"type\":\"srtsink\",\"latency\":2000,\"uri\":\"srt://0.0.0.0:$SINK?latency=2000&mode=listener\"}]}"

# The engine shuts down when its stdin closes, and that clean exit is what makes valgrind write the
# leak report: keep the writer in its own process so it can be ended early.
( printf '%s\n' "$INIT"; sleep "$DURATION" ) | \
  BLACKGATE_STATS_SOCKET="$SOCK" valgrind \
    --tool=memcheck --leak-check=full --show-leak-kinds=all \
    --errors-for-leak-kinds=none --num-callers=30 --undef-value-errors=no \
    --log-file="$LOG" "$ENGINE" "vg-$LABEL" >"$ECSV" 2>&1 &
VPID=$!
PIDS+=($VPID)
WRITER=$(pgrep -f "sleep $DURATION" -n 2>/dev/null | head -1 || true)

# Wait for the engine's sink listener, then connect a receiver. Order matters: an SRT caller that
# arrives before the listener exists fails instantly ("Input/output error") and then nothing consumes
# the sink, the pipeline stalls, and valgrind measures a pipeline that never ran.
for _ in $(seq 1 40); do ss -lun 2>/dev/null | grep -q ":$SINK " && break; sleep 0.5; done
for attempt in 1 2 3 4 5; do
  ffmpeg -hide_banner -loglevel error -i "srt://127.0.0.1:$SINK?mode=caller&latency=2000" \
    -c copy -f null - -progress "$WORK/recv-$LABEL.progress" -nostats \
    >"$WORK/receiver-$LABEL.log" 2>&1 &
  RPID=$!
  sleep 5
  if kill -0 "$RPID" 2>/dev/null; then PIDS+=($RPID); break; fi
  echo "  receiver attempt $attempt failed, retrying"
done

sleep 20
valid=$(grep -ac "SOURCE_VALID" "$ECSV" 2>/dev/null); valid=${valid:-0}
t=$(grep -a "^out_time_us=" "$WORK/recv-$LABEL.progress" 2>/dev/null | tail -1 | cut -d= -f2); t=${t:-0}
echo
echo "harness: SOURCE_VALID=$valid  receiver out_time=$(( ${t:-0} / 1000000 ))s"
if [ "$valid" -eq 0 ] || [ "${t:-0}" -lt 5000000 ]; then
  echo "HARNESS INVALID: the chain is not actually streaming under valgrind -- do not read the report"
fi

# Watch it until the writer ends (stdin closes) or the clock runs out.
END=$(( $(date +%s) + DURATION ))
while kill -0 "$VPID" 2>/dev/null && [ "$(date +%s)" -lt "$END" ]; do
  rss=$(awk '/VmRSS/{print $2}' "/proc/$VPID/status" 2>/dev/null)
  printf '  %s  rss=%s MB\n' "$(date -u +%H:%M:%SZ)" "$(( ${rss:-0} / 1024 ))"
  sleep 60
done

echo
echo "closing stdin so the engine can exit cleanly and valgrind can write its report..."
[ -n "${WRITER:-}" ] && kill "$WRITER" 2>/dev/null
for _ in $(seq 1 24); do kill -0 "$VPID" 2>/dev/null || break; sleep 5; done
if kill -0 "$VPID" 2>/dev/null; then
  echo "  engine still alive after 120 s of teardown -- TERM"
  kill "$VPID" 2>/dev/null; sleep 20
  kill -9 "$VPID" 2>/dev/null
fi

echo
echo "--- leak summary (bytes per kind) ---"
grep -aE "LEAK SUMMARY|definitely lost|indirectly lost|possibly lost|still reachable|suppressed" "$LOG" 2>/dev/null | sed 's/==[0-9]*==/  /' | sed 's/^  *//' | sort -u | head -12

echo
echo "--- top allocation sites by retained bytes ---"
python3 - "$LOG" <<'PY'
import re, sys
recs, cur = [], None
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"==\d+== ([\d,]+) bytes in ([\d,]+) blocks are (\w[\w \-]*?) in loss record", line)
    if m:
        cur = {"b": int(m.group(1).replace(",", "")), "k": m.group(3).strip(), "f": []}
        recs.append(cur); continue
    m = re.match(r"==\d+==\s+(?:at|by) 0x[0-9A-F]+: (.*)", line)
    if m and cur is not None:
        f = re.sub(r"\s*\([^)]*\)\s*$", "", m.group(1))
        if f not in cur["f"]:
            cur["f"].append(f)
recs = [r for r in recs if r["b"] > 0]
recs.sort(key=lambda r: -r["b"])
for r in recs[:12]:
    print(f"  {r['b']/1048576:7.2f} MB  {r['k']:<18} {' <- '.join(r['f'][:5])}")
print(f"\n  ({len(recs)} loss records with bytes; full trace in the log)")
PY
echo
echo "log: $LOG"
echo "next: run a second length and compare --  bash $0 --compare $LABEL <other-label>"
