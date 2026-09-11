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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Building Desktop Video DKMS for $(uname -r)..."
/usr/sbin/dkms autoinstall -k "$(uname -r)"
/usr/sbin/depmod -a "$(uname -r)"
/usr/sbin/modprobe blackmagic_io
systemctl enable --now DesktopVideoHelper.service

for i in {1..30}; do
    compgen -G '/dev/blackmagic/io*' > /dev/null && break
    sleep 1
done
compgen -G '/dev/blackmagic/io*' > /dev/null

install -m 0755 /opt/blackgate/decklink-profile-config /opt/blackgate/bin/decklink-profile-config
for i in {1..30}; do
    /opt/blackgate/bin/decklink-profile-config two-sub-devices-half && break
    [ "$i" -eq 30 ] && exit 1
    sleep 1
done

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
