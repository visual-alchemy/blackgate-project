#!/usr/bin/env bash
# Dua uji lanjutan setelah soak pertama:
#   FASE C: RTMP pull native dengan rantai yang BENAR (rtmp2src keluar FLV, bukan TS)
#   FASE D: TS hasil pull native dimasukkan ke ENGINE sungguhan lewat SRT loopback
#           (ffprobe bukan bukti; sidecar sengaja me-rebase timestamp, native tidak)
set -u

W=/tmp/soak2
HLS_TS=/tmp/soak/hls.ts
MTX=/tmp/soak/mediamtx
RTMP_SECONDS=${RTMP_SECONDS:-480}
SAMPLE=30
rm -rf "$W"; mkdir -p "$W"
cd "$W" || exit 1

echo "########## FASE C: RTMP pull native, rantai benar ##########"
# konfigurasi eksplisit: tanpa ini mediamtx v1.21 memakai config kosong -> "path 'soak' is not configured"
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
paths:
  all_others:
YML
("$MTX" > "$W/mtx.log" 2>&1 &) ; sleep 4
echo "  mediamtx: $(grep -cE 'path .* is not configured' "$W/mtx.log") penolakan path, RTMP $(ss -tln 2>/dev/null | grep -c ':1935') listener"

timeout $((RTMP_SECONDS+90)) ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i testsrc2=size=1280x720:rate=25 -f lavfi -i sine=frequency=1000 \
  -t "$RTMP_SECONDS" -c:v libx264 -preset ultrafast -g 50 -b:v 2500k -c:a aac \
  -f flv "rtmp://127.0.0.1:1935/soak" > "$W/pub.log" 2>&1 &
PUB_PID=$!
sleep 6

# RANTAI BENAR: rtmp2src -> flvdemux -> parse -> mpegtsmux (re-mux, wilayah yang didokumentasikan berisiko)
timeout "$RTMP_SECONDS" gst-launch-1.0 -q \
  rtmp2src location="rtmp://127.0.0.1:1935/soak" ! \
  flvdemux name=d d. ! h264parse ! mpegtsmux name=m ! filesink location="$W/rtmp.ts" \
  d. ! aacparse ! m. > "$W/rtmp.log" 2>&1 &
R_PID=$!
for i in $(seq 1 $((RTMP_SECONDS/SAMPLE))); do
  sleep "$SAMPLE"
  printf '%s %s %s\n' "$(date +%H:%M:%S)" "$(stat -c %s "$W/rtmp.ts" 2>/dev/null || echo 0)" \
    "$(ps -o rss= -p "$(pgrep -x gst-launch-1.0 | head -1)" 2>/dev/null | tr -d ' ' || echo 0)" >> "$W/rtmp.samples"
done &
SAMP=$!
wait "$R_PID" 2>/dev/null; kill "$SAMP" 2>/dev/null

python3 - "$W/rtmp.samples" "RTMP pull native (rantai flvdemux+mpegtsmux)" <<'PY'
import sys
rows=[(l.split()[0],int(l.split()[1]),int(l.split()[2]) if len(l.split())>2 else 0) for l in open(sys.argv[1]) if len(l.split())>=2]
if not rows: print(f"  {sys.argv[2]}: TIDAK ADA SAMPEL"); raise SystemExit
d=[rows[i][1]-rows[i-1][1] for i in range(1,len(rows))]
print(f"  {sys.argv[2]}: {len(rows)} sampel, akhir {rows[-1][1]/1048576:.1f} MB")
print(f"  delta/30s: min={min(d)/1048576:.2f} max={max(d)/1048576:.2f} MB | stall {sum(1 for x in d if x<=0)}/{len(d)}")
print(f"  RSS: awal {rows[0][2]/1024:.1f} akhir {rows[-1][2]/1024:.1f} MB")
PY
echo "  log pipeline: $(tail -c 250 "$W/rtmp.log" | tr '\n' ' ' | head -c 200)"
echo "  probe:"; ffprobe -v error -show_entries stream=codec_name,width,height,avg_frame_rate,sample_rate \
  -of default=noprint_wrappers=1 "$W/rtmp.ts" 2>&1 | head -8 | sed 's/^/    /'
