#!/usr/bin/env bash
# Build one trusted migration bundle for a source-checkout Blackgate gateway.
set -euo pipefail

VERSION="${1:?usage: scripts/package-source-appliance-bootstrap.sh VERSION [OUTPUT_DIR]}"
OUTPUT_DIR="${2:-$PWD/output}"
[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
  echo "Invalid version" >&2
  exit 64
}

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cd "$PROJECT_ROOT"
make build
mkdir -p "$OUTPUT_DIR"
tar czf "$STAGE/blackgate-release.tar.gz" -C _build/prod/rel blackgate
printf '%s\n' "$VERSION" > "$STAGE/bootstrap-version"

for file in \
  blackgate-source-bootstrap-install \
  blackgate-system-action \
  blackgate-system-action.sudoers \
  blackgate-updater \
  blackgate-update-public.pem; do
  cp "iso-builder/files/$file" "$STAGE/$file"
done

cat > "$STAGE/README.txt" <<'EOF'
Blackgate source-installation migration bundle

This trusted, one-time migration moves runtime service into versioned appliance
layout while retaining source tree and source Khepri database for rollback.

Before running, verify SHA256SUMS. Run read-only preflight:

  ./blackgate-source-bootstrap-install --check SOURCE_ROOT OLD_VERSION [DATABASE_SOURCE]

Then execute migration:

  sudo ./blackgate-source-bootstrap-install --confirm SOURCE_ROOT OLD_VERSION [DATABASE_SOURCE]

Typical command:

  sudo ./blackgate-source-bootstrap-install --confirm /home/woi/blackgate-project legacy-1.0.0

If installer finds more than one SOURCE_ROOT/khepri* directory, supply active
database directory explicitly as third argument. Migration stops and restarts
blackgate.service. Do not interrupt power during migration.
EOF

(
  cd "$STAGE"
  sha256sum \
    blackgate-release.tar.gz \
    bootstrap-version \
    blackgate-source-bootstrap-install \
    blackgate-system-action \
    blackgate-system-action.sudoers \
    blackgate-updater \
    blackgate-update-public.pem > SHA256SUMS
)

BUNDLE="$OUTPUT_DIR/blackgate-source-bootstrap-$VERSION.tar.gz"
tar czf "$BUNDLE" -C "$STAGE" .
sha256sum "$BUNDLE"
