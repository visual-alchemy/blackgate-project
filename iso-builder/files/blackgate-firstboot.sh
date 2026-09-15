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
# Replaced by iso-builder/build.sh when this script is injected into an ISO.
# Keep the runtime release directory independent from the OTP application
# version (which remains 1.0.0).
RELEASE_VERSION="@BLACKGATE_RELEASE_VERSION@"
if [ -f "$RELEASE_TARBALL" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Extracting Blackgate release..."
    mkdir -p "/opt/blackgate/releases/$RELEASE_VERSION" /opt/blackgate/incoming /opt/blackgate/backups
    tar xzf "$RELEASE_TARBALL" -C "/opt/blackgate/releases/$RELEASE_VERSION" --strip-components=1
    ln -sfn "releases/$RELEASE_VERSION" /opt/blackgate/current
    rm -f "$RELEASE_TARBALL"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Release extracted successfully"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Release tarball not found at $RELEASE_TARBALL"
fi

# ─── Set ownership ──────────────────────────────────────────────────────
chown -R blackgate:blackgate /opt/blackgate/releases /opt/blackgate/incoming /opt/blackgate/backups
mkdir -p /var/lib/blackgate/khepri
chown -R blackgate:blackgate /var/lib/blackgate

# ─── Install Blackmagic Desktop Video driver ───────────────────────────
DRIVER_DEB="/opt/blackgate/desktopvideo_16.0.1a2_amd64.deb"
if [ -f "$DRIVER_DEB" ]; then
    if dpkg-query -W -f='${Status}' desktopvideo 2>/dev/null | grep -q 'install ok installed'; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Desktop Video 16.0.1 already installed"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installing Desktop Video 16.0.1..."
        OFFLINE_LIST="/etc/apt/sources.list.d/blackgate-offline.list"
        OFFLINE_PARTS="/etc/apt/blackgate-empty-sources.list.d"
        if [ ! -f "$OFFLINE_LIST" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Offline APT repository unavailable"
            exit 1
        fi
        apt-get \
            -o Dir::Etc::sourcelist="$OFFLINE_LIST" \
            -o Dir::Etc::sourceparts="$OFFLINE_PARTS" \
            update
        apt-get \
            -o Dir::Etc::sourcelist="$OFFLINE_LIST" \
            -o Dir::Etc::sourceparts="$OFFLINE_PARTS" \
            --no-install-recommends \
            install -y "$DRIVER_DEB"
    fi

    # Curtin can install Desktop Video before the target's final kernel is
    # booted. Build DKMS again for the actual running kernel before modprobe.
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Building Desktop Video DKMS for $(uname -r)..."
    dkms autoinstall -k "$(uname -r)"
    depmod -a "$(uname -r)"
    systemctl enable --now DesktopVideoHelper.service || true
    modprobe blackmagic_io
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Desktop Video package missing"
    exit 1
fi

# ─── Configure DeckLink Quad 2 connector mapping ───────────────────────
PROFILE_TOOL_STAGED="/opt/blackgate/decklink-profile-config"
PROFILE_TOOL="/opt/blackgate/current/bin/decklink-profile-config"
install -m 0755 "$PROFILE_TOOL_STAGED" "$PROFILE_TOOL"

for i in {1..30}; do
    if compgen -G "/dev/blackmagic/io*" > /dev/null; then
        break
    fi
    sleep 1
done

if ! compgen -G "/dev/blackmagic/io*" > /dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: DeckLink device nodes unavailable"
    exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Setting DeckLink profile to 2dhd..."
profile_configured=false
for i in {1..30}; do
    if "$PROFILE_TOOL" two-sub-devices-half; then
        profile_configured=true
        break
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DeckLink SDK not ready; retrying ($i/30)..."
    sleep 1
done

if [ "$profile_configured" != true ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not activate DeckLink 2dhd profile"
    exit 1
fi

# ─── Configure kernel socket buffers for high-bitrate SRT ───────────────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuring sysctl socket buffers..."
cat <<EOF > /etc/sysctl.d/90-blackgate.conf
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
sysctl --system

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
