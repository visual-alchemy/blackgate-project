#!/usr/bin/env bash
# Long-run watch for the LIVE gateway with real clients connected.
#
# One CSV row per minute, appended, so a multi-hour run survives the session. It records only what is readable
# WITHOUT the API token and without touching a running route:
#
#   engines / pids      - the engine set, so a respawn or a lost engine is visible as a change in the list
#   node/engine RSS     - the gateway node and the sum of its engine processes
#   engine_rss          - per-engine RSS as rid:mb;..., so a leak in ONE route is visible, not just the sum
#   tx_mbps / rx_mbps   - what the NIC actually carried: if a client drops, TX falls and this is the row that
#                         says when. This is the closest thing to proof that egress kept flowing all night.
#   udp_sndbuf_err      - kernel refusals to queue a UDP datagram (the box's own send path)
#   nic_tx_dropped      - the NIC's outbound drops (the wire, not SRT)
#   src_invalid         - SOURCE_INVALID markers per interval (ingest leg stalls)
#   sidecar_restarts    - "Starting ffmpeg sidecar" per interval (HLS/RTMP source reconnects)
#   engine_exits        - engine shutdown/exit lines per interval
#   engine_starts       - "start_native_pipeline" per interval: an engine RESPAWN, whichever path caused it
#   watchdog_restarts   - "Watchdog detected" per interval: the route's own watchdog fired
#                         (BOTH variants count: "SDI playout freeze" and "network stall")
#
# The SRT sender counters that the dashboard's "egress dropped" badge is computed from live inside the release
# and are not readable without a token; this file is what makes a spike in them attributable, because a drop
# window that lines up with src_invalid/sidecar_restarts is an ingest story, and one that does not is a network
# story. The dashboard's Destination Statistics (dropped vs retx) is read by the operator at the end of the run.
set -uo pipefail

OUT_DIR="${OUT_DIR:-/home/blackgate/blackgate-trend}"
INTERVAL="${INTERVAL:-60}"
NIC="${NIC:-enp3s0}"
ROOT="${BLACKGATE_ROOT:-/opt/blackgate}"
LABEL="${LABEL:-clients}"
# SRT destination ports to watch for a backed-up kernel send queue.
SRT_SINK_PORTS="${SRT_SINK_PORTS:-16000,17000,18000}"

mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/soak-$LABEL-$(date +%Y%m%d-%H%M%S).csv"

now_ms() { date +%s%3N; }
last_ts="$(date +%s)"
TX_PREV="$(cat "/sys/class/net/$NIC/statistics/tx_bytes" 2>/dev/null || echo 0)"
RX_PREV="$(cat "/sys/class/net/$NIC/statistics/rx_bytes" 2>/dev/null || echo 0)"
T_PREV="$(date +%s)"

# ONE journal read per cycle, then every counter greps the same buffer: five separate journalctl
# invocations cost more than the sample itself and skew the counters away from the row's timestamp.
window() { journalctl -u blackgate.service --since "@$last_ts" --no-pager -q 2>/dev/null; }

count_in() {
  # $1 = the window text, $2 = ERE pattern
  printf '%s\n' "$1" | grep -cE "$2" || true
}

udp_sndbuf_errors() {
  awk '/^Udp:/ { if (++n==2) { print $7; exit } }' /proc/net/snmp
}

nic_drops() {
  # TX line: bytes packets errors dropped carrier collsns -> field 4
  ip -s link show "$NIC" 2>/dev/null | awk '/TX:/ {getline; print $4; exit}'
}

nic_rx_drops() {
  cat "/sys/class/net/$NIC/statistics/rx_dropped" 2>/dev/null || echo 0
}

# Bytes sitting in the KERNEL send queue of the SRT sink sockets. A non-zero, growing value here means the
# egress leg is being held back after SRT handed the datagram over - which separates "our queue is backing up"
# from "the client never got it".
srt_sendq() {
  ss -unap 2>/dev/null | awk -v ports="$SRT_SINK_PORTS" '
    BEGIN { n = split(ports, P, ","); for (i = 1; i <= n; i++) want[P[i]] = 1 }
    {
      split($4, a, ":"); port = a[length(a)]
      if (port in want && $1 == "UNCONN") { gsub(/[^0-9]/, "", $3); s += $3 }
    }
    END { printf "%d", s }'
}

