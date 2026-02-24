#!/bin/bash
set -e

#
# Blackgate ISO Builder (Ubuntu 22.04 Docker Edition)
# Builds a bootable Ubuntu Jammy ISO with Blackgate Docker image pre-installed.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build"
VERSION="${VERSION:-1.0.0}"
OUTPUT_NAME="blackgate-${VERSION}-amd64"

echo "═══════════════════════════════════════════════════════════"
echo "  Blackgate Server ISO Builder v${VERSION} (Ubuntu Docker)"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ─── Step 1: Install prerequisites ──────────────────────────────────────

echo "📦 Step 1: Installing live-build..."
sudo apt-get update -qq
sudo apt-get install -y -qq live-build debootstrap grub-pc-bin grub-efi-amd64-bin xorriso ubuntu-keyring mtools dosfstools

# ─── Step 2: Build Blackgate Docker Image ───────────────────────────────

echo "🐳 Step 2: Building Blackgate Docker Image..."
cd "$PROJECT_ROOT"

# Ensure we're using the latest Dockerfile
docker build -t blackgate/app:latest .

# ─── Step 3: Prepare live-build ─────────────────────────────────────────

echo "🏗️  Step 3: Preparing live-build environment for Ubuntu Jammy..."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

lb config \
    --mode ubuntu \
    --system live \
    --mirror-bootstrap "http://archive.ubuntu.com/ubuntu/" \
    --mirror-chroot "http://archive.ubuntu.com/ubuntu/" \
    --mirror-binary "http://archive.ubuntu.com/ubuntu/" \
    --security false \
    --distribution jammy \
    --bootloader "grub-efi" \
    --binary-images iso \
    --archive-areas "main restricted universe multiverse" \
    --memtest none \
    --iso-application "Blackgate Server" \
    --iso-preparer "Visual Alchemy" \
    --iso-publisher "Visual Alchemy" \
    --iso-volume "BLACKGATE-${VERSION}"

# ─── Step 4: Copy configuration files ──────────────────────────────────

echo "📋 Step 4: Copy configuration files..."

# Package lists
mkdir -p config/package-lists
cp "$SCRIPT_DIR/config/package-lists/blackgate.list.chroot" config/package-lists/

# Chroot includes
mkdir -p config/includes.chroot/opt/blackgate
mkdir -p config/includes.chroot/etc/systemd/system
mkdir -p config/includes.chroot/etc/ssh/sshd_config.d
mkdir -p config/includes.chroot/etc/sysctl.d
mkdir -p config/includes.chroot/var/lib/blackgate

# ✨ Export Docker image into the ISO
echo "   Exporting Docker image to tar (this may take a minute)..."
docker save blackgate/app:latest | gzip > config/includes.chroot/opt/blackgate/blackgate-image.tar.gz

# Copy docker-compose
cp "$SCRIPT_DIR/config/includes.chroot/opt/blackgate/docker-compose.yml" config/includes.chroot/opt/blackgate/

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

if [ -f "binary.iso" ]; then
    mv "binary.iso" "$SCRIPT_DIR/output/${OUTPUT_NAME}.iso"
elif [ -f "${OUTPUT_NAME}.iso" ]; then
    mv "${OUTPUT_NAME}.iso" "$SCRIPT_DIR/output/${OUTPUT_NAME}.iso"
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
