#!/usr/bin/env bash
# FASE D'': bukti terakhir — engine sungguhan menerima TS hasil pull native.
# Perubahan dari percobaan sebelumnya (semua kesalahan harness, bukan engine):
#   - sink memakai UDP, bukan SRT, supaya variabel interop SRT hilang; pertanyaannya
#     adalah "engine menerima timestamp/PAT/PMT native atau tidak", bukan "SRT-nya jalan atau tidak"
#   - stats listener menulis INKREMENTAL (versi sebelumnya menahan sampai EOF, jadi buta)
#   - source tetap CALLER ke sidecar LISTEN = bentuk produksi (route_handler.ex:1600)
set -u

W=/tmp/soak4
HLS_TS=/tmp/soak/hls.ts
rm -rf "$W"; mkdir -p "$W"
cd /home/dvls/blackgate-project || exit 1

SOCK=/tmp/blackgate_accept3.sock; SRCP=47130; UDPP=47131
rm -f "$SOCK" "$SOCK.ready" "$SOCK.lines"

cat > "$W/stats_listener.py" <<'PY'
import socket, os, sys
p = sys.argv[1]
try: os.unlink(p)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(p); s.listen(4)
open(p + ".ready", "w").close()
while True:
    c, _ = s.accept()
    f = open(p + ".lines", "ab")
    while True:
        try: b = c.recv(65536)
        except OSError: break
        if not b: break
        f.write(b); f.flush()      # INKREMENTAL: bisa dibaca saat engine masih hidup
    f.close(); c.close()
PY
python3 "$W/stats_listener.py" "$SOCK" & STATS_PID=$!
for i in $(seq 1 20); do [ -f "$SOCK.ready" ] && break; sleep 0.5; done
echo "stats listener: $([ -f "$SOCK.ready" ] && echo siap || echo GAGAL)"

# 1) peran SIDECAR: LISTEN, dorong TS hasil pull native ke SRT (identik route_handler.ex:1600)
timeout 100 ffmpeg -hide_banner -loglevel warning -re -i "$HLS_TS" -c copy -f mpegts \
  "srt://127.0.0.1:$SRCP?mode=listener&latency=500000" > "$W/sidecar.log" 2>&1 &
SC_PID=$!
sleep 3
# 2) penguras sink UDP (engine menulis ke sini)
timeout 100 ffmpeg -hide_banner -loglevel warning -i "udp://127.0.0.1:$UDPP?fifo_size=2097152&overrun_nonfatal=1" \
  -c copy -f mpegts "$W/engine-out.ts" > "$W/udp.log" 2>&1 &
UDP_PID=$!
sleep 1

# 3) engine: source CALLER (produksi), sink UDP
INIT='{"type":"init","route_id":"accept-native-hls3","primary_source":{"type":"srtsrc","uri":"srt://127.0.0.1:'"$SRCP"'?mode=caller&latency=500000"},"auto_join":true,"sinks":[{"type":"udpsink","uri":"udp://127.0.0.1:'"$UDPP"'?pkt_size=1316"}]}'
echo "INIT: $INIT"
{ echo "$INIT"; sleep 60; } | BLACKGATE_NO_THUMBNAIL=1 BLACKGATE_STATS_SOCKET="$SOCK" \
  native/build/blackgate-engine "$SOCK" accept-native-hls3 > "$W/engine.log" 2>&1 &
ENG_PID=$!

sleep 35
echo "engine hidup: $(kill -0 $ENG_PID 2>/dev/null && echo ya || echo TIDAK)"
echo "output di sisi sink: $(stat -c %s "$W/engine-out.ts" 2>/dev/null || echo 0) bytes"
ffprobe -v error -show_entries stream=codec_name,width,height,avg_frame_rate,sample_rate \
  -of default=noprint_wrappers=1 "$W/engine-out.ts" 2>&1 | head -8 | sed 's/^/    /'
echo "--- STATS dari engine (bukti utama):"
tr ',' '\n' < "$SOCK.lines" 2>/dev/null | grep -iE 'route_id|total-buffers|bytes-received|bytes-sent|video-pid|audio-pid|fps|loss|health|sink-index|updated' | head -20 | sed 's/^/    /'
echo "   (baris stats mentah: $(wc -c < "$SOCK.lines" 2>/dev/null || echo 0) bytes)"
echo "--- log engine:"; tail -12 "$W/engine.log" | sed 's/^/    /'
echo "--- log sidecar (kosong = normal):"; head -3 "$W/sidecar.log" | sed 's/^/    /'
echo "--- log penguras UDP:"; head -4 "$W/udp.log" | sed 's/^/    /'
kill "$UDP_PID" "$ENG_PID" "$SC_PID" "$STATS_PID" 2>/dev/null
pkill -P $$ 2>/dev/null
echo "########## selesai ##########"
