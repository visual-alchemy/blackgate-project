#!/usr/bin/env bash
# Create a dashboard-uploadable signed update. Private key stays outside Git.
set -euo pipefail

VERSION="${1:?usage: scripts/package-signed-update.sh VERSION PRIVATE_KEY [OUTPUT_DIR]}"
PRIVATE_KEY="${2:?usage: scripts/package-signed-update.sh VERSION PRIVATE_KEY [OUTPUT_DIR]}"
OUTPUT_DIR="${3:-$PWD/output}"
[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo "Invalid version" >&2; exit 64; }
[[ -r "$PRIVATE_KEY" ]] || { echo "Private key unreadable" >&2; exit 66; }

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cd "$PROJECT_ROOT"
[[ "$VERSION" == "$(tr -d '\r\n' < iso-builder/release-version)" ]] || {
  echo "Package version must match iso-builder/release-version and bundled release notes" >&2
  exit 65
}
make build
mkdir -p "$OUTPUT_DIR"
tar czf "$STAGE/blackgate-release.tar.gz" -C _build/prod/rel blackgate
RELEASE_SHA="$(sha256sum "$STAGE/blackgate-release.tar.gz" | awk '{print $1}')"
cp "$PROJECT_ROOT/iso-builder/files/blackgate-updater" "$STAGE/blackgate-updater"
chmod 0750 "$STAGE/blackgate-updater"
UPDATER_SHA="$(sha256sum "$STAGE/blackgate-updater" | awk '{print $1}')"
cat > "$STAGE/manifest.txt" <<EOF
product=blackgate
version=$VERSION
platform=ubuntu-24.04-amd64
release_sha256=$RELEASE_SHA
updater_sha256=$UPDATER_SHA
EOF
openssl pkeyutl -sign -rawin -inkey "$PRIVATE_KEY" \
  -in "$STAGE/manifest.txt" -out "$STAGE/manifest.sig"
tar czf "$OUTPUT_DIR/$VERSION.bgupdate" -C "$STAGE" \
  manifest.txt manifest.sig blackgate-release.tar.gz blackgate-updater
sha256sum "$OUTPUT_DIR/$VERSION.bgupdate"
