#!/bin/bash
set -e

LOG="/var/log/blackgate-firstboot.log"
exec >> "$LOG" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Blackgate first boot setup..."

# ─── Remove sudo access for blackgate user ──────────────────────────────
deluser blackgate sudo 2>/dev/null || true
gpasswd -d blackgate sudo 2>/dev/null || true

# ─── Extract Elixir release ─────────────────────────────────────────────
RELEASE_TARBALL="/opt/blackgate/blackgate-release.tar.gz"
if [ -f "$RELEASE_TARBALL" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Extracting Blackgate release..."
    tar xzf "$RELEASE_TARBALL" -C /opt/blackgate/ --strip-components=0
    rm -f "$RELEASE_TARBALL"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Release extracted successfully"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Release tarball not found at $RELEASE_TARBALL"
fi

# ─── Set ownership ──────────────────────────────────────────────────────
chown -R blackgate:blackgate /opt/blackgate
mkdir -p /var/lib/blackgate/khepri
chown -R blackgate:blackgate /var/lib/blackgate

# ─── Enable and start Blackgate service ────────────────────────────────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Blackgate service..."
systemctl daemon-reload
systemctl enable blackgate.service
systemctl start blackgate.service

# ─── Wait for port 4000 to be listening ────────────────────────────────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Blackgate to start (port 4000)..."
for i in {1..30}; do
    if ss -tlnp 2>/dev/null | grep -q ':4000 '; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Blackgate is listening on port 4000"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Blackgate not listening after 60s. Check 'journalctl -u blackgate'"
    fi
    sleep 2
done

# ─── Disable firstboot so it won't run again on next reboot ────────────
systemctl disable blackgate-firstboot.service
rm -f /etc/systemd/system/multi-user.target.wants/blackgate-firstboot.service

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ First boot setup complete!"
