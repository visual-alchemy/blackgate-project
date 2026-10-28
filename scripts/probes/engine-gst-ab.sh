#!/usr/bin/env bash
# Run the real Blackgate engine against two GStreamer versions and compare its memory behaviour.
#
# Everything from the earlier probes is reused: synthetic SRT feed, engine with preview=true (which builds the
# decode branch, so no DeckLink device is involved), its own stats socket, own ports 19891/19991 — the live
# routes on 16000-20000 and the live stats socket are never touched.
#
# The point of this run is not "does 1.26 exist" but "does our binary, compiled against 1.24 bindings, run on
# 1.26 without breaking and without growing". ABI stability is claimed by GStreamer, not yet proven by us, so
# the resolved library path from /proc/<pid>/maps is printed for each arm: if it does not say gst126, the arm
# proves nothing about 1.26 no matter what the RSS says.
#
# Usage: bash engine-gst-ab.sh [seconds-per-arm]
set -uo pipefail
PER="${1:-1200}"
ROOT="${BLACKGATE_ROOT:-/home/blackgate/blackgate-project}"
ENGINE="$ROOT/native/build/blackgate-engine"
WORK="${WORK:-/home/blackgate/.hermes/cache/scratch/engine-ab}"
FEED_PORT=19891
SINK_PORT=19991
CPUS="${CPUS:-0-2}"
OUT="$WORK/engine-ab-$(date -u +%H%M%S).log"
mkdir -p "$WORK"

[ -x "$ENGINE" ] || { echo "FAIL: engine tidak ada di $ENGINE"; exit 2; }
echo "engine: $ENGINE  sha256=$(sha256sum "$ENGINE" | cut -c1-16)"
echo "feed :19891  sink :19991  cores $CPUS  ${PER}s per arm"

start_feed() {
  ffmpeg -hide_banner -loglevel error -re \
    -f lavfi -i "testsrc2=size=1920x1080:rate=25" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
    -vf "interlace=scan=tff:lowpass=1" -flags +ilme+ildct -top 1 \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 9000k -g 50 \
    -c:a aac -b:a 128k -shortest \
    -f mpegts "srt://127.0.0.1:$FEED_PORT?mode=listener&latency=2000" >"$WORK/feed.log" 2>&1 &
  FEED=$!
}
start_receiver() {
  ffmpeg -hide_banner -loglevel error -i "srt://127.0.0.1:$SINK_PORT?mode=caller&latency=2000" \
    -c copy -f null - -progress "$WORK/recv.progress" -nostats >"$WORK/recv.log" 2>&1 &
  RECV=$!
}

