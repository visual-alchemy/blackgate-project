#!/bin/bash

# ─── Get current IP ─────────────────────────────────────────────────────
IP=""
for i in {1..5}; do
    IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [ -n "$IP" ] && break
    sleep 1
done

# ─── Get Blackgate service status ────────────────────────────────────────
if systemctl is-active --quiet blackgate 2>/dev/null; then
    STATUS="✅ Running"
else
    STATUS="❌ Stopped"
fi

# ─── Display banner ──────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║              BLACKGATE SRT GATEWAY                   ║"
echo "  ╠══════════════════════════════════════════════════════╣"
if [ -n "$IP" ]; then
echo "  ║  Dashboard  :  http://${IP}:4000"
echo "  ║  SSH        :  ssh blackgate@${IP}"
else
echo "  ║  Dashboard  :  http://<waiting for IP...>:4000"
fi
echo "  ║  Login      :  admin - ~/blackgate-dashboard-credentials.txt"
echo "  ║  Service    :  ${STATUS}"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  Logs       :  journalctl -u blackgate -f"
echo "  ║  Status     :  systemctl status blackgate"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
