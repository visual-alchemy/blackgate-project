#!/usr/bin/env bash
# Does the leak live in OUR elements or in the DeckLink plugin?
#
# The engine's SDI branch is: queue2(5 s, time-limited) ! tsdemux ! decodebin ! queue(5 s) !
# videoconvert ! videorate ! videoscale ! capsfilter(UYVY, interlaced) ! identity(sync) ! decklinkvideosink
#
# This reproduces that branch element for element from a synthetic 1080i50 feed, with the DeckLink sink
# replaced by fakesink -- so every live SDI output stays untouched. If RSS grows here, the retention is
# in the branch we own (queues, tsdemux, decodebin, videorate, the interlace caps) and valgrind can name
# it with no downtime at all. If RSS is flat here, the leak is inside the DeckLink plugin/SDK and only a
# real device will show it.
#
# No H.264 encoder exists in this box's GStreamer, so the feed comes from ffmpeg over SRT (srtsrc), the
# same way a real route takes it.
#
# Usage: bash sdi-shape-probe.sh [seconds]
set -uo pipefail
DURATION="${1:-1200}"
PORT="${PORT:-19861}"
WORK="${WORK:-/home/blackgate/blackgate-trend/valgrind}"
LOG="$WORK/sdi-shape.log"
mkdir -p "$WORK"

command -v gst-launch-1.0 >/dev/null || { echo "FAIL: gst-launch-1.0 not found"; exit 2; }
command -v ffmpeg >/dev/null || { echo "FAIL: ffmpeg not found"; exit 2; }
ss -lun 2>/dev/null | awk -v p=":$PORT" '$4 ~ p "$"' | grep -q . && { echo "FAIL: port $PORT busy"; exit 2; }
rm -f "$LOG"

echo "branch: queue2(5s) ! tsdemux ! decodebin ! queue(5s) ! videoconvert ! videorate ! videoscale !"
echo "        capsfilter(UYVY) ! identity(sync) ! fakesink      [DeckLink sink REPLACED by fakesink]"
echo "feed:   synthetic 1080i50 H.264 in MPEG-TS, 9 Mbps, realtime, over SRT to port $PORT"
echo "run:    ${DURATION}s"

trap 'kill ${GPID:-} ${FPID:-} 2>/dev/null' EXIT INT TERM
ffmpeg -hide_banner -loglevel error -re \
  -f lavfi -i "testsrc2=size=1920x1080:rate=25" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
  -vf "interlace=scan=tff:lowpass=1" -flags +ilme+ildct -top 1 \
  -c:v libx264 -preset ultrafast -tune zerolatency -b:v 9000k -g 50 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -shortest \
  -f mpegts "srt://127.0.0.1:$PORT?mode=listener&latency=2000" >"$WORK/sdi-shape-feed.log" 2>&1 &
FPID=$!
sleep 2

gst-launch-1.0 -e -q \
  srtsrc uri="srt://127.0.0.1:$PORT?mode=caller&latency=2000" \
  ! video/mpegts ! tsdemux name=demux \
  demux. ! queue ! fakesink sync=false \
  demux. ! queue2 use-buffering=false max-size-buffers=0 max-size-bytes=0 max-size-time=5000000000 \
     ! decodebin \
     ! queue max-size-time=5000000000 \
     ! videoconvert \
     ! videorate skip-to-first=true \
     ! videoscale \
     ! capsfilter caps="video/x-raw,format=UYVY,width=1920,height=1080,framerate=25/1" \
     ! identity sync=true \
     ! fakesink sync=false \
  >"$LOG" 2>&1 &
GPID=$!
echo "gst-launch pid $GPID   feed pid $FPID"

sleep 25
if ! kill -0 "$GPID" 2>/dev/null; then
  echo "FAIL: pipeline died at startup; last lines:"
  tail -6 "$LOG"
  exit 3
fi
pushed=$(awk '{print $2}' /proc/$GPID/stat 2>/dev/null)
echo "pipeline running; sampling RSS once a minute"
FIRST=""
ENDATS=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$ENDATS" ]; do
  kill -0 "$GPID" 2>/dev/null || { echo "  pipeline exited early"; break; }
  rss=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status" 2>/dev/null)
  [ -z "${FIRST:-}" ] && FIRST="$rss"
  # CPU tells a real working branch from a stalled one: 1080i50 decode into UYVY costs about a core,
  # a stalled branch costs nothing and would read as a flat RSS for the wrong reason.
  ct=$(awk '{print $14+$15}' /proc/$GPID/stat 2>/dev/null)
  cpu=$(( (${ct:-0} - ${LASTCT:-${ct:-0}}) * 100 / 60 / $(getconf CLK_TCK) ))
  LASTCT=${ct:-0}
  printf '  %s  rss=%s MB  cpu=%s%%\n' "$(date -u +%H:%M:%SZ)" "${rss:-?}" "$cpu"
  sleep 60
done
LAST=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status" 2>/dev/null)
echo
echo "first=$FIRST MB  last=${LAST:-?} MB  over ${DURATION}s"
echo "flat (~0-5 MB)  => the branch we own is not the leak; it is the DeckLink sink/plugin"
echo "growing         => the leak is in our branch; valgrind this shape and read the stacks"
