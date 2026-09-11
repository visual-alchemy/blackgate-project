#!/bin/sh
# Blackgate appliance login summary. Only show in an interactive terminal.

case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
[ -n "$IP" ] || IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$IP" ] || IP="<waiting for DHCP>"

if systemctl is-active --quiet blackgate.service 2>/dev/null; then
  STATUS="Running"
else
  STATUS="Stopped"
fi

UPTIME="$(uptime -p 2>/dev/null || uptime)"
MEMORY="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 " / " $2}')"
DISK="$(df -h / 2>/dev/null | awk 'NR==2 {print $3 " used, " $4 " free"}')"
DECKLINKS="$(find /dev/blackmagic -maxdepth 1 -name 'io*' -type c 2>/dev/null | wc -l | tr -d ' ')"

printf '\n'
printf '%s\n' '  ╔══════════════════════════════════════════════════════════════╗'
printf '%s\n' '  ║                   BLACKGATE SRT GATEWAY                      ║'
printf '%s\n' '  ╠══════════════════════════════════════════════════════════════╣'
printf '  ║  Hostname   : %-48s║\n' "$(hostname)"
printf '  ║  Dashboard  : %-48s║\n' "http://${IP}:4000"
printf '  ║  Login      : %-48s║\n' 'admin / password123'
printf '  ║  SSH        : %-48s║\n' "ssh blackgate@${IP}"
printf '  ║  Service    : %-48s║\n' "$STATUS"
printf '%s\n' '  ╠══════════════════════════════════════════════════════════════╣'
printf '  ║  Uptime     : %-48s║\n' "$UPTIME"
printf '  ║  Memory     : %-48s║\n' "${MEMORY:-unavailable}"
printf '  ║  Disk       : %-48s║\n' "${DISK:-unavailable}"
printf '  ║  DeckLink   : %-48s║\n' "${DECKLINKS:-0} device node(s)"
printf '%s\n' '  ╠══════════════════════════════════════════════════════════════╣'
printf '%s\n' '  ║  Root shell : su -                                           ║'
printf '%s\n' "  ║  Logs       : su -c 'journalctl -u blackgate -f'             ║"
printf '%s\n' '  ╚══════════════════════════════════════════════════════════════╝'
printf '\n'
