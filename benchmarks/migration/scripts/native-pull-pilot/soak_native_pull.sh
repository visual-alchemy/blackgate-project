#!/usr/bin/env bash
# Soak harness: native HLS pull vs native RTMP pull, looking for stalls/drift.
#
# What "aman" means here (and what this measures):
#   - the output keeps growing in every sampling window (no stall/deadlock),
#   - no errors in the pipeline log,
#   - the pulled TS stays decodable (ffprobe still reports h264/aac at the end).
# Sampling every 30s and reporting the MINIMUM delta is what catches drift: a stream that
# works for two minutes and then stalls shows up as zero-delta windows.
set -u

SOAK=/tmp/soak
URL="https://cdnw-pull.tvri.go.id/stream/ASEAN_GAMES/playlist.m3u8"
HLS_SECONDS=${HLS_SECONDS:-720}     # 12 min
RTMP_SECONDS=${RTMP_SECONDS:-900}   # 15 min
SAMPLE=30

rm -rf "$SOAK"; mkdir -p "$SOAK"
echo "soak dir: $SOAK"

sample_loop() { # $1 file  $2 count  $3 outfile  $4 pgrep pattern
  local file="$1" count="$2" out="$3" pat="$4" i
  for i in $(seq 1 "$count"); do
    sleep "$SAMPLE"
    local sz rss
    sz=$(stat -c %s "$file" 2>/dev/null || echo 0)
    rss=$(ps -o rss= -p "$(pgrep -f "$pat" | head -1)" 2>/dev/null | tr -d ' ')
    printf '%s %s %s\n' "$(date +%H:%M:%S)" "$sz" "${rss:-0}" >> "$out"
  done
}

analyse() { # $1 samples file  $2 label
  python3 - "$1" "$2" <<'PY'
import sys
path, label = sys.argv[1], sys.argv[2]
rows = []
for line in open(path):
    parts = line.split()
    if len(parts) >= 2:
        rows.append((parts[0], int(parts[1]), int(parts[2]) if len(parts) > 2 else 0))
if not rows:
    print(f"{label}: TIDAK ADA SAMPEL"); sys.exit(0)
deltas = [rows[i][1] - rows[i-1][1] for i in range(1, len(rows))]
stalls = [i for i, d in enumerate(deltas, start=1) if d <= 0]
rss_mb = [r[2] / 1024 for r in rows if r[2]]
print(f"=== {label} ===")
print(f"  sampel        : {len(rows)} (interval 30s)")
print(f"  ukuran akhir  : {rows[-1][1]/1048576:.1f} MB")
print(f"  delta per 30s : min={min(deltas)/1048576:.2f} MB  max={max(deltas)/1048576:.2f} MB  rata2={sum(deltas)/len(deltas)/1048576:.2f} MB")
print(f"  jendela STALL : {len(stalls)} dari {len(deltas)}" + (f"  (menit ke-{int(stalls[0]*30/60)})" if stalls else ""))
if rss_mb:
    print(f"  RSS proses    : awal={rss_mb[0]:.1f} MB  akhir={rss_mb[-1]:.1f} MB  puncak={max(rss_mb):.1f} MB")
print(f"  pertumbuhan   : {rows[-1][1]/max(1,rows[-1][2] or 1) and ''}{'stabil' if len(stalls)==0 else 'TIDAK STABIL'}")
PY
}

############################## FASE A — HLS pull native ##############################
echo; echo "########## FASE A: HLS pull native ($((HLS_SECONDS/60)) menit) ##########"
timeout "$HLS_SECONDS" gst-launch-1.0 -q souphttpsrc location="$URL" ! hlsdemux ! tsparse \
  ! filesink location="$SOAK/hls.ts" > "$SOAK/hls.log" 2>&1 &
