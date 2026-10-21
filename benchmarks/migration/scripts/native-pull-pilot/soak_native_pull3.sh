#!/usr/bin/env bash
# Uji ulang dengan bentuk yang BENAR:
#   FASE C': RTMP pull native — location harus dua segmen (app/stream), bukan satu
#   FASE D': engine sungguhan menerima TS native — memakai bentuk SRT PRODUKSI
#            (sidecar LISTEN, engine CALLER; lihat route_handler.ex:1600)
set -u

W=/tmp/soak3
MTX=/tmp/soak/mediamtx
HLS_TS=/tmp/soak/hls.ts
RTMP_SECONDS=${RTMP_SECONDS:-420}
SAMPLE=30
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

echo "########## FASE C': RTMP pull native (location 2 segmen + rantai FLV) ##########"
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
    pass:
    ips: []
    permissions:
      - action: publish
      - action: read
paths:
  all_others:
YML
("$MTX" > "$W/mtx.log" 2>&1 &) ; sleep 4

timeout $((RTMP_SECONDS+90)) ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i testsrc2=size=1280x720:rate=25 -f lavfi -i sine=frequency=1000 \
  -t "$RTMP_SECONDS" -c:v libx264 -preset ultrafast -g 50 -b:v 2500k -c:a aac \
  -f flv "rtmp://127.0.0.1:1935/live/soak" > "$W/pub.log" 2>&1 &
PUB_PID=$!
sleep 7
echo "  mediamtx: $(grep -c 'is publishing to path' "$W/mtx.log") publisher terdaftar, RTMP $(ss -tln 2>/dev/null | grep -c ':1935') listener"

timeout "$RTMP_SECONDS" gst-launch-1.0 -q \
  rtmp2src location="rtmp://127.0.0.1:1935/live/soak" ! \
  flvdemux name=d d. ! queue ! h264parse ! mpegtsmux name=m ! filesink location="$W/rtmp.ts" \
  d. ! queue ! aacparse ! m. > "$W/rtmp.log" 2>&1 &
R_PID=$!
for i in $(seq 1 $((RTMP_SECONDS/SAMPLE))); do
  sleep "$SAMPLE"
  printf '%s %s %s\n' "$(date +%H:%M:%S)" "$(stat -c %s "$W/rtmp.ts" 2>/dev/null || echo 0)" \
    "$(ps -o rss= -p "$(pgrep -x gst-launch-1.0 | head -1)" 2>/dev/null | tr -d ' ' || echo 0)" >> "$W/rtmp.samples"
done &
SAMP=$!
sleep $((RTMP_SECONDS+10)); kill "$SAMP" 2>/dev/null

python3 - "$W/rtmp.samples" "RTMP pull native (flvdemux+mpegtsmux)" <<'PY'
import sys
rows=[(l.split()[0],int(l.split()[1]),int(l.split()[2]) if len(l.split())>2 else 0) for l in open(sys.argv[1]) if len(l.split())>=2]
if not rows: print(f"  {sys.argv[2]}: TIDAK ADA SAMPEL"); raise SystemExit
d=[rows[i][1]-rows[i-1][1] for i in range(1,len(rows))]
print(f"  {sys.argv[2]}: {len(rows)} sampel, akhir {rows[-1][1]/1048576:.1f} MB")
print(f"  delta/30s: min={min(d)/1048576:.2f} max={max(d)/1048576:.2f} MB | stall {sum(1 for x in d if x<=0)}/{len(d)}")
print(f"  RSS: awal {rows[0][2]/1024:.1f} akhir {rows[-1][2]/1024:.1f} MB")
PY
echo "  log pipeline: $(tail -c 300 "$W/rtmp.log" | tr '\n' ' ' | head -c 250)"
echo "  probe hasil:"; ffprobe -v error -show_entries stream=codec_name,width,height,avg_frame_rate,sample_rate \
  -of default=noprint_wrappers=1 "$W/rtmp.ts" 2>&1 | head -8 | sed 's/^/    /'
