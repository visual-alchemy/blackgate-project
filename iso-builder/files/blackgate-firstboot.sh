#!/bin/bash
set -e

LOG="/var/log/blackgate-firstboot.log"
exec >> "$LOG" 2>&1

stamp() { date '+%Y-%m-%d %H:%M:%S'; }
say() { echo "[$(stamp)] $*"; }

say "Starting Blackgate first boot setup..."

# ─── Remove sudo access for the blackgate user ─────────────────────────────
deluser blackgate sudo 2>/dev/null || true
gpasswd -d blackgate sudo 2>/dev/null || true

# ─── Kernel socket buffers for high-bitrate SRT ────────────────────────────
# Without 16 MB the kernel drops SRT packets at 9-50 Mbps before the gateway ever sees them.
say "Configuring sysctl socket buffers..."
cat <<EOF > /etc/sysctl.d/90-blackgate.conf
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
sysctl --system

# ─── System integration + first release ────────────────────────────────────
# Uses the same installer a manual install runs: systemd unit, privileged action helper with its
# sudoers drop-in, update helper, /etc/blackgate/blackgate.env (credentials, random unless the
# installer finds a Makefile), the update signing keypair, the releases/current layout and the first
# release unpacked from the tarball shipped on the ISO. Keeping one code path means the appliance and
# a hand-installed gateway behave identically.
RELEASE_TARBALL=/opt/blackgate/blackgate-release.tar.gz
RELEASE_VERSION="$(tr -d '\r\n' < /opt/blackgate/release-version 2>/dev/null || true)"
if [ -z "$RELEASE_VERSION" ] && [ -f "$RELEASE_TARBALL" ]; then
    RELEASE_VERSION="$(date +%Y.%m.%d).1"
fi

if [ -x /opt/blackgate/blackgate-install-system-actions.sh ]; then
    say "Installing system integration (release $RELEASE_VERSION)..."
    BLACKGATE_ARTIFACT_DIR=/opt/blackgate/files \
        bash /opt/blackgate/blackgate-install-system-actions.sh \
        --root /opt/blackgate \
        --data-dir /var/lib/blackgate/khepri \
        --release-version "$RELEASE_VERSION" \
        --tarball "$RELEASE_TARBALL" || say "WARNING: installer reported a failure — see above"
    rm -f "$RELEASE_TARBALL"
else
    say "WARNING: /opt/blackgate/blackgate-install-system-actions.sh is missing — no service, no updates"
fi

# ─── Keep the generated API credentials where root can find them ───────────
if [ -f /etc/blackgate/blackgate.env ] && [ ! -f /root/blackgate-credentials.txt ]; then
    {
        echo "Blackgate API credentials (generated at first boot)"
        echo "source: /etc/blackgate/blackgate.env (root only, 0600)"
        echo
        cat /etc/blackgate/blackgate.env
    } > /root/blackgate-credentials.txt
    chown root:root /root/blackgate-credentials.txt
    chmod 0600 /root/blackgate-credentials.txt
    say "API credentials written to /root/blackgate-credentials.txt (0600)"
fi

# ─── Wait for the dashboard ────────────────────────────────────────────────
say "Waiting for Blackgate to start (port 4000)..."
for i in {1..30}; do
    if ss -tlnp 2>/dev/null | grep -q ':4000 '; then
        say "✅ Blackgate is listening on port 4000"
        break
    fi
    if [ "$i" -eq 30 ]; then
        say "WARNING: Blackgate not listening after 60s. Check 'journalctl -u blackgate'"
    fi
    sleep 2
done

# ─── Disable firstboot so it won't run again on next reboot ────────────────
systemctl disable blackgate-firstboot.service
rm -f /etc/systemd/system/multi-user.target.wants/blackgate-firstboot.service

say "✅ First boot setup complete!"
