#!/usr/bin/env bash
# Standalone RSS probe for the udp-to-srt workload config.
# Runs each engine with the exact init JSON the benchmark used, measures VmHWM,
# and repeats for the Rust engine with the thumbnail branch disabled.
set -u
cd /home/dvls/blackgate-project
export PATH="$HOME/.blackgate/toolchain/bin:$PATH"

PROBE_SOCK=/tmp/blackgate_probe_stats.sock
UDP_PORT=60559
SRT_PORT=47251
DEFAULT_INIT='{"type":"init","route_id":"bench-udp-to-srt","primary_source":{"type":"udpsrc","uri":"udp://127.0.0.1:60559"},"auto_join":true,"sinks":[{"type":"srtsink","uri":"srt://127.0.0.1:47251?mode=caller&latency=120"}]}'
INIT="${PROBE_INIT:-$DEFAULT_INIT}"

cleanup() {
  pkill -f 'blackgate-engin[e] bench-udp-to-srt' 2>/dev/null
  pkill -f 'blackgate_pipelin[e] bench-udp-to-srt' 2>/dev/null
  pkill -f 'blackgate_probe_stats' 2>/dev/null
  pkill -f "ffmpeg.*udp://127.0.0.1:$UDP_PORT" 2>/dev/null
}
trap cleanup EXIT

cleanup
rm -f "$PROBE_SOCK"

# dummy stats listener so the engine's connect() succeeds
python3 - "$PROBE_SOCK" <<'PY' &
import os, socket, sys, threading
path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(8)
def drain(c):
    try:
        while c.recv(65536):
            pass
    except OSError:
        pass
while True:
    c, _ = s.accept()
    threading.Thread(target=drain, args=(c,), daemon=True).start()
PY
sleep 1

# source feed: ~9 Mbps H.264 in MPEG-TS over UDP, matching the workload's profile
ffmpeg -hide_banner -loglevel error -re \
  -f lavfi -i "testsrc2=size=1920x1080:rate=25" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
  -c:v libx264 -preset ultrafast -tune zerolatency -b:v 9000k -maxrate 9000k -bufsize 18000k \
  -c:a aac -b:a 128k -shortest \
  -f mpegts "udp://127.0.0.1:$UDP_PORT?pkt_size=1316" >/dev/null 2>&1 &
FFMPEG=$!
sleep 3

run_engine() { # $1 label  $2 binary  $3 "thumb"|"nothumb"
  local label="$1" bin="$2" mode="$3"
  local env_extra=()
  if [ "$mode" = "nothumb" ]; then env_extra=(BLACKGATE_NO_THUMBNAIL=1); fi
  # stdin must stay open: the engine treats EOF as a shutdown request
  { echo "$INIT"; sleep 90; } | env "${env_extra[@]}" BLACKGATE_STATS_SOCKET="$PROBE_SOCK" \
    "$bin" "$PROBE_SOCK" bench-udp-to-srt >"/tmp/probe-$label.log" 2>&1 &
  local pid=$!
  sleep 45
  if kill -0 "$pid" 2>/dev/null; then
    local hwm rss
    hwm=$(awk '/VmHWM/{printf "%.1f", $2/1024}' /proc/$pid/status 2>/dev/null)
    rss=$(awk '/VmRSS/{printf "%.1f", $2/1024}' /proc/$pid/status 2>/dev/null)
    printf '%-22s VmHWM=%s MB   VmRSS=%s MB\n' "$label" "${hwm:-?}" "${rss:-?}"
  else
    printf '%-22s DIED (lihat /tmp/probe-%s.log)\n' "$label" "$label"
    tail -3 "/tmp/probe-$label.log" | sed 's/^/    /'
  fi
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  sleep 2
}

echo "=== probe RSS: konfigurasi udp-to-srt ==="
run_engine "rust (thumbnail on)"  native/build/blackgate-engine       thumb
run_engine "rust (thumbnail off)" native/build/blackgate-engine       nothumb
run_engine "c    (referensi)"     native/archive/c-engine/build/blackgate_pipeline thumb
echo
echo "=== apakah cabang thumbnail memang jalan? ==="
for f in /tmp/probe-rust*.log; do echo "--- $f"; grep -iE 'thumbnail|Thumbnail' "$f" | head -3; done
kill "$FFMPEG" 2>/dev/null