echo "  kontinuitas PTS:"
for st in a v; do nice -n 19 ffprobe -v error -show_packets -select_streams $st -show_entries packet=pts_time -of csv=p=0 "$W/rtmp.ts" 2>/dev/null | awk -F, -v s=$st 'NF&&$1!="N/A"{if(p!=""){dd=$1-p; if(dd>mx)mx=dd}; p=$1; n++} END{printf "    %s: %d paket, jeda PTS terbesar %.3f s\n", s, n, mx}'; done
pkill -P $$ 2>/dev/null; for p in $(pgrep -x mediamtx); do kill "$p" 2>/dev/null; done; kill "$PUB_PID" 2>/dev/null

echo; echo "########## FASE D': engine menerima TS native (bentuk SRT PRODUKSI) ##########"
cd /home/dvls/blackgate-project || exit 1
SOCK=/tmp/blackgate_accept2.sock; SRCP=47120; OUTP=47121
rm -f "$SOCK" "$SOCK.ready" "$SOCK.lines"
cat > "$W/stats_listener.py" <<'PY'
import socket, os, sys
p = sys.argv[1]
try: os.unlink(p)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(p); s.listen(4)
open(p + ".ready", "w").close()
while True:
    c, _ = s.accept(); data = b""
    while True:
        try: b = c.recv(65536)
        except OSError: break
        if not b: break
        data += b
    with open(p + ".lines", "ab") as f: f.write(data)
    c.close()
PY
python3 "$W/stats_listener.py" "$SOCK" & STATS_PID=$!
for i in $(seq 1 20); do [ -f "$SOCK.ready" ] && break; sleep 0.5; done

# 1) peran SIDECAR: LISTEN, dorong TS hasil pull native (bentuk sama seperti route_handler.ex:1600)
timeout 120 ffmpeg -hide_banner -loglevel warning -re -i "$HLS_TS" -c copy -f mpegts \
  "srt://127.0.0.1:$SRCP?mode=listener&latency=500000" > "$W/sidecar.log" 2>&1 &
SC_PID=$!
# 2) konsumen di sisi sink: LISTEN (engine sebagai caller masuk ke sini)
timeout 120 ffmpeg -hide_banner -loglevel error -i "srt://127.0.0.1:$OUTP?mode=listener&latency=500000" \
  -c copy -f mpegts "$W/engine-out.ts" > "$W/cons.log" 2>&1 &
CONS_PID=$!
sleep 3

# 3) engine: source CALLER (persis seperti produksi), sink CALLER
INIT='{"type":"init","route_id":"accept-native-hls2","primary_source":{"type":"srtsrc","uri":"srt://127.0.0.1:'"$SRCP"'?mode=caller&latency=500000"},"auto_join":true,"sinks":[{"type":"srtsink","uri":"srt://127.0.0.1:'"$OUTP"'?mode=caller&latency=500000"}]}'
{ echo "$INIT"; sleep 70; } | BLACKGATE_NO_THUMBNAIL=1 BLACKGATE_STATS_SOCKET="$SOCK" \
  native/build/blackgate-engine "$SOCK" accept-native-hls2 > "$W/engine.log" 2>&1 &
ENG_PID=$!
sleep 30
echo "  engine hidup: $(kill -0 $ENG_PID 2>/dev/null && echo ya || echo TIDAK)"
echo "  output engine: $(stat -c %s "$W/engine-out.ts" 2>/dev/null || echo 0) bytes"
ffprobe -v error -show_entries stream=codec_name,width,height -of default=noprint_wrappers=1 \
  "$W/engine-out.ts" 2>&1 | head -6 | sed 's/^/    /'
echo "  --- stats dari engine (bukti menerima TS native):"
tr ',' '\n' < "$SOCK.lines" 2>/dev/null | grep -iE 'total-buffers|bytes|video-pid|audio-pids|fps|route_id|health' | head -12 | sed 's/^/    /'
echo "  --- log engine (baris penting):"
grep -iE 'error|warn|invalid|crash|corruption|double free|pid|pmt|playing|shutdown' "$W/engine.log" | head -14 | sed 's/^/    /'
echo "  --- log sidecar/konsumen:"; tail -2 "$W/sidecar.log" | sed 's/^/    /'; tail -2 "$W/cons.log" | sed 's/^/    /'
kill "$CONS_PID" "$ENG_PID" "$SC_PID" "$STATS_PID" 2>/dev/null
echo; echo "########## selesai ##########"
