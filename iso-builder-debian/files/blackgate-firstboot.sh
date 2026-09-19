#!/bin/bash
set -euo pipefail

LOG=/var/log/blackgate-firstboot.log
exec >> "$LOG" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Blackgate Debian first boot..."

tar xzf /opt/blackgate/blackgate-release.tar.gz -C /opt/blackgate --strip-components=1
rm -f /opt/blackgate/blackgate-release.tar.gz
chown -R blackgate:blackgate /opt/blackgate
mkdir -p /var/lib/blackgate/khepri
chown -R blackgate:blackgate /var/lib/blackgate

cat > /etc/sysctl.d/90-blackgate.conf <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
sysctl --system

systemctl daemon-reload
systemctl enable --now blackgate.service
systemctl disable blackgate-firstboot.service
rm -f /etc/systemd/system/multi-user.target.wants/blackgate-firstboot.service
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Blackgate Debian first boot complete"
