#!/usr/bin/env bash
# Install the system integration behind Settings > System:
#
#   * blackgate.service            systemd unit running $ROOT/current (so restart/reboot/deploy work
#                                  and the gateway comes back after a reboot)
#   * blackgate-system-action      root helper, allowlisted via sudoers, schedules restart/reboot/
#                                  shutdown/deploy through systemd-run with a delay
#   * blackgate-updater            root update deployer: verifies a signed package, swaps `current`
#                                  atomically, rolls back when the new release fails its health check
#   * /etc/blackgate/blackgate.env credentials (0600 root) — never in the unit file, which is world
#                                  readable
#   * /etc/blackgate/update-{private,public}-key.pem  Ed25519 update signing pair
#
# Usage (as root, from the project checkout):
#   sudo scripts/install-system-actions.sh [--root DIR] [--data-dir DIR] [--user NAME]
#                                          [--tarball PATH] [--release-version V] [--no-start]
#                                          [--skip-unit] [--skip-keys]
#
# --root defaults to /opt/blackgate. A development checkout wants a deployment directory of its own,
# e.g. --root /home/blackgate/blackgate-deploy --data-dir /home/blackgate/blackgate-project (so the
# existing Khepri database, and therefore the routes, is kept).
set -euo pipefail

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

ROOT=/opt/blackgate
DATA_DIR=/var/lib/blackgate/khepri
SERVICE_USER=blackgate
TARBALL=""
VERSION="$(tr -d '\r\n' < "$PROJECT_ROOT/iso-builder/release-version" 2>/dev/null || true)"
SKIP_UNIT=0
SKIP_KEYS=0
START=1

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2%/}"; shift 2 ;;
    --data-dir) DATA_DIR="${2%/}"; shift 2 ;;
    --user) SERVICE_USER="$2"; shift 2 ;;
    --tarball) TARBALL="$2"; shift 2 ;;
    --release-version) VERSION="$2"; shift 2 ;;
    --skip-unit) SKIP_UNIT=1; shift ;;
    --skip-keys) SKIP_KEYS=1; shift ;;
    --no-start) START=0; shift ;;
    -h | --help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run this as root (it installs a systemd unit and a sudoers drop-in)." >&2; exit 77; }
id "$SERVICE_USER" >/dev/null 2>&1 || { echo "User $SERVICE_USER does not exist." >&2; exit 67; }

echo "=== 0/7 pre-flight ==="
for tool in install visudo openssl systemctl tar sed awk grep pgrep; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 69; }
done
echo "tools ok (install visudo openssl systemctl tar sed awk grep pgrep)"

# Khepri uses the database directory verbatim as its Ra store directory. Pointing it at a *parent*
# makes the gateway come up on a fresh empty database while the real one — with the routes — stays
# untouched next to it, which looks exactly like "my routes disappeared". Refuse that case and say
# what the right value is.
if [ -d "$DATA_DIR" ]; then
  existing_store="$(find "$DATA_DIR" -maxdepth 1 -mindepth 1 -name 'khepri#*' -type d -print -quit 2>/dev/null || true)"
  if [ -n "$existing_store" ]; then
    echo "Refusing --data-dir $DATA_DIR: this looks like a parent directory, not a Khepri store." >&2
    echo "  a store already lives at: $existing_store" >&2
    echo "  pass --data-dir $existing_store (that is the value the running gateway uses)." >&2
    exit 65
  fi
fi

FILES="${BLACKGATE_ARTIFACT_DIR:-$PROJECT_ROOT/iso-builder/files}"
for required in blackgate.service blackgate-system-action blackgate-system-action.sudoers blackgate-updater; do
  [ -r "$FILES/$required" ] || { echo "Missing $FILES/$required — run from the project checkout, or point BLACKGATE_ARTIFACT_DIR at the directory that ships them." >&2; exit 66; }
done

echo "=== 1/7 directories ==="
# /usr/local/libexec is a Debian-ism that Ubuntu does not create; the privileged helpers live there
# because that is where a packaged appliance expects them.
mkdir -p "$ROOT/releases" "$ROOT/incoming" "$ROOT/backups" "$DATA_DIR" /etc/blackgate /usr/local/libexec
chown -R "$SERVICE_USER:$SERVICE_USER" "$ROOT" "$DATA_DIR"
echo "root     : $ROOT (releases, incoming, backups)"
echo "data dir : $DATA_DIR"
echo "helpers  : /usr/local/libexec"

