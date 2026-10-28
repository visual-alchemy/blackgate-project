#!/usr/bin/env bash
# A/B probe: does the engine's memory grow because it DECODES, or because of something else?
#
# Two identical engines, each with its own synthetic feed, one difference only:
#   arm A  preview=true    -> the engine builds its thumbnail/decode branch (avdec_h264)
#   arm B  preview=false   -> no decode anywhere in the pipeline
#
# Each arm is a complete chain, like a real route: ffmpeg sender -> engine -> SRT listener -> ffmpeg
# receiver. Neither arm touches the DeckLink card, the live routes, the live stats socket, or the live
# ports (16000/17000/18000/19000/20000).
#
# One sender per arm on purpose: an ffmpeg SRT listener serves ONE caller, so a shared feed starves the
# second arm and the A/B measures nothing (caught in the smoke run - arm B sat in "Connection timeout"
# while arm A held the single connection).
#
# Output: one CSV row per sample per arm (rss_mb, vmdata_mb, threads, fds), an engine log per arm, and a
# progress file per receiver so "the arm was actually streaming" is checked, not assumed.
# Usage:  bash ab_decode_probe.sh [seconds] [interval_s]
# Defaults: 5400 s (90 min), sample every 60 s. A 240 s run is enough to prove the harness end to end.
set -uo pipefail

SECONDS_TO_RUN="${1:-5400}"
INTERVAL="${2:-60}"
ROOT="${BLACKGATE_ROOT:-/home/blackgate/blackgate-project}"
ENGINE="$ROOT/native/build/blackgate-engine"
WORK="${WORK:-/home/blackgate/.hermes/cache/scratch/ab-probe}"
FEED_A=19801
FEED_B=19802
SINK_A=19902
SINK_B=19904
SOCK_A="$WORK/stats-a.sock"
SOCK_B="$WORK/stats-b.sock"

mkdir -p "$WORK"
rm -f "$SOCK_A" "$SOCK_B"
CSV="$WORK/ab-$(date +%Y%m%d-%H%M%S).csv"
echo "ts,arm,pid,rss_mb,vmdata_mb,threads,fds" >"$CSV"

[ -x "$ENGINE" ] || { echo "FAIL: engine binary missing at $ENGINE (run: make -C native)"; exit 2; }
command -v ffmpeg >/dev/null || { echo "FAIL: ffmpeg not on PATH"; exit 2; }
echo "engine: $ENGINE  sha256=$(sha256sum "$ENGINE" | cut -c1-16)"
echo "csv:    $CSV"
echo "run:    ${SECONDS_TO_RUN}s, sample every ${INTERVAL}s"

