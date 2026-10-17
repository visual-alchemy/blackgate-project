#!/usr/bin/env bash
# Run ONE engine standalone against the exact init JSON and print its peak RSS.
#
# Use it to price an optional pipeline branch (preview/thumbnail, an extra sink, a parser)
# or to compare memory between a port and its reference WITHOUT a full harness run and
# without stopping a live release. Repeat with the branch toggled and compare VmHWM.
#
#   ENGINE=./native/build/blackgate-engine \
#   INIT_JSON='{"type":"init","route_id":"probe","preview":true,"source":{...},"sinks":[...]}' \
#   LABEL='preview on' scripts/probe_engine_rss.sh
#
# Vars (all overridable):
#   ENGINE        engine binary to run                (default ./native/build/blackgate-engine)
#   INIT_JSON     the init line the control plane sent (COPY IT VERBATIM from the log or the
#                 harness's run evidence; a hand-rebuilt JSON omits the field that matters)
#   LABEL         name printed with the measurement
#   STATS_SOCK    path for a dummy stats listener     (default /tmp/probe_engine_stats.sock)
#   STATS_ENV     env var the engine READS for it     (default BLACKGATE_STATS_SOCKET)
#   ROUTE_ID      argv[1]                             (default taken from INIT_JSON's route_id)
#   FEED_CMD      shell command that feeds the source (default: a 9 Mbps 1080p25 H.264/AAC
#                 MPEG-TS pattern over UDP to the port in INIT_JSON)
#   MEASURE_SECS  how long to sample before reading   (default 45)
#
# Two traps this script exists to avoid, both of which make a probe measure nothing:
#   1. stdin EOF is a SHUTDOWN REQUEST for this engine, so the JSON must come from a
#      producer that stays alive -- a heredoc or `<<<` closes stdin immediately and the
#      engine exits with `stdin closed (cond=0x10), shutting down pipeline`.
#   2. the engine exits if it cannot reach the stats socket, so a dummy listener must own
#      the path before it starts (and it must be its OWN path, never a live release's).
set -u

ENGINE="${ENGINE:-./native/build/blackgate-engine}"
STATS_SOCK="${STATS_SOCK:-/tmp/probe_engine_stats.sock}"
STATS_ENV="${STATS_ENV:-BLACKGATE_STATS_SOCKET}"
MEASURE_SECS="${MEASURE_SECS:-45}"
INIT_JSON="${INIT_JSON:?set INIT_JSON to the init line the control plane sent}"
ROUTE_ID="${ROUTE_ID:-$(printf '%s' "$INIT_JSON" | sed -n 's/.*"route_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')}"
LABEL="${LABEL:-probe}"
UDP_PORT="$(printf '%s' "$INIT_JSON" | sed -n 's/.*udp:\/\/[^:]*:\([0-9]*\).*/\1/p')"
UDP_PORT="${UDP_PORT:-60559}"
FEED_CMD="${FEED_CMD:-ffmpeg -hide_banner -loglevel error -re -f lavfi -i testsrc2=size=1920x1080:rate=25 -f lavfi -i sine=frequency=1000:sample_rate=48000 -c:v libx264 -preset ultrafast -tune zerolatency -b:v 9000k -maxrate 9000k -bufsize 18000k -c:a aac -b:a 128k -shortest -f mpegts udp://127.0.0.1:${UDP_PORT}?pkt_size=1316}"

# Bracketed patterns: `pkill -f` matches the shell's OWN command line, so a plain pattern
# terminates the command you are running instead of the probes.
cleanup() {
  pkill -f "$(basename "$ENGINE")[ ]" 2>/dev/null
  pkill -f "probe_engine_stats[.]sock" 2>/dev/null
  pkill -f "udp://127.0.0.1:${UDP_PORT}" 2>/dev/null
}
trap cleanup EXIT
cleanup
rm -f "$STATS_SOCK"

# Dummy stats listener: the engine connects on startup and exits if nothing answers.
python3 - "$STATS_SOCK" <<'PY' &
import socket, sys, threading
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
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

bash -c "$FEED_CMD" >/dev/null 2>&1 &
sleep 3

# Keep stdin OPEN for the whole measurement.
{ printf '%s\n' "$INIT_JSON"; sleep "$((MEASURE_SECS + 30))"; } | \
  env "$STATS_ENV=$STATS_SOCK" "$ENGINE" "$ROUTE_ID" >"/tmp/probe-${LABEL// /_}.log" 2>&1 &
PID=$!
sleep "$MEASURE_SECS"

if kill -0 "$PID" 2>/dev/null; then
  awk -v l="$LABEL" '/VmHWM/{h=$2/1024} /VmRSS/{r=$2/1024} END{printf "%-22s VmHWM=%.1f MB   VmRSS=%.1f MB\n", l, h, r}' "/proc/$PID/status"
else
  printf '%-22s DIED -- see /tmp/probe-%s.log\n' "$LABEL" "${LABEL// /_}"
  tail -3 "/tmp/probe-${LABEL// /_}.log" | sed 's/^/    /'
fi
kill -9 "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
