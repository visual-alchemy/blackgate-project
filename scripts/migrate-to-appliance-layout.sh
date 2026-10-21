#!/usr/bin/env bash
# Move an existing Blackgate deployment to the appliance layout.
#
#   before:  a release directory somewhere in a checkout, a Khepri store next to it, and the gateway
#            started by hand (make start) or by a unit pointing at that directory
#   after:   /opt/blackgate/{releases,current,incoming,backups} with the store at the appliance's
#            /var/lib/blackgate/khepri, driven by blackgate.service
#
# The routes live in the store, so the store is *copied* and verified before anything points at it; the
# original is left untouched as a fallback. If the new store comes up empty, the script puts the old
# layout back and exits non-zero instead of leaving a gateway with no routes.
#
# Usage (as root):
#   scripts/migrate-to-appliance-layout.sh \
#     --old-store /home/blackgate/blackgate-project/khepri#blackgate@blackgate \
#     --tarball /home/blackgate/blackgate-release.tar.gz \
#     [--root /opt/blackgate] [--data-dir /var/lib/blackgate/khepri] \
#     [--release-version 2026.10.21.1] [--user blackgate] [--expected-routes 2] [--old-root DIR]
#
# --old-root is only needed for the rollback path (default /opt/blackgate is what the unit already
# points at when nothing was migrated yet); pass the deployment root the unit uses today.
set -euo pipefail

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

OLD_STORE=""
OLD_ROOT=""
ROOT=/opt/blackgate
DATA_DIR=/var/lib/blackgate/khepri
TARBALL=""
VERSION="$(tr -d '\r\n' < "$PROJECT_ROOT/iso-builder/release-version" 2>/dev/null || true)"
SERVICE_USER=blackgate
EXPECTED_ROUTES=2
SERVICE=blackgate.service

while [ $# -gt 0 ]; do
  case "$1" in
    --old-store) OLD_STORE="${2%/}"; shift 2 ;;
    --old-root) OLD_ROOT="${2%/}"; shift 2 ;;
    --root) ROOT="${2%/}"; shift 2 ;;
    --data-dir) DATA_DIR="${2%/}"; shift 2 ;;
    --tarball) TARBALL="$2"; shift 2 ;;
    --release-version) VERSION="$2"; shift 2 ;;
    --user) SERVICE_USER="$2"; shift 2 ;;
    --expected-routes) EXPECTED_ROUTES="$2"; shift 2 ;;
    -h | --help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

say() { printf '\n== %s ==\n' "$*"; }
die() { echo "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this as root"
[ -n "$OLD_STORE" ] || die "--old-store is required (the khepri#<node> directory holding the routes)"
[ -d "$OLD_STORE" ] || die "no Khepri store at $OLD_STORE"
[ -r "$TARBALL" ] || die "--tarball must point at a release tarball of $VERSION"
[ -n "$VERSION" ] || die "no release version (write iso-builder/release-version or pass --release-version)"

# The old deployment root: needed only if the new store turns out empty and we roll back.
if [ -z "$OLD_ROOT" ]; then
  OLD_ROOT="$(grep -m1 -oP '(?<=^WorkingDirectory=).*/[^/]+' /etc/systemd/system/$SERVICE 2>/dev/null | sed 's|/current$||' || true)"
fi

say "1/6 stopping $SERVICE"
systemctl stop "$SERVICE" 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -u "$SERVICE_USER" -f beam.smp >/dev/null 2>&1 || break
  sleep 1
done
if pgrep -u "$SERVICE_USER" -f beam.smp >/dev/null 2>&1; then
  die "a Blackgate node for $SERVICE_USER is still running — stop it first (make stop) and re-run"
fi
echo "stopped (no writes to the store while it is copied)"

say "2/6 creating the appliance layout"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" \
  "$ROOT" "$ROOT/releases" "$ROOT/incoming" "$ROOT/backups" "$DATA_DIR"
echo "$ROOT/{releases,current,incoming,backups} · store $DATA_DIR"

say "3/6 copying the Khepri store"
if [ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
  die "$DATA_DIR is not empty — move it aside first, or pass a different --data-dir"
fi
cp -a "$OLD_STORE/." "$DATA_DIR/"
chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
echo "$(find "$DATA_DIR" -type f | wc -l) files, $(du -sh "$DATA_DIR" | cut -f1)"

say "4/6 verifying the copy against the original"
if diff -r --brief "$OLD_STORE" "$DATA_DIR" >/dev/null 2>&1; then
  echo "identical to $OLD_STORE (which stays untouched as the fallback)"
else
  echo "copy differs from the original — starting the old gateway again, nothing was changed" >&2
  systemctl start "$SERVICE" 2>/dev/null || true
  exit 1
fi

say "5/6 installing under $ROOT"
BLACKGATE_ARTIFACT_DIR="${BLACKGATE_ARTIFACT_DIR:-$PROJECT_ROOT/iso-builder/files}" \
  "$PROJECT_ROOT/scripts/install-system-actions.sh" \
  --root "$ROOT" --data-dir "$DATA_DIR" --release-version "$VERSION" --tarball "$TARBALL"

say "6/6 checking that the migrated gateway actually sees the routes"
sleep 8
journalctl -u "$SERVICE" -n 120 --no-pager 2>/dev/null | grep -i "database directory" | tail -1 || true
if journalctl -u "$SERVICE" -n 120 --no-pager 2>/dev/null | grep -q "0 record(s) recovered"; then
  echo "the new store came up empty — rolling back to the old layout" >&2
  if [ -n "$OLD_ROOT" ] && [ -d "$OLD_ROOT" ]; then
    BLACKGATE_ARTIFACT_DIR="${BLACKGATE_ARTIFACT_DIR:-$PROJECT_ROOT/iso-builder/files}" \
      "$PROJECT_ROOT/scripts/install-system-actions.sh" \
      --root "$OLD_ROOT" --data-dir "$OLD_STORE" --release-version "$VERSION" --tarball "$TARBALL"
    echo "rolled back: the gateway runs from $OLD_ROOT against $OLD_STORE again" >&2
  else
    echo "could not determine the old root — fix the unit by hand before starting anything" >&2
  fi
  exit 1
fi

systemctl is-active "$SERVICE"
COOKIE="$(grep -m1 -oP '(?<=^RELEASE_COOKIE=).*' /etc/blackgate/blackgate.env 2>/dev/null || true)"
ROUTES="$(RELEASE_COOKIE="${COOKIE:-blackgate_production_cookie}" \
  "$ROOT/current/bin/blackgate" rpc 'IO.puts(length(elem(Blackgate.Db.get_all_routes(), 1)))' 2>/dev/null | tail -1 || true)"

echo "routes in the new store: ${ROUTES:-unknown} (expected $EXPECTED_ROUTES)"
echo
echo "migration done. The gateway now runs from $ROOT/current; the old root ${OLD_ROOT:-?} and the"
echo "original store $OLD_STORE are untouched. Once you are satisfied:"
echo "  mv '$OLD_STORE' ~/khepri-backup-\$(date +%Y%m%d)      # retire the old store"
echo "  rm -rf '${OLD_ROOT:-<old root>}'                      # retire the old deployment root"
