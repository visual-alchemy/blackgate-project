#!/usr/bin/env bash
# Create one trusted, root-installed migration bundle for legacy Ubuntu gateways.
set -euo pipefail

VERSION="${1:?usage: scripts/package-appliance-bootstrap.sh NEW_VERSION [OUTPUT_DIR]}"
OUTPUT_DIR="${2:-$PWD/output}"
[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo "Invalid version" >&2; exit 64; }

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cd "$PROJECT_ROOT"
make build
mkdir -p "$OUTPUT_DIR"
tar czf "$STAGE/blackgate-release.tar.gz" -C _build/prod/rel blackgate
for file in \
  blackgate-bootstrap-install \
  blackgate-update-bootstrap \
  blackgate-system-action \
  blackgate-system-action.sudoers \
  blackgate-updater \
  blackgate-update-public.pem; do
  cp "iso-builder/files/$file" "$STAGE/$file"
done

cat > "$STAGE/README.txt" <<'EOF'
Blackgate Ubuntu appliance bootstrap bundle

This is a one-time migration for a trusted administrator. It changes a legacy
/opt/blackgate installation to versioned releases and enables signed dashboard
updates. Verify SHA256SUMS before transfer. On gateway, unpack then run:

  sudo ./blackgate-bootstrap-install OLD_VERSION NEW_VERSION

Example old version for client installed from commit 75becc4: 75becc4
Use the NEW_VERSION printed in this bundle filename. The gateway restarts.
EOF
(cd "$STAGE" && sha256sum blackgate-release.tar.gz blackgate-bootstrap-install \
  blackgate-update-bootstrap blackgate-system-action blackgate-system-action.sudoers \
  blackgate-updater blackgate-update-public.pem > SHA256SUMS)
tar czf "$OUTPUT_DIR/blackgate-ubuntu-bootstrap-$VERSION.tar.gz" -C "$STAGE" .
sha256sum "$OUTPUT_DIR/blackgate-ubuntu-bootstrap-$VERSION.tar.gz"