echo "  log publisher: $(tail -c 150 "$W/pub.log" | tr '\n' ' ' | head -c 120)"
# hentikan mediamtx & publisher berdasarkan PID (jangan pernah pkill -f)
pkill -P $$ 2>/dev/null
for p in $(pgrep -f 'mediamtx$'); do kill "$p" 2>/dev/null; done
kill "$PUB_PID" 2>/dev/null

echo; echo "########## FASE D: engine sungguhan menerima TS native ##########"
cd /home/dvls/blackgate-project || exit 1
SOCK=/tmp/blackgate_accept_stats.sock; SRCP=47110; OUTP=47111
rm -f "$SOCK"
cat > /tmp/soak2/stats_listener.py <<'PY'
import socket, os, sys
p = sys.argv[1]
try: os.unlink(p)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(p); s.listen(4)
open(p + ".ready", "w").close()
while True:
    c, _ = s.accept()
    data = b""
    while True:
        try: b = c.recv(65536)
        except OSError: break
        if not b: break
        data += b
    with open(p + ".lines", "ab") as f: f.write(data)
    c.close()
PY
python3 /tmp/soak2/stats_listener.py "$SOCK" &
STATS_PID=$!
for i in $(seq 1 20); do [ -f "$SOCK.ready" ] && break; sleep 0.5; done
echo "  stats listener: $([ -f "$SOCK.ready" ] && echo 'siap' || echo 'GAGAL')"

INIT='{"type":"init","route_id":"accept-native-hls","primary_source":{"type":"srtsrc","uri":"srt://127.0.0.1:'"$SRCP"'?mode=listener&latency=500000"},"auto_join":true,"sinks":[{"type":"srtsink","uri":"srt://127.0.0.1:'"$OUTP"'?mode=caller&latency=500000"}]}'
# INVOKASI BENAR (mengikuti probe yang sudah terbukti di repo):
#   INIT lewat stdin — engine menganggap EOF sebagai perintah shutdown, jadi stdin harus tetap terbuka
#   argv = [socket path, route_id]
{ echo "$INIT"; sleep 60; } | BLACKGATE_NO_THUMBNAIL=1 BLACKGATE_STATS_SOCKET="$SOCK" \
  native/build/blackgate-engine "$SOCK" accept-native-hls > /tmp/soak2/engine.log 2>&1 &
ENG_PID=$!
sleep 4
echo "  engine hidup: $(kill -0 $ENG_PID 2>/dev/null && echo ya || echo TIDAK)"

# konsumen di sisi sink (sekaligus bukti engine benar-benar mengeluarkan TS)
timeout 40 ffmpeg -hide_banner -loglevel error -i "srt://127.0.0.1:$OUTP?mode=listener&latency=500000" \
  -c copy -f mpegts /tmp/soak2/engine-out.ts > /tmp/soak2/cons.log 2>&1 &
CONS_PID=$!
sleep 3
# sumber: TS hasil pull native didorong sebagai SRT caller ke listener engine
timeout 40 ffmpeg -hide_banner -loglevel warning -re -i "$HLS_TS" -c copy -f mpegts \
  "srt://127.0.0.1:$SRCP?mode=caller&latency=500000" > /tmp/soak2/push.log 2>&1
echo "  push selesai. output engine: $(stat -c %s /tmp/soak2/engine-out.ts 2>/dev/null || echo 0) bytes"
ffprobe -v error -show_entries stream=codec_name,width,height -of default=noprint_wrappers=1 \
  /tmp/soak2/engine-out.ts 2>&1 | head -6 | sed 's/^/    /'
echo "  --- stats yang dilaporkan engine (bukti ia menerima timestamp native):"
head -c 700 "$SOCK.lines" 2>/dev/null | tr ',' '\n' | grep -iE 'route_id|buffer|bytes|pid|loss|health|error' | head -14 | sed 's/^/    /'
echo "  --- log engine:"; tail -6 /tmp/soak2/engine.log | sed 's/^/    /'
kill "$CONS_PID" "$ENG_PID" "$STATS_PID" 2>/dev/null
echo; echo "########## selesai ##########"
