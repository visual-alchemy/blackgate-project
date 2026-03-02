#!/bin/bash
set -e

LOG="/var/log/blackgate-firstboot.log"
exec >> "$LOG" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Blackgate first boot setup..."

# ─── Ensure docker.io is installed ─────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Docker not found, installing..."
    apt-get update -qq
    apt-get install -y docker.io docker-compose-v2
fi

# ─── Ensure docker group and user membership ────────────────────────────
groupadd -f docker
usermod -aG docker blackgate 2>/dev/null || true

# ─── Wait for Docker to be ready ───────────────────────────────────────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Docker daemon..."
for i in {1..30}; do
    if docker info > /dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Docker is ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Docker not ready after 60s"
        exit 1
    fi
    sleep 2
done

# ─── Load Docker image ──────────────────────────────────────────────────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Loading Blackgate Docker image..."
if docker image inspect blackgate/app:latest > /dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Image already loaded, skipping"
else
    docker load < /opt/blackgate/blackgate-image.tar.gz
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Image loaded successfully"
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

# ─── Wait for container to be running ──────────────────────────────────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Blackgate container..."
for i in {1..20}; do
    if docker ps --format '{{.Names}}' | grep -q "^blackgate$"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Blackgate container is running"
        break
    fi
    sleep 3
done

# ─── Disable firstboot so it won't run again on next reboot ────────────
systemctl disable blackgate-firstboot.service
rm -f /etc/systemd/system/multi-user.target.wants/blackgate-firstboot.service

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ First boot setup complete!"