HLS_PID=$!
sample_loop "$SOAK/hls.ts" $((HLS_SECONDS/SAMPLE)) "$SOAK/hls.samples" 'hlsdemux' &
SAMP_PID=$!
wait "$HLS_PID" 2>/dev/null
kill "$SAMP_PID" 2>/dev/null
analyse "$SOAK/hls.samples" "HLS native (playlist live CDN tvri)"
echo "  log pipeline  : $(tail -c 300 "$SOAK/hls.log" | tr '\n' ' ' | sed 's/  */ /g' | head -c 200)"
echo "  probe akhir   :"; ffprobe -hide_banner -loglevel error \
  -show_entries stream=codec_name,width,height,avg_frame_rate,sample_rate -of default=noprint_wrappers=1 \
  "$SOAK/hls.ts" 2>&1 | head -8 | sed 's/^/    /'

############################## FASE B — RTMP pull native ##############################
echo; echo "########## FASE B: RTMP pull native ($((RTMP_SECONDS/60)) menit) ##########"
echo "-- mengambil server RTMP (mediamtx, binary statis, tanpa sudo, hanya di /tmp)"
TAG=$(curl -s --max-time 25 https://api.github.com/repos/bluenviron/mediamtx/releases/latest \
      | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
echo "   tag terbaru: ${TAG:-TIDAK TERBACA}"
if [ -n "${TAG:-}" ] && curl -fL --max-time 300 -o "$SOAK/mediamtx.tar.gz" \
     "https://github.com/bluenviron/mediamtx/releases/download/$TAG/mediamtx_${TAG}_linux_amd64.tar.gz" 2>&1 | tail -1; then
  tar -xzf "$SOAK/mediamtx.tar.gz" -C "$SOAK" 2>/dev/null
  if [ -x "$SOAK/mediamtx" ]; then
    echo "   mediamtx siap: $("$SOAK/mediamtx" --version 2>&1 | head -1)"
    "$SOAK/mediamtx" > "$SOAK/mtx.log" 2>&1 &
    MTX_PID=$!
    sleep 4
    echo "-- publisher (peran OBS) mendorong ke rtmp://127.0.0.1:1935/soak"
    timeout $((RTMP_SECONDS+60)) ffmpeg -hide_banner -loglevel warning -re \
      -f lavfi -i testsrc2=size=1280x720:rate=25 -f lavfi -i sine=frequency=1000 \
      -t "$RTMP_SECONDS" -c:v libx264 -preset ultrafast -g 50 -b:v 2500k -c:a aac \
      -f flv "rtmp://127.0.0.1:1935/soak" > "$SOAK/pub.log" 2>&1 &
    PUB_PID=$!
    sleep 6
    echo "-- puller native: rtmp2src → tsparse → filesink"
    timeout "$RTMP_SECONDS" gst-launch-1.0 -q rtmp2src location="rtmp://127.0.0.1:1935/soak" \
      ! tsparse ! filesink location="$SOAK/rtmp.ts" > "$SOAK/rtmp.log" 2>&1 &
    R_PID=$!
    sample_loop "$SOAK/rtmp.ts" $((RTMP_SECONDS/SAMPLE)) "$SOAK/rtmp.samples" 'rtmp2src' &
    SAMP2=$!
    wait "$R_PID" 2>/dev/null
    kill "$SAMP2" 2>/dev/null
    analyse "$SOAK/rtmp.samples" "RTMP pull native (rtmp2src ← mediamtx)"
    echo "  log pipeline  : $(tail -c 300 "$SOAK/rtmp.log" | tr '\n' ' ' | sed 's/  */ /g' | head -c 200)"
    echo "  probe akhir   :"; ffprobe -hide_banner -loglevel error \
      -show_entries stream=codec_name,width,height,avg_frame_rate,sample_rate -of default=noprint_wrappers=1 \
      "$SOAK/rtmp.ts" 2>&1 | head -8 | sed 's/^/    /'
    echo "  log publisher : $(tail -c 200 "$SOAK/pub.log" | tr '\n' ' ' | head -c 150)"
    echo "  log mediamtx  : $(grep -icE 'error' "$SOAK/mtx.log") baris error"
    kill "$PUB_PID" "$MTX_PID" 2>/dev/null
  else
    echo "   GAGAL: binary mediamtx tidak terbentuk — fase B dilewati (jujur, bukan disamarkan)"
  fi
else
  echo "   GAGAL mengunduh mediamtx — fase B dilewati (server RTMP tidak tersedia di box ini)"
fi

echo; echo "########## selesai ##########"
ls -la "$SOAK" | tail -8
