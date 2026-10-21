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

# ─── Runtime packages from the image's local pool ─────────────────────────
# The installer fetched these from the Ubuntu archive when it had network. When it did not, the image
# carried them: pool/ + Packages.gz on the ISO, kept on the installed system by the installer's
# late-commands, indexed by the same list that drives the install (files/packages.list is generated from
# iso-builder/autoinstall/user-data, so the two can never drift). Without them the release cannot start.
if [ -f /opt/blackgate/files/packages.list ] && [ -f /opt/blackgate/pool/Packages.gz ]; then
    MISSING=""
    for pkg in gstreamer1.0-plugins-bad libsrt1.5-gnutls libcjson1 dkms; do
        dpkg -s "$pkg" >/dev/null 2>&1 || MISSING="$MISSING $pkg"
    done
    if [ -n "$MISSING" ]; then
        say "Runtime packages missing:$MISSING — installing from the local pool..."
        xargs -a /opt/blackgate/files/packages.list apt-get install -y --no-install-recommends >>"$LOG" 2>&1 \
            || say "WARNING: local pool install reported an error (see $LOG) — the gateway may not start"
        say "Local pool install finished."
    else
        say "Runtime packages already present (archive install succeeded)."
    fi
else
    say "No local package pool on this system — runtime packages must come from the archive."
fi

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

# ─── Hand the client the dashboard credentials ─────────────────────────────
# The dashboard password is generated at install and lives in a root-only file, while the client has no
# root: without this copy they cannot log in at all.
if [ -f /etc/blackgate/blackgate.env ] && [ ! -f /home/blackgate/blackgate-dashboard-credentials.txt ]; then
    API_USER="$(grep -m1 -oP '(?<=API_AUTH_USERNAME=)\S+' /etc/blackgate/blackgate.env 2>/dev/null || echo admin)"
    API_PASS="$(grep -m1 -oP '(?<=API_AUTH_PASSWORD=)\S+' /etc/blackgate/blackgate.env 2>/dev/null || true)"
    if [ -n "$API_PASS" ]; then
        {
            echo "Blackgate dashboard"
            echo "  URL      : http://$(hostname -I | awk '{print $1}'):4000"
            echo "  username : $API_USER"
            echo "  password : $API_PASS"
            echo
            echo "Change the password after the first login (Settings > Users)."
        } > /home/blackgate/blackgate-dashboard-credentials.txt
        chown blackgate:blackgate /home/blackgate/blackgate-dashboard-credentials.txt
        chmod 0640 /home/blackgate/blackgate-dashboard-credentials.txt
        say "Dashboard credentials written to /home/blackgate/blackgate-dashboard-credentials.txt"
    fi
fi

# ─── Console banner ────────────────────────────────────────────────────────
# A headless install has no way to learn its own address before somebody logs in, and the login prompt
# itself carries no information. Write one for the console (getty prints /etc/issue.d/*), without the
# password: that stays in the 0640 credentials file.
IP_NOW="$(hostname -I | awk '{print $1}')"
if [ -n "$IP_NOW" ]; then
    mkdir -p /etc/issue.d
    {
        echo "Blackgate SRT Gateway"
        echo "  Dashboard : http://$IP_NOW:4000"
        echo "  Login     : admin (password: /home/blackgate/blackgate-dashboard-credentials.txt)"
        echo
    } > /etc/issue.d/99-blackgate
    say "Console banner written with IP $IP_NOW"
else
    say "WARNING: no IPv4 address yet - console banner skipped"
fi

# ─── DeckLink driver ───────────────────────────────────────────────────────
# The vendor driver is what makes the card usable: the GStreamer plugin only talks to it. The ISO ships
# the .deb, so a fresh appliance gets SDI without anyone logging in.
DV_DEB=/opt/blackgate/files/blackmagic-desktopvideo.deb
if [ -f "$DV_DEB" ]; then
    say "Installing Blackmagic Desktop Video driver..."
    if apt-get install -y --no-install-recommends "$DV_DEB" >> "$LOG" 2>&1; then
        modprobe blackmagic 2>/dev/null || true
        modprobe blackmagic-io 2>/dev/null || true
        say "Desktop Video installed; dkms: $(dkms status | tr '\n' ' ')"
    else
        say "WARNING: Desktop Video installation failed — see above"
    fi
else
    say "WARNING: no Desktop Video .deb on this image — SDI needs the vendor driver installed by hand"
fi

# ─── DeckLink driver presence ──────────────────────────────────────────────
# Without the vendor driver the gateway runs but SDI stays dark, so say it plainly at first boot.
if ls /dev/blackmagic/io* >/dev/null 2>&1; then
    say "DeckLink devices present: $(ls /dev/blackmagic/ | tr '\n' ' ')"
else
    say "WARNING: no /dev/blackmagic/* devices - SDI needs the Blackmagic Desktop Video driver"
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
