#!/bin/sh
# Convert this development host into a reversible Ubuntu appliance updater test.
set -eu

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELEASE="$PROJECT_ROOT/_build/prod/rel/blackgate"
VERSION="sandbox-$(git -C "$PROJECT_ROOT" rev-parse --short HEAD)"
ROOT=/opt/blackgate
BACKUP=/root/blackgate-sandbox-backup

[ "$(id -u)" = 0 ] || { echo "Run with sudo" >&2; exit 1; }
[ -d "$RELEASE" ] || { echo "Build release first: make build" >&2; exit 1; }
[ ! -e "$ROOT" ] || { echo "$ROOT already exists; refusing overwrite" >&2; exit 1; }

mkdir -p "$BACKUP"
cp -a /etc/systemd/system/blackgate.service "$BACKUP/blackgate.service.before-sandbox"

if ! id blackgate >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /opt/blackgate --shell /usr/sbin/nologin blackgate
fi

systemctl stop blackgate.service
mkdir -p "$ROOT/releases/$VERSION" "$ROOT/incoming" "$ROOT/backups" /etc/blackgate
cp -a "$RELEASE/." "$ROOT/releases/$VERSION/"
ln -s "releases/$VERSION" "$ROOT/current"
chown -R blackgate:blackgate "$ROOT"

install -o root -g root -m 0750 "$PROJECT_ROOT/iso-builder/files/blackgate-system-action" /usr/local/libexec/blackgate-system-action
install -o root -g root -m 0750 "$PROJECT_ROOT/iso-builder/files/blackgate-updater" /usr/local/libexec/blackgate-updater
install -o root -g root -m 0440 "$PROJECT_ROOT/iso-builder/files/blackgate-system-action.sudoers" /etc/sudoers.d/blackgate-system-action
install -o root -g root -m 0644 "$PROJECT_ROOT/iso-builder/files/blackgate-update-public.pem" /etc/blackgate/update-public-key.pem
visudo -cf /etc/sudoers.d/blackgate-system-action

cat > /etc/systemd/system/blackgate.service <<'EOF'
[Unit]
Description=Blackgate SRT Gateway (appliance sandbox)
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=blackgate
Group=blackgate
WorkingDirectory=/opt/blackgate/current
Environment=PHX_SERVER=true
Environment=PORT=4000
Environment=PHX_HOST=0.0.0.0
Environment=API_AUTH_USERNAME=admin
Environment=API_AUTH_PASSWORD=password123
Environment=LICENSE_SERVER_URL=https://license-server-eta-bay.vercel.app
Environment=HOME=/opt/blackgate/current
Environment=DATABASE_DATA_DIR=/var/lib/blackgate/khepri
ExecStartPre=-/bin/rm -f /tmp/hydra_unix_sock
ExecStart=/opt/blackgate/current/bin/blackgate start
ExecStop=/opt/blackgate/current/bin/blackgate stop
ExecStopPost=-/bin/rm -f /tmp/hydra_unix_sock
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/lib/blackgate/khepri
chown -R blackgate:blackgate /var/lib/blackgate
systemctl daemon-reload
systemctl start blackgate.service
systemctl is-active --quiet blackgate.service
echo "Sandbox ready: $ROOT/current -> releases/$VERSION"
echo "Service backup: $BACKUP/blackgate.service.before-sandbox"