node_rss_mb() {
  ps -eo rss,args 2>/dev/null | grep -E 'beam\.smp.*(blackgate|rel/blackgate)' | grep -v grep |
    awk '{s+=$1} END {printf "%.1f", s/1024}'
}

engines() {
  ps -eo pid,args 2>/dev/null |
    grep -E "^ *[0-9]+ $ROOT/releases/[0-9.]+/lib/blackgate-[0-9.]+/priv/native/build/blackgate-engine " |
    grep -v grep
}

# rid:rss_mb;rid:rss_mb;... - one entry per engine, so the trend of a single route can be read out of the row.
engine_rss_each() {
  printf '%s\n' "$1" | awk 'NF {print $1, $3}' | while read -r p rid; do
    rss="$(awk '/VmRSS/{print int($2/1024)}' "/proc/$p/status" 2>/dev/null)"
    printf '%s:%s;' "${rid:0:8}" "${rss:-0}"
  done
}

echo "ts,engines,engine_rss_mb,engine_rss,node_rss_mb,tx_mbps,rx_mbps,udp_sndbuf_err,nic_tx_dropped,nic_rx_dropped,srt_sendq_bytes,src_invalid,sidecar_restarts,engine_exits,engine_starts,watchdog_restarts,load1,engine_ids" >"$CSV"
echo "watch started: $CSV (interval ${INTERVAL}s)"

while :; do
  ts="$(date +%FT%T%:z)"
  eng="$(engines)"
  n_eng="$(printf '%s\n' "$eng" | grep -c . || true)"
  eng_rss="$(printf '%s\n' "$eng" | awk 'NF {print $1}' | while read -r p; do awk '/VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null; done | awk '{s+=$1} END {printf "%.1f", s/1024}')"
  eng_each="$(engine_rss_each "$eng")"
  ids="$(printf '%s\n' "$eng" | awk 'NF {print $3}' | cut -c1-8 | paste -sd';' -)"
  win="$(window)"
  src="$(count_in "$win" 'SOURCE_INVALID:')"
  side="$(count_in "$win" 'Starting ffmpeg sidecar')"
  exits="$(count_in "$win" 'shutdown complete|engine exited|Engine (exited|crashed)')"
  starts="$(count_in "$win" 'start_native_pipeline')"
  wdog="$(count_in "$win" 'Watchdog detected')"
  load="$(cut -d' ' -f1 /proc/loadavg)"

  # NIC throughput over the interval that just elapsed: the egress proof.
  T_NOW="$(date +%s)"
  TX_NOW="$(cat "/sys/class/net/$NIC/statistics/tx_bytes" 2>/dev/null || echo 0)"
  RX_NOW="$(cat "/sys/class/net/$NIC/statistics/rx_bytes" 2>/dev/null || echo 0)"
  DT=$(( T_NOW - T_PREV )); [ "$DT" -lt 1 ] && DT=1
  tx_mbps=$(( (TX_NOW - TX_PREV) * 8 / DT / 1000000 ))
  rx_mbps=$(( (RX_NOW - RX_PREV) * 8 / DT / 1000000 ))

  printf '%s,%s,%s,"%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
    "$ts" "$n_eng" "${eng_rss:-0}" "$eng_each" "$(node_rss_mb)" "$tx_mbps" "$rx_mbps" \
    "$(udp_sndbuf_errors)" "$(nic_drops)" "$(nic_rx_drops)" "$(srt_sendq)" \
    "$src" "$side" "$exits" "$starts" "$wdog" "$load" "$ids" >>"$CSV"

  TX_PREV="$TX_NOW"; RX_PREV="$RX_NOW"; T_PREV="$T_NOW"
  last_ts="$(date +%s)"
  sleep "$INTERVAL"
done
