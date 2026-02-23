#!/bin/bash
set -e

#
# Blackgate ISO Builder
# Builds a bootable Debian 12 ISO with Blackgate pre-installed.
# Designed to run inside GitHub Actions (Ubuntu runner).
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build"
VERSION="${VERSION:-1.0.0}"
OUTPUT_NAME="blackgate-${VERSION}-amd64"

echo "═══════════════════════════════════════════════════════════"
echo "  Blackgate ISO Builder v${VERSION}"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ─── Step 1: Install live-build ─────────────────────────────────────────

echo "📦 Step 1: Installing live-build..."
sudo apt-get update -qq
sudo apt-get install -y -qq live-build debootstrap syslinux-utils isolinux xorriso debian-archive-keyring

# ─── Step 2: Build Blackgate Release ────────────────────────────────────

echo "🔨 Step 2: Building Blackgate release..."

# Build native C pipeline
echo "   Building native pipeline..."
cd "$PROJECT_ROOT"
make -C native clean
make -C native

# Install Elixir deps and build release
echo "   Building Elixir release..."
cd "$PROJECT_ROOT"
export MIX_ENV=prod
export SECRET_KEY_BASE=$(openssl rand -hex 64)
mix local.hex --force
mix local.rebar --force
mix deps.get --only prod
mix compile

# Build frontend
echo "   Building frontend..."
cd "$PROJECT_ROOT/web_app"
yarn install --frozen-lockfile 2>/dev/null || yarn install
npx vite build
mkdir -p "$PROJECT_ROOT/priv/static"
cp -r dist/* "$PROJECT_ROOT/priv/static/"

# Build Elixir release
cd "$PROJECT_ROOT"
mix phx.digest
mix release --overwrite

RELEASE_DIR="$PROJECT_ROOT/_build/prod/rel/blackgate"
echo "   Release built at: $RELEASE_DIR"

# ─── Step 3: Prepare live-build ─────────────────────────────────────────

echo "🏗️  Step 3: Preparing live-build environment..."

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Initialize live-build
lb config \
    --mode debian \
    --system live \
    --mirror-bootstrap "http://deb.debian.org/debian/" \
    --mirror-chroot "http://deb.debian.org/debian/" \
    --mirror-binary "http://deb.debian.org/debian/" \
    --security false \
    --distribution bookworm \
    --architectures amd64 \
    --binary-images iso-hybrid \
    --debian-installer live \
    --debian-installer-gui false \
    --archive-areas "main contrib non-free non-free-firmware" \
    --apt-recommends false \
    --memtest none \
    --iso-application "Blackgate SRT Gateway" \
    --iso-preparer "Visual Alchemy" \
    --iso-publisher "Visual Alchemy" \
    --iso-volume "BLACKGATE-${VERSION}"

# ─── Step 4: Copy configuration files ──────────────────────────────────

echo "📋 Step 4: Copying configuration files..."

# Package lists
mkdir -p config/package-lists
cp "$SCRIPT_DIR/config/package-lists/blackgate.list.chroot" config/package-lists/

# Chroot includes (files that go into the ISO filesystem)
mkdir -p config/includes.chroot/opt/blackgate
mkdir -p config/includes.chroot/etc/systemd/system
mkdir -p config/includes.chroot/etc/ssh/sshd_config.d
mkdir -p config/includes.chroot/etc/sysctl.d
mkdir -p config/includes.chroot/var/lib/blackgate

# Copy Blackgate release
cp -r "$RELEASE_DIR"/* config/includes.chroot/opt/blackgate/

# Copy native pipeline binary
cp "$PROJECT_ROOT/native/build/blackgate_pipeline" config/includes.chroot/opt/blackgate/bin/

# Copy public key for license verification
mkdir -p config/includes.chroot/opt/blackgate/lib/blackgate-*/priv/license
if [ -f "$PROJECT_ROOT/priv/license/public_key.pem" ]; then
    # Find the actual lib directory name
    find config/includes.chroot/opt/blackgate/lib -name "blackgate-*" -type d | while read dir; do
        mkdir -p "$dir/priv/license"
        cp "$PROJECT_ROOT/priv/license/public_key.pem" "$dir/priv/license/"
    done
fi

# Copy system config files
cp "$SCRIPT_DIR/config/includes.chroot/etc/systemd/system/blackgate.service" \
    config/includes.chroot/etc/systemd/system/
cp "$SCRIPT_DIR/config/includes.chroot/etc/ssh/sshd_config.d/99-blackgate.conf" \
    config/includes.chroot/etc/ssh/sshd_config.d/
cp "$SCRIPT_DIR/config/includes.chroot/etc/sysctl.d/99-blackgate.conf" \
    config/includes.chroot/etc/sysctl.d/
cp "$SCRIPT_DIR/config/includes.chroot/etc/motd" \
    config/includes.chroot/etc/
cp "$SCRIPT_DIR/config/includes.chroot/etc/issue" \
    config/includes.chroot/etc/

# Copy hooks
mkdir -p config/hooks/live
cp "$SCRIPT_DIR/config/hooks/live/0100-setup.hook.chroot" config/hooks/live/
chmod +x config/hooks/live/*.hook.chroot

# ─── Step 5: Build ISO ──────────────────────────────────────────────────

echo "🔥 Step 5: Building ISO (this takes ~10 minutes)..."
sudo lb build 2>&1 | tail -20

# ─── Step 6: Move output ────────────────────────────────────────────────

echo "📀 Step 6: Collecting output..."
mkdir -p "$SCRIPT_DIR/output"

if [ -f "${OUTPUT_NAME}.hybrid.iso" ]; then
    mv "${OUTPUT_NAME}.hybrid.iso" "$SCRIPT_DIR/output/${OUTPUT_NAME}.iso"
elif [ -f "live-image-amd64.hybrid.iso" ]; then
    mv "live-image-amd64.hybrid.iso" "$SCRIPT_DIR/output/${OUTPUT_NAME}.iso"
fi

ISO_PATH="$SCRIPT_DIR/output/${OUTPUT_NAME}.iso"

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(du -h "$ISO_PATH" | cut -f1)
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  ✅ ISO built successfully!"
    echo "  📀 File: $ISO_PATH"
    echo "  📏 Size: $ISO_SIZE"
    echo "═══════════════════════════════════════════════════════════"
else
    echo "❌ ISO build failed — no output file found"
    ls -la "$BUILD_DIR/"
    exit 1
fi