echo "=== 2/7 privileged helpers ==="
install -o root -g root -m 0750 "$FILES/blackgate-system-action" /usr/local/libexec/blackgate-system-action
install -o root -g root -m 0750 "$FILES/blackgate-updater" /usr/local/libexec/blackgate-updater

echo "=== 3/7 sudoers drop-in ==="
# Validate before installing: a broken file in /etc/sudoers.d locks out every sudo user on the box.
visudo -cf "$FILES/blackgate-system-action.sudoers" >/dev/null
install -o root -g root -m 0440 "$FILES/blackgate-system-action.sudoers" /etc/sudoers.d/blackgate-system-action
visudo -c >/dev/null
echo "installed /etc/sudoers.d/blackgate-system-action (validated by visudo)"

echo "=== 4/7 environment file ==="
ENV_FILE=/etc/blackgate/blackgate.env
if [ -f "$ENV_FILE" ]; then
  echo "$ENV_FILE exists — keeping the existing credentials"
  # Re-installing under a different root (dev box -> appliance layout, say) must not leave the
  # dashboard pointing at the old one: the update card works against BLACKGATE_ROOT.
  existing_root="$(grep -m1 -oP '(?<=^BLACKGATE_ROOT=).*' "$ENV_FILE" || true)"
  if [ "$existing_root" = "$ROOT" ]; then
    echo "  BLACKGATE_ROOT already $ROOT"
  elif [ -n "$existing_root" ]; then
    sed -i "s|^BLACKGATE_ROOT=.*|BLACKGATE_ROOT=$ROOT|" "$ENV_FILE"
    echo "  BLACKGATE_ROOT updated: $existing_root -> $ROOT"
  else
    printf 'BLACKGATE_ROOT=%s\n' "$ROOT" >> "$ENV_FILE"
    echo "  BLACKGATE_ROOT added: $ROOT"
  fi
else
  API_USER=admin
  API_PASSWORD=""
  RELEASE_COOKIE_VALUE=""
  LICENSE_URL=""
  if [ -r "$PROJECT_ROOT/Makefile" ]; then
    API_USER="$(grep -m1 -oP '(?<=API_AUTH_USERNAME=)\S+' "$PROJECT_ROOT/Makefile" || echo admin)"
    API_PASSWORD="$(grep -m1 -oP '(?<=API_AUTH_PASSWORD=)\S+' "$PROJECT_ROOT/Makefile" || true)"
    RELEASE_COOKIE_VALUE="$(grep -m1 -oP '(?<=RELEASE_COOKIE=)\S+' "$PROJECT_ROOT/Makefile" || true)"
    LICENSE_URL="$(grep -m1 -oP '(?<=LICENSE_SERVER_URL=)\S+' "$PROJECT_ROOT/Makefile" || true)"
  fi
  [ -n "$API_PASSWORD" ] || API_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
  [ -n "$RELEASE_COOKIE_VALUE" ] || RELEASE_COOKIE_VALUE="$(openssl rand -base64 32 | tr -d '/+=')"
  {
    echo "# Read by blackgate.service. Keep 0600 root:root — a unit file is world readable."
    echo "API_AUTH_USERNAME=$API_USER"
    echo "API_AUTH_PASSWORD=$API_PASSWORD"
    echo "RELEASE_COOKIE=$RELEASE_COOKIE_VALUE"
    # The dashboard's Software Update card works against this root; without it the app falls back to
    # /opt/blackgate, which is wrong for any deployment that does not use the appliance layout.
    echo "BLACKGATE_ROOT=$ROOT"
    [ -n "$LICENSE_URL" ] && echo "LICENSE_SERVER_URL=$LICENSE_URL"
  } > "$ENV_FILE"
  chown root:root "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  if [ "$API_PASSWORD" = "password123" ]; then
    echo "note: credentials were copied from the repository's Makefile (lab defaults)."
    echo "      Change them in $ENV_FILE and restart the service before this box faces a network."
  else
    echo "generated a random API password in $ENV_FILE"
  fi
fi
chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"

