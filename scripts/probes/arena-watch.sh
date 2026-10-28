#!/usr/bin/env bash
# Per-engine memory anatomy, one row per minute per engine.
#
# Why: the RSS of every DECODING engine climbs ~35 MB/h (probe A/B proved the decode branch alone
# does not), and smaps says the growth is anonymous memory, not libDeckLinkAPI.so. That leaves two
# candidates that behave differently and need different fixes:
#   * glibc malloc arenas: RSS climbs in ~64 MB anon mappings that accumulate (one per thread that
#     contends) and are never returned to the OS -> fix is MALLOC_ARENA_MAX, no code change.
#   * GStreamer buffer retention: anon grows inside a fixed number of mappings -> fix is code.
# So this logs the ANATOMY, not just the total: if anon_maps / anon_64mb keeps rising while RSS
# rises, it is arenas; if RSS rises and both stay flat, it is buffer retention.
#
# Read-only. Usage: bash arena-watch.sh [interval]   (default 60 s)
set -uo pipefail
INTERVAL="${1:-60}"
OUT_DIR="${OUT_DIR:-/home/blackgate/blackgate-trend}"
mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/arena-$(date +%Y%m%d-%H%M%S).csv"
echo "ts,route,pid,rss_mb,vmdata_mb,threads,anon_maps,anon_64mb,heap_mb" >"$CSV"
echo "writing $CSV every ${INTERVAL}s"

while :; do
  ts="$(date -u +%FT%TZ)"
  for p in $(pgrep -f '/opt/blackgate/releases/.*/blackgate-engine' 2>/dev/null); do
    rid=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | awk '{print substr($2,1,8)}')
    [ -z "${rid:-}" ] && continue
    rss=$(awk '/VmRSS/{printf "%d", $2/1024}' "/proc/$p/status" 2>/dev/null)
    vmd=$(awk '/VmData/{printf "%d", $2/1024}' "/proc/$p/status" 2>/dev/null)
    thr=$(ls "/proc/$p/task" 2>/dev/null | wc -l)
    # every anonymous rw mapping >= 1 MB is a heap arena candidate; the 60-70 MB ones are the
    # classic glibc HEAP_MAX_SIZE blocks on x86-64 (64 MiB). /proc/<pid>/maps leaves the path
    # column empty for anonymous memory (pmap is what prints "[ anon ]").
    read -r nmaps n64 heap < <(awk '
      {
        split($1, a, "-")
        sz = (strtonum("0x" a[2]) - strtonum("0x" a[1])) / 1048576
        if ($2 ~ /^rw/ && $5 == "0" && NF < 6) {
          if (sz >= 1) n++
          if (sz > 60 && sz < 70) b++
        }
        if (NF >= 6 && $6 ~ /\[heap\]/) h = sz
      }
      END { printf "%d %d %d", n+0, b+0, h+0 }' "/proc/$p/maps" 2>/dev/null)
    echo "$ts,$rid,$p,${rss:-0},${vmd:-0},${thr:-0},${nmaps:-0},${n64:-0},${heap:-0}" >>"$CSV"
  done
  sleep "$INTERVAL"
done
