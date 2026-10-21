#!/usr/bin/env bash
# Uji penerimaan terakhir, memakai bentuk yang TERBUKTI memproses data (sumber UDP, seperti benchmark):
# TS hasil pull native dikirim lewat UDP -> engine -> sink UDP. Pertanyaannya cuma satu:
# apakah engine mengurai PAT/PMT/timestamp milik TS native dan mengalirkannya.
set -u
W=/tmp/soak9; SOCK=/tmp/blackgate_accept9.sock; INP=47190; OUTP=47191
rm -rf "$W"; mkdir -p "$W"; cd /home/dvls/blackgate-project || exit 1
rm -f "$SOCK" "$SOCK.ready" "$SOCK.lines"
cat > "$W/l.py" <<'PY'
import socket, os, sys
p = sys.argv[1]
try: os.unlink(p)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(p); s.listen(4); open(p + ".ready", "w").close()
while True:
    c, _ = s.accept(); f = open(p + ".lines", "ab")
    while True:
        try: b = c.recv(65536)
        except OSError: break
        if not b: break
        f.write(b); f.flush()
    f.close(); c.close()
PY
python3 "$W/l.py" "$SOCK" & STATS=$!
for i in $(seq 1 20); do [ -f "$SOCK.ready" ] && break; sleep 0.5; done

# pengirim: TS hasil pull native (timestamp ASLI CDN, tanpa rebase) lewat UDP
timeout 50 ffmpeg -hide_banner -loglevel warning -re -i /tmp/soak/hls.ts -c copy -f mpegts \
  "udp://127.0.0.1:$INP?pkt_size=1316" > "$W/tx.log" 2>&1 &
TX=$!
sleep 2
timeout 50 ffmpeg -hide_banner -loglevel warning -i "udp://127.0.0.1:$OUTP?fifo_size=2097152&overrun_nonfatal=1" \
  -c copy -f mpegts "$W/out.ts" > "$W/rx.log" 2>&1 &
RX=$!
sleep 1
INIT='{"route_id":"accept-udp","source":{"type":"udpsrc","uri":"udp://127.0.0.1:'"$INP"'"},"preview":true,"sinks":[{"type":"udpsink","uri":"udp://127.0.0.1:'"$OUTP"'?pkt_size=1316"}]}'
echo "payload: $INIT"
{ echo "$INIT"; sleep 35; } | BLACKGATE_STATS_SOCKET="$SOCK" native/build/blackgate-engine accept-udp > "$W/e.log" 2>&1 &
ENG=$!
sleep 26
echo "engine hidup: $(kill -0 $ENG 2>/dev/null && echo ya || echo TIDAK)"
echo "output sink: $(stat -c %s "$W/out.ts" 2>/dev/null || echo 0) bytes"
ffprobe -v error -show_entries stream=codec_name,width,height,avg_frame_rate -of default=noprint_wrappers=1 "$W/out.ts" 2>&1 | head -6 | sed 's/^/    /'
echo "--- stats engine (pid terurai = bukti PMT native diterima):"
tr ',' '\n' < "$SOCK.lines" 2>/dev/null | grep -oE '"(video-pid|audio-pids|fps-inferred|bytes-received|bytes-sent|total-bytes-sent|packets-received)":[^}]*' | sort -u | head -10 | sed 's/^/    /'
echo "--- log engine:"; grep -iE 'Argument|pipeline|pid|thumbnail|sink|tee|error|warn' "$W/e.log" | head -12 | sed 's/^/    /'
kill $RX $TX $ENG $STATS 2>/dev/null; pkill -P $$ 2>/dev/null
echo "########## selesai ##########"
