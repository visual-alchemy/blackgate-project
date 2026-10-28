#!/usr/bin/env bash
# Does a different H.264 decoder grow too?
#
# Established: h264parse alone is flat; avdec_h264 (libav 1.24.1) grows ~10 MB/min at full speed and ~47
# MB/h on a live route; the rate scales with the decoder's thread count. So the retention is inside the
# decoder. This box also has openh264dec (software), vaapih264dec / vah264dec (VA-API) and vulkanh264dec.
# If one of them stays flat over the same work, switching the SDI branch's decoder is the whole fix.
#
# Usage: bash decode-alt.sh [seconds-per-arm] [arms...]
set -uo pipefail
PER="${1:-180}"
ARMS="${2:-openh264 vaapi vulkan}"
TS="${TS:-/home/blackgate/.hermes/cache/scratch/int1080i-v.ts}"
CPUS="${CPUS:-4-6}"
WORK="${WORK:-/home/blackgate/.hermes/cache/scratch}"
OUT="${OUT:-/home/blackgate/blackgate-trend/valgrind/decode-alt-$(date -u +%H%M%S).log}"
SRC="multifilesrc location=$TS loop=true caps=video/mpegts"

dec_for() {
  case "$1" in
    avdec)    echo "avdec_h264" ;;
    openh264) echo "openh264dec" ;;
    vaapi)    echo "vaapih264dec" ;;
    vah264)   echo "vah264dec" ;;
    vulkan)   echo "vulkanh264dec" ;;
  esac
}

run_arm() {
  local arm="$1" dec chain
  dec=$(dec_for "$arm")
  # vaapi/vulkan decode to GPU memory and cannot link straight into a raw-video fakesink; convert down.
  case "$arm" in
    vaapi|vah264|vulkan) chain="$SRC ! tsdemux ! h264parse ! $dec ! videoconvert ! fakesink sync=false" ;;
    *)                   chain="$SRC ! tsdemux ! h264parse ! $dec ! fakesink sync=false" ;;
  esac
  echo "=== arm $arm ($dec)"
  trap 'kill ${GPID:-} 2>/dev/null' EXIT INT TERM
  taskset -c "$CPUS" gst-launch-1.0 -e -q $chain >"$WORK/alt-$arm.log" 2>&1 &
  GPID=$!
  sleep 15
  if ! kill -0 "$GPID" 2>/dev/null; then
    echo "    DEAD: $(tail -1 "$WORK/alt-$arm.log" | cut -c1-100)"
    echo "$arm dec=$dec DEAD" >>"$OUT"; echo; return
  fi
  local r0 r="" t=0 c0 c1 cpu
  r0=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status")
  c0=$(awk '{print $14+$15}' "/proc/$GPID/stat")
  while [ "$t" -lt "$PER" ]; do
    kill -0 "$GPID" 2>/dev/null || break
    sleep 60; t=$(( t + 60 ))
    r=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$GPID/status")
    printf '      t=%-4s %s MB\n' "${t}s" "$r"
  done
  c1=$(awk '{print $14+$15}' "/proc/$GPID/stat" 2>/dev/null)
  cpu=$(( (${c1:-0} - ${c0:-0}) * 100 / PER / $(getconf CLK_TCK) ))
  kill "$GPID" 2>/dev/null; sleep 2; kill -9 "$GPID" 2>/dev/null
  printf '    RESULT %s: %s -> %s MB (%+d in %ss, cpu %s%%)\n\n' "$arm" "$r0" "${r:-?}" "$(( ${r:-0} - r0 ))" "$PER" "$cpu"
  echo "$arm dec=$dec rss0=$r0 rssN=${r:-?} delta=$(( ${r:-0} - r0 )) cpu=$cpu per=$PER" >>"$OUT"
}

for a in $ARMS; do run_arm "$a"; done
echo "ringkasan ($OUT):"
sed 's/^/  /' "$OUT"
echo
echo "Pembanding: avdec_h264 pada beban yang sama = +43 MB / 240 s (cpu ~270%)."
echo "Arm yang datar DAN cpu tinggi = decoder pengganti yang layak dipakai di cabang SDI."
