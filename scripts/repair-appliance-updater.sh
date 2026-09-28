#!/bin/sh
# Repair this dev appliance's root updater. Optional VERSION deploys a release
# after repair; omit it to restore rollback support without restarting Blackgate.
set -eu

VERSION="${1:-}"
if [ -n "$VERSION" ]; then
  case "$VERSION" in
    [A-Za-z0-9]* ) ;;
    *) echo "Usage: sudo $0 [VERSION]" >&2; exit 64 ;;
  esac
  case "$VERSION" in
    *[!A-Za-z0-9._-]*) echo "Invalid version" >&2; exit 64 ;;
  esac
  [ "${#VERSION}" -le 64 ] || { echo "Invalid version" >&2; exit 64; }
fi

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo" >&2; exit 1; }
[ "$(hostname)" = "blackgate-dev" ] || {
  echo "Refusing to modify updater outside blackgate-dev" >&2
  exit 1
}

ROOT=/opt/blackgate
CURRENT="$ROOT/current"
RELEASES="$ROOT/releases"
UPDATER=/usr/local/libexec/blackgate-updater
PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UPDATER_SOURCE="$PROJECT_ROOT/iso-builder/files/blackgate-updater"

[ -x "$UPDATER_SOURCE" ] || { echo "Repo updater missing or not executable" >&2; exit 1; }
[ -L "$CURRENT" ] || { echo "Current release symlink missing: $CURRENT" >&2; exit 1; }
CURRENT_REAL="$(readlink -f "$CURRENT")"
case "$CURRENT_REAL" in
  "$RELEASES"/*) ;;
  *) echo "Current release points outside $RELEASES: $CURRENT_REAL" >&2; exit 1 ;;
esac

if [ -n "$VERSION" ]; then
  TARGET="$RELEASES/$VERSION"
  PACKAGE="$ROOT/incoming/$VERSION.bgupdate"
  [ -d "$TARGET" ] || { echo "Installed target release missing: $TARGET" >&2; exit 1; }
  [ -f "$PACKAGE" ] || { echo "Update package missing: $PACKAGE" >&2; exit 1; }
  [ -x "$TARGET/bin/blackgate" ] || { echo "Target release executable missing: $TARGET" >&2; exit 1; }
fi

STAMP="$(date '+%Y%m%d%H%M%S')"
if [ -f "$UPDATER" ]; then
  BACKUP="$UPDATER.backup-$STAMP"
  cp -p -- "$UPDATER" "$BACKUP"
fi
install -o root -g root -m 0750 "$UPDATER_SOURCE" "$UPDATER"
cmp -s "$UPDATER_SOURCE" "$UPDATER" || { echo "Installed updater verification failed" >&2; exit 1; }
echo "Rollback-capable updater installed; current release unchanged"
[ -z "$VERSION" ] || exec "$UPDATER" deploy "$VERSION"
