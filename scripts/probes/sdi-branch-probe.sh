#!/usr/bin/env bash
# Reproduce the engine's SDI branch from a FILE, with the DeckLink sink replaced by fakesink.
#
# Why a file: the branch is what is under test, not the network. A 20 s 1080i50 TS looped by
# multifilesrc feeds it far faster than real time, so a leak that is per-frame shows up in minutes
# instead of hours. Nothing here touches a DeckLink device or a live route.
#
# The branch mirrors native/rust/engine-gst/src/builder.rs add_sdi_sink():
#   queue2 use-buffering=false max-size-buffers=0 max-size-bytes=0 max-size-time=5s
#   ! tsdemux ! decodebin ! queue 5s ! videoconvert ! videorate skip-to-first=true ! videoscale
#   ! capsfilter UYVY 1920x1080 25/1 ! identity(sync) ! decklinkvideosink   <- replaced by fakesink
#
# Usage: bash sdi-branch-probe.sh [seconds] [sync|nosync]
#   sync   = identity sync=true  (engine's setting; paces to real time)
#   nosync = identity sync=false (max throughput; leak per buffer shows fastest)
set -uo pipefail
DURATION="${1:-900}"
SYNC_MODE="${2:-nosync}"
TS="${TS:-/home/blackgate/.hermes/cache/scratch/int1080i-v.ts}"
LOG="${LOG:-/home/blackgate/blackgate-trend/valgrind/sdi-branch.log}"
[ -f "$TS" ] || { echo "FAIL: no TS file at $TS"; exit 2; }
if [ "$SYNC_MODE" = "sync" ]; then SYNCTAG="true"; else SYNCTAG="false"; fi

echo "branch: multifilesrc(loop) ! tsdemux ! queue2(5s) ! decodebin ! queue(5s) ! videoconvert !"
echo "        videorate ! videoscale ! capsfilter(UYVY) ! identity(sync=$SYNCTAG) ! fakesink"
echo "source: $TS (looped, as fast as the branch accepts)"
echo "run:    ${DURATION}s   log: $LOG"

# Optional isolated prefix: GST_PREFIX=/home/blackgate/gst126/root runs the same branch on the newer GStreamer
# without touching the system packages the live routes use. The registry is deleted because a registry built
# while plugins were still unresolvable keeps reporting them as missing.
GSTBIN="gst-launch-1.0"
if [ -n "${GST_PREFIX:-}" ]; then
  export LD_LIBRARY_PATH="$GST_PREFIX/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export GST_PLUGIN_SYSTEM_PATH="$GST_PREFIX/usr/lib/x86_64-linux-gnu/gstreamer-1.0"
  export GST_PLUGIN_SYSTEM_PATH_1_0="$GST_PLUGIN_SYSTEM_PATH"
  export GST_REGISTRY="/home/blackgate/.hermes/cache/scratch/registry-sdi-prefix.bin"
  export GST_REGISTRY_1_0=$GST_REGISTRY
  rm -f "$GST_REGISTRY"
  GSTBIN="$GST_PREFIX/usr/bin/gst-launch-1.0"
  LOG="/home/blackgate/blackgate-trend/valgrind/sdi-branch-126.log"
  echo "library: GStreamer dari prefix $GST_PREFIX ($("$GSTBIN" --version 2>/dev/null | head -1))"
fi

trap 'kill ${GPID:-} 2>/dev/null' EXIT INT TERM
# video-only TS: with audio in the file tsdemux exposes a second pad that gst-launch cannot route, and
# "delayed linking failed" leaves the branch stalled (cpu 0%, which would read as a flat RSS).
# Pinned to a few cores: the live routes decode on this same box and must not lose CPU to a probe.
CPUS="${CPUS:-4-6}"
taskset -c "$CPUS" "$GSTBIN" -e -q \
  multifilesrc location="$TS" loop=true caps="video/mpegts" \
  ! tsdemux \
  ! queue2 use-buffering=false max-size-buffers=0 max-size-bytes=0 max-size-time=5000000000 \
     ! h264parse ! avdec_h264 \
     ! queue max-size-time=5000000000 \
     ! videoconvert \
     ! videorate skip-to-first=true \
     ! videoscale \
     ! capsfilter caps="video/x-raw,format=UYVY,width=1920,height=1080,framerate=25/1" \
     ! identity sync=$SYNCTAG \
     ! fakesink sync=false \
  >"$LOG" 2>&1 &
GPID=$!
CLK=$(getconf CLK_TCK)

sleep 15
kill -0 "$GPID" 2>/dev/null || { echo "FAIL: pipeline died at startup:"; tail -5 "$LOG"; exit 3; }

FIRST=""; LASTCT=""; DONE=0
ENDATS=$(( $(date +%s) + DURATION ))
while [ "$DONE" -lt "$DURATION" ]; do
  kill -0 "$GPID" 2>/dev/null || { echo "  pipeline exited early:"; tail -3 "$LOG"; break; }
  rss=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status" 2>/dev/null)
  ct=$(awk '{print $14+$15}' "/proc/$GPID/stat" 2>/dev/null)
  [ -z "$FIRST" ] && FIRST="$rss"
  cpu=$(( (${ct:-0} - ${LASTCT:-${ct:-0}}) * 100 / 30 / CLK ))
  LASTCT=${ct:-0}
  printf '  t=%-5s rss=%-4s MB  cpu=%s%%\n' "${DONE}s" "${rss:-?}" "$cpu"
  sleep 30; DONE=$(( DONE + 30 ))
  [ "$(date +%s)" -ge "$ENDATS" ] && break
done
LAST=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status" 2>/dev/null)
echo
echo "RESULT  first=$FIRST MB  last=${LAST:-?} MB  delta=$(( ${LAST:-0} - ${FIRST:-0} )) MB over ${DONE}s"
echo "  flat + cpu~0%   => branch tidak memproses apa pun; ukuran tidak sah"
echo "  flat + cpu>50%  => cabang milik kita bersih; kebocoran ada di plugin DeckLink"
echo "  growing         => kebocoran di cabang kita; jalankan valgrind bentuk ini"
