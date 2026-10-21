#!/usr/bin/env bash
# Build a signed Blackgate update package (<version>.bgupdate).
#
# The package is what Settings > System uploads and deploys, and what the root updater verifies
# before it touches the running release. Layout, matching iso-builder/files/blackgate-updater:
#
#   manifest.txt             product/version/platform/release_sha256/updater_sha256
#   manifest.sig             Ed25519 signature over manifest.txt (openssl pkeyutl -rawin)
#   blackgate-release.tar.gz the OTP release, priv/release-notes.json baked in
#   blackgate-updater        the root updater, so an old appliance can be updated too
#
# Usage:
#   scripts/package-signed-update.sh [VERSION] [PRIVATE_KEY] [OUTPUT_DIR]
#
# VERSION defaults to iso-builder/release-version, the key to /etc/blackgate/update-private-key.pem
# (generate the pair once with scripts/install-system-actions.sh), output to ./dist.
set -euo pipefail

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# The signing key is 0600 root, so signing has to run as root — but `make build` must not: it writes
# priv/static and web_app/dist, which would then be root-owned and break the next non-root build.
# So build as yourself, then package:
#
#     make build && sudo BLACKGATE_SKIP_BUILD=1 scripts/package-signed-update.sh
#     make build && sudo scripts/package-signed-update.sh --no-build
#
# Flags are stripped before the positional arguments, so `--no-build` can stand alone or beside them.
SKIP_BUILD="${BLACKGATE_SKIP_BUILD:-0}"
positional=()
for arg in "$@"; do
  case "$arg" in
    --no-build) SKIP_BUILD=1 ;;
    *) positional+=("$arg") ;;
  esac
done

VERSION_FILE="iso-builder/release-version"
VERSION="${positional[0]:-$(tr -d '\r\n' < "$VERSION_FILE" 2>/dev/null || true)}"
PRIVATE_KEY="${positional[1]:-/etc/blackgate/update-private-key.pem}"
OUTPUT_DIR="${positional[2]:-$PROJECT_ROOT/dist}"
NOTES_FILE="iso-builder/release-notes.txt"

[ -n "$VERSION" ] || { echo "No version: pass one or write $VERSION_FILE" >&2; exit 64; }
printf '%s' "$VERSION" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || { echo "Invalid version '$VERSION'" >&2; exit 64; }
[ -r "$PRIVATE_KEY" ] || {
  echo "Private key unreadable: $PRIVATE_KEY" >&2
  echo "Generate the signing pair once with: sudo scripts/install-system-actions.sh --root <dir>" >&2
  exit 66
}
command -v openssl >/dev/null || { echo "openssl is required to sign the package" >&2; exit 69; }

if [ "$SKIP_BUILD" = "1" ]; then
  echo "=== using the existing release (BLACKGATE_SKIP_BUILD=1) ==="
else
  echo "=== building release $VERSION ==="
  make build
fi

APP_DIR="$(find _build/prod/rel/blackgate/lib -maxdepth 1 -type d -name 'blackgate-*' | head -1)"
[ -n "$APP_DIR" ] || { echo "Release app dir not found — did make build succeed?" >&2; exit 65; }

# The dashboard reads priv/release-notes.json to show which release is deployed and what changed in
# it, so bake it into the release before packing. Quotes are stripped from the subjects: this is a
# display string, and a hand-written notes file is used when one exists.
CHANGES="$(if [ -r "$NOTES_FILE" ]; then cat "$NOTES_FILE"; else git log --pretty='- %s' -12; fi)"
NOTES_JSON="$APP_DIR/priv/release-notes.json"
{
  printf '{\n  "version": "%s",\n  "released_on": "%s",\n  "changes": [\n' "$VERSION" "$(date +%F)"
  printf '%s\n' "$CHANGES" | sed -e 's/[\\"]//g' -e 's/^- //' -e '/^[[:space:]]*$/d' | awk '{printf "    \"%s\",\n", $0}'
  printf '    "Packaged by scripts/package-signed-update.sh"\n  ]\n}\n'
} > "$NOTES_JSON"
python3 -c "import json,sys; json.load(open('$NOTES_JSON')); print('release notes valid:', '$NOTES_JSON')"

# Running under sudo writes the notes file as root inside a tree the operator owns, which then blocks
# the *next* non-root packaging run ("Permission denied" on the same path). Hand it back.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
  chown "$SUDO_USER" "$NOTES_JSON" 2>/dev/null || true
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUTPUT_DIR"

echo "=== packing ==="
tar czf "$STAGE/blackgate-release.tar.gz" -C _build/prod/rel blackgate
RELEASE_SHA="$(sha256sum "$STAGE/blackgate-release.tar.gz" | awk '{print $1}')"
install -m 0750 iso-builder/files/blackgate-updater "$STAGE/blackgate-updater"
UPDATER_SHA="$(sha256sum "$STAGE/blackgate-updater" | awk '{print $1}')"

cat > "$STAGE/manifest.txt" <<EOF
product=blackgate
version=$VERSION
platform=ubuntu-24.04-amd64
release_sha256=$RELEASE_SHA
updater_sha256=$UPDATER_SHA
EOF

openssl pkeyutl -sign -rawin -inkey "$PRIVATE_KEY" -in "$STAGE/manifest.txt" -out "$STAGE/manifest.sig"

PACKAGE="$OUTPUT_DIR/$VERSION.bgupdate"
tar czf "$PACKAGE" -C "$STAGE" manifest.txt manifest.sig blackgate-release.tar.gz blackgate-updater

# Signing runs as root, so hand the artifact back to whoever invoked sudo.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
  chown "$SUDO_USER" "$PACKAGE" 2>/dev/null || true
  chown "$SUDO_USER" "$OUTPUT_DIR" 2>/dev/null || true
fi

echo
echo "package : $PACKAGE"
echo "version : $VERSION"
echo "release : sha256=$RELEASE_SHA ($(du -h "$STAGE/blackgate-release.tar.gz" | cut -f1))"
echo "package sha256: $(sha256sum "$PACKAGE" | awk '{print $1}')"