run_arm() {  # $1 = label, $2 = gst prefix (empty = system libraries)
  local label="$1" prefix="$2" init pid r0 rN t=0
  echo
  echo "=== ARM $label  (prefix: ${prefix:-<system 1.24>}) ==="
  rm -f "$WORK/stats.sock" "$WORK/recv.progress"
  python3 - "$WORK/stats.sock" <<'PY' &
import os, socket, sys
p = sys.argv[1]
try: os.unlink(p)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(p); s.listen(4)
while True:
    try: c, _ = s.accept()
    except OSError: break
    try:
        while c.recv(65536): pass
    except OSError: pass
    c.close()
PY
  local SOCKPID=$!
  for _ in $(seq 1 40); do [ -S "$WORK/stats.sock" ] && break; sleep 0.1; done

  start_feed
  sleep 3
  start_receiver
  sleep 1
  init=$(cat <<JSON
{"route_id":"probe-$label","preview":true,"source":{"type":"srtsrc","uri":"srt://127.0.0.1:$FEED_PORT?latency=2000&mode=caller"},"sinks":[{"type":"srtsink","latency":2000,"uri":"srt://0.0.0.0:$SINK_PORT?latency=2000&mode=listener"}]}
JSON
)
  if [ -n "$prefix" ]; then
    ( printf '%s\n' "$init"; sleep $(( PER + 120 )) ) | \
      LD_LIBRARY_PATH="$prefix/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      GST_PLUGIN_SYSTEM_PATH="$prefix/usr/lib/x86_64-linux-gnu/gstreamer-1.0" \
      GST_PLUGIN_SYSTEM_PATH_1_0="$prefix/usr/lib/x86_64-linux-gnu/gstreamer-1.0" \
      GST_REGISTRY="$WORK/registry-$label.bin" GST_REGISTRY_1_0="$WORK/registry-$label.bin" \
      BLACKGATE_STATS_SOCKET="$WORK/stats.sock" \
      taskset -c "$CPUS" "$ENGINE" "probe-$label" >"$WORK/engine-$label.log" 2>&1 &
  else
    ( printf '%s\n' "$init"; sleep $(( PER + 120 )) ) | \
      BLACKGATE_STATS_SOCKET="$WORK/stats.sock" \
      taskset -c "$CPUS" "$ENGINE" "probe-$label" >"$WORK/engine-$label.log" 2>&1 &
  fi
  ENG=$!

  sleep 20
  pid=$(pgrep -f "blackgate-engine probe-$label" -n 2>/dev/null | head -1)
  if [ -z "${pid:-}" ]; then
    echo "  DEAD: $(tail -3 "$WORK/engine-$label.log" | tr '\n' ' ' | cut -c1-160)"
    kill "$FEED" "$RECV" "$SOCKPID" 2>/dev/null
    return 3
  fi

  # proof of life
  local dec valid tval
  dec=$(grep -acE "Branch ready|avdec_h264" "$WORK/engine-$label.log")
  valid=$(grep -ac "SOURCE_VALID" "$WORK/engine-$label.log")
  tval=$(grep -a "^out_time_us=" "$WORK/recv.progress" 2>/dev/null | tail -1 | cut -d= -f2); tval=${tval:-0}
  printf '  decode-branch=%s  SOURCE_VALID=%s  receiver=%ss\n' "$dec" "$valid" $(( tval / 1000000 ))
  echo -n "  libgstreamer dipakai: "
  grep -aoE "/[^ ]*libgstreamer-1\.0\.so\.0\.[0-9.]+" "/proc/$pid/maps" 2>/dev/null | head -1 | sed 's|.*/|  |' || echo "tidak terbaca"
  grep -aoE "libgst126|gst126[^ ]*libgstreamer" "/proc/$pid/maps" 2>/dev/null | head -1 | grep -q . && echo "  (prefix 1.26 terpakai)"

  r0=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$pid/status")
  echo "  awal: ${r0} MB"
  while [ "$t" -lt "$PER" ]; do
    kill -0 "$pid" 2>/dev/null || { echo "  engine mati di t=${t}s"; break; }
    sleep 60; t=$(( t + 60 ))
    rN=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$pid/status" 2>/dev/null)
    printf '    t=%-5s %s MB\n' "${t}s" "${rN:-?}"
  done
  kill "$ENG" "$FEED" "$RECV" "$SOCKPID" 2>/dev/null; sleep 2; kill -9 "$ENG" "$FEED" "$RECV" 2>/dev/null
  printf '  HASIL %s: %s -> %s MB  (%+d)  = %.2f MB/jam\n' "$label" "$r0" "${rN:-?}" \
    "$(( ${rN:-0} - r0 ))" "$(awk -v d=$(( ${rN:-0} - r0 )) -v p="$PER" 'BEGIN{printf "%.2f", d*3600/p}')"
  echo "$label prefix=${prefix:-system} rss0=$r0 rssN=${rN:-?} delta=$(( ${rN:-0} - r0 )) per=$PER" >>"$OUT"
}

run_arm "gst126" "/home/blackgate/gst126/root"
run_arm "gst124" ""

echo
echo "=== ringkasan ($OUT) ==="
sed 's/^/  /' "$OUT"
echo
echo "pembanding live (1.24): 3 engine decode+SDI naik ±47 MB/jam, engine tanpa decode mendatar di 98 MB"