if [ "$SKIP_KEYS" -eq 0 ]; then
  echo "=== 5/7 update signing keys ==="
  if [ -f /etc/blackgate/update-private-key.pem ]; then
    echo "signing key exists — left as is"
  else
    openssl genpkey -algorithm ED25519 -out /etc/blackgate/update-private-key.pem
    chmod 0600 /etc/blackgate/update-private-key.pem
    chown root:root /etc/blackgate/update-private-key.pem
    echo "generated /etc/blackgate/update-private-key.pem (keep it off this box when you can)"
  fi
  openssl pkey -in /etc/blackgate/update-private-key.pem -pubout -out /etc/blackgate/update-public-key.pem
  chmod 0644 /etc/blackgate/update-public-key.pem
  chown root:root /etc/blackgate/update-public-key.pem
  echo "public key: /etc/blackgate/update-public-key.pem (what the updater verifies against)"
else
  echo "=== 5/7 update signing keys (skipped) ==="
fi

if [ "$SKIP_UNIT" -eq 0 ]; then
  echo "=== 6/7 systemd unit ==="
  UNIT=/etc/systemd/system/blackgate.service
  sed -e "s#^User=.*#User=$SERVICE_USER#" \
    -e "s#^Group=.*#Group=$SERVICE_USER#" \
    -e "s#^Environment=DATABASE_DATA_DIR=.*#Environment=DATABASE_DATA_DIR=$DATA_DIR#" \
    -e "s#/opt/blackgate#$ROOT#g" \
    "$FILES/blackgate.service" > "$UNIT"
  chown root:root "$UNIT"
  chmod 0644 "$UNIT"
  systemctl daemon-reload
  systemctl enable blackgate.service >/dev/null
  echo "installed $UNIT (WorkingDirectory=$ROOT/current, DATABASE_DATA_DIR=$DATA_DIR)"
else
  echo "=== 6/7 systemd unit (skipped) ==="
fi

echo "=== 7/7 first release ==="
if [ -n "$TARBALL" ]; then
  [ -r "$TARBALL" ] || { echo "Tarball not readable: $TARBALL" >&2; exit 66; }
  [ -n "$VERSION" ] || { echo "No release version — write iso-builder/release-version or pass --release-version" >&2; exit 64; }
  mkdir -p "$ROOT/releases/$VERSION"
  tar xzf "$TARBALL" -C "$ROOT/releases/$VERSION" --strip-components=1
  chown -R "$SERVICE_USER:$SERVICE_USER" "$ROOT/releases/$VERSION"
  ln -sfn "releases/$VERSION" "$ROOT/current.next"
  mv -Tf "$ROOT/current.next" "$ROOT/current"
  echo "seeded releases/$VERSION and pointed current at it"
elif [ -e "$ROOT/current" ]; then
  echo "current -> $(readlink "$ROOT/current")"
else
  echo "no release yet: build one (make build) and seed it, or deploy a .bgupdate through the dashboard"
fi

if [ "$START" -eq 1 ] && [ "$SKIP_UNIT" -eq 0 ]; then
  echo
  if pgrep -u "$SERVICE_USER" -f 'beam.smp' >/dev/null 2>&1; then
    echo "A Blackgate node for $SERVICE_USER is already running outside systemd."
    echo "Stop it first (make stop), then: systemctl start blackgate.service"
    echo "Two nodes at once leave a stale /tmp/hydra_unix_sock and every engine fails to connect."
  elif [ -e "$ROOT/current" ]; then
    systemctl restart blackgate.service
    sleep 3
    echo "blackgate.service: $(systemctl is-active blackgate.service)"
    echo "Dashboard: http://$(hostname -I 2>/dev/null | awk '{print $1}'):4000"
  else
    echo "Not starting: no release under $ROOT/current yet."
  fi
fi

echo
echo "Next steps"
echo "  1. Prove the privileged path without rebooting anything:"
echo "       sudo /usr/local/libexec/blackgate-system-action test-action"
echo "       systemctl is-active blackgate-dashboard-test.timer"
echo "       sudo /usr/local/libexec/blackgate-system-action cancel blackgate-dashboard-test"
echo "  2. Build a signed package for the dashboard's Software Update card:"
echo "       scripts/package-signed-update.sh"
echo "  3. Upload it in Settings > System, or copy it to $ROOT/incoming/<version>.bgupdate"