PIDS=()
cleanup() {
  echo
  echo "--- cleanup ---"
  for pid in "${PIDS[@]:-}"; do [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null; done
  sleep 1
  for pid in "${PIDS[@]:-}"; do [ -n "${pid:-}" ] && kill -9 "$pid" 2>/dev/null; done
  rm -f "$SOCK_A" "$SOCK_B"
  echo "done"
}
trap cleanup EXIT INT TERM

start_stats_listener() {
  local path="$1"
  python3 - "$path" <<'PY' &
import os, socket, sys
path = sys.argv[1]
try: os.unlink(path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path); s.listen(8)
while True:
    try:
        conn, _ = s.accept()
    except OSError:
        break
    while True:
        try:
            if not conn.recv(65536):
                break
        except OSError:
            break
    conn.close()
PY
  PIDS+=($!)
  for _ in $(seq 1 50); do [ -S "$path" ] && return 0; sleep 0.1; done
  echo "FAIL: stats socket $path never appeared"; return 1
}

start_feed() {  # $1 = feed port
  ffmpeg -hide_banner -loglevel error -re \
    -f lavfi -i "testsrc2=size=1920x1080:rate=25" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 4000k -g 50 -pix_fmt yuv420p \
    -c:a aac -b:a 128k -shortest \
    -f mpegts "srt://127.0.0.1:$1?mode=listener&latency=2000" \
    >"$WORK/feed-$1.log" 2>&1 &
  PIDS+=($!)
}

start_receiver() {  # $1 = sink port
  ffmpeg -hide_banner -loglevel error -i "srt://127.0.0.1:$1?mode=caller&latency=2000" \
    -c copy -f null - -progress "$WORK/recv-$1.progress" -nostats \
    >"$WORK/receiver-$1.log" 2>&1 &
  PIDS+=($!)
}

start_engine() {  # $1 arm, $2 stats socket, $3 feed port, $4 sink port, $5 preview
  local init
  init=$(cat <<JSON
{"route_id":"probe-$1","preview":$5,"source":{"type":"srtsrc","uri":"srt://127.0.0.1:$3?latency=2000&mode=caller"},"sinks":[{"type":"srtsink","latency":2000,"uri":"srt://0.0.0.0:$4?latency=2000&mode=listener"}]}
JSON
)
  ( printf '%s\n' "$init"; sleep "$SECONDS_TO_RUN" ) | \
    BLACKGATE_STATS_SOCKET="$2" "$ENGINE" "probe-$1" >"$WORK/engine-$1.log" 2>&1 &
  PIDS+=($!)
}

start_stats_listener "$SOCK_A" || exit 2
start_stats_listener "$SOCK_B" || exit 2

echo
echo "arm A: preview=TRUE  (decode branch on)   feed :$FEED_A  sink :$SINK_A"
start_feed "$FEED_A"
echo "arm B: preview=FALSE (no decode anywhere)  feed :$FEED_B  sink :$SINK_B"
start_feed "$FEED_B"
sleep 3
for port in "$SINK_A" "$SINK_B"; do start_receiver "$port"; done
sleep 1
start_engine A "$SOCK_A" "$FEED_A" "$SINK_A" true
start_engine B "$SOCK_B" "$FEED_B" "$SINK_B" false

# --- did each arm actually stream? ----------------------------------------------------------------
echo
echo "waiting 20 s for both chains to flow..."
sleep 20
ok=1
for arm in A B; do
  if [ "$arm" = A ]; then port=$SINK_A; else port=$SINK_B; fi
  dec=$(grep -acE "Branch ready|avdec_h264" "$WORK/engine-$arm.log" 2>/dev/null | head -1)
  valid=$(grep -ac "SOURCE_VALID" "$WORK/engine-$arm.log" 2>/dev/null | head -1)
  t=$(grep -a "^out_time_us=" "$WORK/recv-$port.progress" 2>/dev/null | tail -1 | cut -d= -f2)
  dec=${dec:-0}; valid=${valid:-0}; t=${t:-0}
  printf '  arm %s: decode-branch=%s  SOURCE_VALID=%s  receiver out_time=%s.%ss\n' \
    "$arm" "$dec" "$valid" $(( t/1000000 )) $(( (t%1000000)/100000 ))
  if [ "$arm" = A ] && [ "$dec" -eq 0 ]; then echo "    FAIL arm A: no decode branch"; ok=0; fi
  if [ "$arm" = B ] && [ "$dec" -ne 0 ]; then echo "    FAIL arm B: it decodes too, second variable"; ok=0; fi
  if [ "$valid" -eq 0 ]; then echo "    FAIL arm $arm: source never validated"; ok=0; fi
  if [ "$t" -lt 5000000 ]; then echo "    FAIL arm $arm: receiver got < 5 s of stream"; ok=0; fi
done
if [ "$ok" -ne 1 ]; then echo; echo "HARNESS INVALID - fix before reading any number"; exit 3; fi
echo "harness valid: A decodes, B does not, both arms streaming"

sample_one() {
  local arm="$1" pid="$2" r d t f
  r=$(awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null); r=${r:-0}
  d=$(awk '/VmData/{print $2}' "/proc/$pid/status" 2>/dev/null); d=${d:-0}
  t=$(ls "/proc/$pid/task" 2>/dev/null | wc -l)
  f=$(ls "/proc/$pid/fd" 2>/dev/null | wc -l)
  echo "$(date -u +%FT%TZ),$arm,$pid,$(( r / 1024 )).$(( (r % 1024) * 10 / 1024 )),$(( d / 1024 )).$(( (d % 1024) * 10 / 1024 )),$t,$f" >>"$CSV"
}

echo
END=$(( $(date +%s) + SECONDS_TO_RUN - 25 ))
while [ "$(date +%s)" -lt "$END" ]; do
  line=""
  for arm in A B; do
    pid=$(pgrep -f "blackgate-engine probe-$arm" -n 2>/dev/null | head -1)
    if [ -z "${pid:-}" ]; then line="$line  $arm=GONE"; continue; fi
    sample_one "$arm" "$pid"
    rss=$(tail -1 "$CSV" | cut -d, -f4)
    line="$line  $arm=${rss}MB"
  done
  echo "  $(date -u +%H:%M:%SZ)$line"
  sleep "$INTERVAL"
done

echo
echo "--- result ---"
python3 - "$CSV" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
for arm in ("A", "B"):
    r = [float(x["rss_mb"]) for x in rows if x["arm"] == arm]
    if not r:
        print(f"  arm {arm}: no samples"); continue
    per_h = (r[-1] - r[0]) / max(len(r) - 1, 1) * 60
    print(f"  arm {arm}: n={len(r)}  rss {r[0]:.1f} -> {r[-1]:.1f} MB  delta {r[-1]-r[0]:+.1f} MB  ({per_h:+.1f} MB/h)")
PY
echo "csv:  $CSV"
echo "logs: $WORK/engine-A.log  $WORK/engine-B.log"
