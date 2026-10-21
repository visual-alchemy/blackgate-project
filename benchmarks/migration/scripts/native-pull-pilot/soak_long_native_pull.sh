#!/usr/bin/env bash
# Soak panjang (gate sebenarnya). Jalankan: HLS_MIN=60 RTMP_MIN=60 bash soak_long_native_pull.sh
# Aman: port 472xx (di luar rentang sidecar 39000..39999), semua proses pakai timeout,
# pembersihan lewat PID (tidak pernah pkill -f), semua artefak di /tmp.
set -u
W=${W:-/tmp/soak_long}
HLS_MIN=${HLS_MIN:-60}
RTMP_MIN=${RTMP_MIN:-60}
SAMPLE=60
URL="https://cdnw-pull.tvri.go.id/stream/ASEAN_GAMES/playlist.m3u8"
MTX=/tmp/soak/mediamtx
mkdir -p "$W"; cd "$W" || exit 1

sample_loop() { # $1 file  $2 jumlah  $3 out  $4 pgrep
  local f="$1" n="$2" o="$3" p="$4" i
  for i in $(seq 1 "$n"); do
    sleep "$SAMPLE"
    printf '%s %s %s\n' "$(date +%H:%M:%S)" "$(stat -c %s "$f" 2>/dev/null || echo 0)" \
      "$(ps -o rss= -p "$(pgrep -x "$p" | head -1)" 2>/dev/null | tr -d ' ' || echo 0)" >> "$o"
  done
}
report() { # $1 samples  $2 label
  python3 - "$1" "$2" "$SAMPLE" <<'PY'
import sys
rows=[(l.split()[0],int(l.split()[1]),int(l.split()[2]) if len(l.split())>2 else 0) for l in open(sys.argv[1]) if len(l.split())>=2]
if not rows: print(f"  {sys.argv[2]}: TIDAK ADA SAMPEL"); raise SystemExit
d=[rows[i][1]-rows[i-1][1] for i in range(1,len(rows))]
rss=[r[2]/1024 for r in rows if r[2]]
print(f"  {sys.argv[2]}: {len(rows)} sampel @{sys.argv[3]}s, akhir {rows[-1][1]/1048576:.0f} MB")
print(f"    delta terendah {min(d)/1048576:.2f} MB, tertinggi {max(d)/1048576:.2f} MB")
print(f"    JENDELA STALL  {sum(1 for x in d if x<=0)} / {len(d)}")
if rss: print(f"    RSS awal {rss[0]:.1f} MB, akhir {rss[-1]:.1f} MB, puncak {max(rss):.1f} MB")
print(f"    VERDICT: {'LULUS' if not any(x<=0 for x in d) else 'GAGAL (ada stall)'}")
PY
}

echo "=== SOAK PANJANG dimulai $(date +%T): HLS ${HLS_MIN}m + RTMP ${RTMP_MIN}m ==="

# ---------- LEG 1: HLS ----------
echo "--- HLS native, ${HLS_MIN} menit"
timeout $((HLS_MIN*60)) gst-launch-1.0 -q souphttpsrc location="$URL" ! hlsdemux ! tsparse \
  ! filesink location="$W/hls.ts" > "$W/hls.log" 2>&1 &
HLS_PID=$!
sample_loop "$W/hls.ts" "$HLS_MIN" "$W/hls.samples" gst-launch-1.0 & S1=$!
wait "$HLS_PID" 2>/dev/null; kill "$S1" 2>/dev/null
report "$W/hls.samples" "HLS native"
echo "    log: $(tail -c 200 "$W/hls.log" | tr '\n' ' ')"

# ---------- LEG 2: RTMP ----------
echo "--- RTMP native, ${RTMP_MIN} menit"
cat > "$W/mediamtx.yml" <<'YML'
rtsp: false
rtmp: true
rtmpAddress: :1935
hls: false
webrtc: false
srt: false
moq: false
api: false
metrics: false
pprof: false
authMethod: internal
authInternalUsers:
  - user: any
    ips: []
    permissions:
      - action: publish
      - action: read
paths:
  all_others:
YML
if [ -x "$MTX" ]; then
  ("$MTX" > "$W/mtx.log" 2>&1 &)
  sleep 4
  timeout $((RTMP_MIN*60+120)) ffmpeg -hide_banner -loglevel warning -re \
    -f lavfi -i testsrc2=size=1280x720:rate=25 -f lavfi -i sine=frequency=1000 \
    -t $((RTMP_MIN*60)) -c:v libx264 -preset ultrafast -g 50 -b:v 2500k -c:a aac \
    -f flv "rtmp://127.0.0.1:1935/live/soak" > "$W/pub.log" 2>&1 &
  PUB_PID=$!
  sleep 7
  timeout $((RTMP_MIN*60)) gst-launch-1.0 -q rtmp2src location="rtmp://127.0.0.1:1935/live/soak" \
    ! flvdemux name=d d. ! queue ! h264parse ! mpegtsmux name=m ! filesink location="$W/rtmp.ts" \
    d. ! queue ! aacparse ! m. > "$W/rtmp.log" 2>&1 &
  RTMP_PID=$!
  sample_loop "$W/rtmp.ts" "$RTMP_MIN" "$W/rtmp.samples" gst-launch-1.0 & S2=$!
  wait "$RTMP_PID" 2>/dev/null; kill "$S2" 2>/dev/null
  report "$W/rtmp.samples" "RTMP native"
  echo "    log: $(tail -c 200 "$W/rtmp.log" | tr '\n' ' ')"
  kill "$PUB_PID" 2>/dev/null
  for p in $(pgrep -x mediamtx); do kill "$p" 2>/dev/null; done
else
  echo "  mediamtx tidak ada di $MTX — leg RTMP dilewati (jujur, bukan disamarkan)"
fi

echo "=== SOAK PANJANG selesai $(date +%T) ==="
ls -la "$W" | tail -8
