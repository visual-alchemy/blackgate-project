#!/usr/bin/env bash
# Realtime, monotonic-timestamp decode on the CPU only — the same shape as a live route.
#
# Why this exists: the file-loop probe grows ~10 MB/min, a live route grows ~0,78 MB/min. Both decode with
# libav, so the 13x gap has to come from something the loop does differently. The obvious candidate is the
# timestamp: a 20 s file on loop restarts its PTS every 20 s, and a decoder that keys queues on PTS behaves
# nothing like that in a real feed. Here ffmpeg encodes a synthetic 1080i50 and sends it over SRT at real
# time (monotonic PTS, exactly like a broadcaster), and the receiver decodes with avdec_h264 on plain CPU.
#
# No GPU anywhere in this chain, which is the constraint the product has to satisfy.
#
# Usage: bash realtime-avdec.sh [seconds]
set -uo pipefail
DURATION="${1:-900}"
PORT="${PORT:-19881}"
CPUS="${CPUS:-4-6}"
WORK="${WORK:-/home/blackgate/.hermes/cache/scratch}"
LOG="$WORK/realtime-avdec.log"

# Optional isolated prefix: GST_PREFIX=/home/blackgate/gst126/root runs the newer GStreamer without touching
# any system package. Everything (plugins, glib, ffmpeg libs) is resolved from the prefix first.
GSTBIN="gst-launch-1.0"
if [ -n "${GST_PREFIX:-}" ]; then
  export LD_LIBRARY_PATH="$GST_PREFIX/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export GST_PLUGIN_SYSTEM_PATH="$GST_PREFIX/usr/lib/x86_64-linux-gnu/gstreamer-1.0"
  export GST_PLUGIN_SYSTEM_PATH_1_0="$GST_PLUGIN_SYSTEM_PATH"
  export GST_REGISTRY="$WORK/registry-prefix.bin"
  export GST_REGISTRY_1_0="$GST_REGISTRY"
  GSTBIN="$GST_PREFIX/usr/bin/gst-launch-1.0"
  LOG="$WORK/realtime-avdec-prefix.log"
fi

echo "feed: ffmpeg libx264 1080i50 -> srt://127.0.0.1:$PORT (realtime, monotonic PTS)"
echo "rx:   srtsrc ! tsdemux ! h264parse ! avdec_h264 ! fakesink   (cpu cores $CPUS)"
echo "bin:  $GSTBIN  ($("$GSTBIN" --version 2>/dev/null | head -1))"
echo "run:  ${DURATION}s"
: >"$LOG"

trap 'kill ${FEED:-} ${RX:-} 2>/dev/null' EXIT INT TERM
ffmpeg -hide_banner -loglevel error -re \
  -f lavfi -i "testsrc2=size=1920x1080:rate=25" -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
  -vf "interlace=scan=tff:lowpass=1" -flags +ilme+ildct -top 1 \
  -c:v libx264 -preset ultrafast -tune zerolatency -b:v 9000k -g 50 \
  -c:a aac -b:a 128k -f mpegts "srt://127.0.0.1:$PORT?mode=listener&latency=200" >>"$LOG" 2>&1 &
FEED=$!
sleep 8

taskset -c "$CPUS" "$GSTBIN" -e -q \
  srtsrc uri="srt://127.0.0.1:$PORT?mode=caller&latency=200" ! tsdemux ! h264parse ! avdec_h264 \
  ! fakesink sync=false >>"$LOG" 2>&1 &
RX=$!
sleep 15
kill -0 "$RX" 2>/dev/null || { echo "FAIL: receiver mati di awal"; tail -5 "$LOG"; exit 3; }

r0=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$RX/status")
echo "  awal: rss=${r0} MB"
t=0
while [ "$t" -lt "$DURATION" ]; do
  kill -0 "$RX" 2>/dev/null || break
  sleep 60; t=$(( t + 60 ))
  r=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$RX/status" 2>/dev/null)
  c=$(awk '/^cpu /{print 100-($5*100/($2+$3+$4+$5+$6+$7+$8))}' /proc/stat)
  printf '  t=%-5s rss=%-6s MB  host_idle=%s%%\n' "${t}s" "${r:-?}" "${c%%.*}"
done

rN=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$RX/status" 2>/dev/null)
echo
printf 'HASIL: %s -> %s MB  (%+d in %ss)  = %.2f MB/menit\n' "$r0" "${rN:-?}" "$(( ${rN:-0} - r0 ))" "$DURATION" \
  "$(awk -v d=$(( ${rN:-0} - r0 )) -v p="$DURATION" 'BEGIN{printf "%.2f", d/(p/60)}')"
echo
echo "pembanding: file-loop 20 s (PTS berulang) = 10,7 MB/menit; route live = 0,78 MB/menit"
echo "kalau di sini <= ~1 MB/menit, loop PTS-lah yang memperbesar gejalanya dan laju asli live yang jadi patokan."
echo
echo "=== error di log (kosong = bersih) ==="
grep -aiE "error|not-negotiated|failed|warning" "$LOG" | tail -5 | cut -c1-140 | sed 's/^/  /'
kill "$RX" "$FEED" 2>/dev/null
