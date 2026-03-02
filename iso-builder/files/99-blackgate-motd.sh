#!/bin/bash

# ─── Get current IP ─────────────────────────────────────────────────────
IP=""
for i in {1..5}; do
    IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [ -n "$IP" ] && break
    sleep 1
done

# ─── Get Blackgate container status ─────────────────────────────────────
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^blackgate$"; then
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
echo "  ║  Login      :  admin / password123"
echo "  ║  Service    :  ${STATUS}"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  Logs       :  sudo journalctl -u blackgate -f       ║"
echo "  ║  Status     :  sudo systemctl status blackgate       ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
