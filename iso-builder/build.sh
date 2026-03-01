#!/bin/bash
set -e

#
# Blackgate ISO Builder (Ubuntu 22.04 Docker Edition)
# Builds a bootable Ubuntu Jammy ISO with Blackgate Docker image pre-installed.
#
# Usage:
#   ./build.sh                    # Build with default version 1.0.0
#   VERSION=2.0.0 ./build.sh      # Build with custom version
#
# Prerequisites:
#   - Ubuntu Server 22.04 (Jammy) x86_64
#   - Docker installed and running (sudo apt install docker.io)
#   - Current user in docker group (sudo usermod -aG docker $USER)
#   - At least 10GB free disk space
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

# ─── Pre-flight checks ─────────────────────────────────────────────────

# Make sure Docker is available
if ! command -v docker &>/dev/null; then
    echo "❌ Docker is not installed. Install it first:"
    echo "   sudo apt-get install -y docker.io"
    echo "   sudo usermod -aG docker \$USER"
    echo "   (then log out and back in)"
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "❌ Docker daemon is not running or you don't have permission."
    echo "   Try: sudo systemctl start docker"
    echo "   Or:  sudo usermod -aG docker \$USER (then re-login)"
    exit 1
fi

# ─── Step 1: Install prerequisites ──────────────────────────────────────

echo "📦 Step 1: Installing live-build and dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    live-build \
    debootstrap \
    syslinux-utils \
    isolinux \
    syslinux \
    syslinux-common \
    grub-pc-bin \
    grub-efi-amd64-bin \
    grub-efi-amd64-signed \
    shim-signed \
    xorriso \
    mtools \
    dosfstools \
    ubuntu-keyring

echo "   ✅ All dependencies installed"

# ─── Step 2: Build Blackgate Docker Image ───────────────────────────────

echo ""
echo "🐳 Step 2: Building Blackgate Docker Image..."
echo "   (This compiles Elixir, C, and React — may take a few minutes)"
cd "$PROJECT_ROOT"
docker build -t blackgate/app:latest .
echo "   ✅ Docker image built successfully"

# ─── Step 3: Prepare live-build ─────────────────────────────────────────

echo ""
echo "🏗️  Step 3: Preparing live-build environment for Ubuntu Jammy..."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

lb config \
    --mode debian \
    --system live \
    --mirror-bootstrap "http://id.archive.ubuntu.com/ubuntu/" \
    --mirror-chroot "http://id.archive.ubuntu.com/ubuntu/" \
    --mirror-binary "http://id.archive.ubuntu.com/ubuntu/" \
    --security false \
    --distribution jammy \
    --bootloader syslinux \
    --binary-images iso \
    --linux-packages linux-image \
    --linux-flavours generic \
    --firmware-binary false \
    --firmware-chroot false \
    --initsystem systemd \
    --archive-areas "main restricted universe multiverse" \
    --memtest none \
    --iso-application "Blackgate Server" \
    --iso-preparer "Visual Alchemy" \
    --iso-publisher "Visual Alchemy" \
    --iso-volume "BLACKGATE-${VERSION}"

echo "   ✅ live-build configured"

# ─── Step 4: Copy configuration files ──────────────────────────────────

echo ""
echo "📋 Step 4: Copying configuration files..."

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
echo "   Docker image size: $(du -h config/includes.chroot/opt/blackgate/blackgate-image.tar.gz | cut -f1)"

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

echo "   ✅ All configuration files copied"

# ─── Step 4.5: Fix ISOLINUX paths for Ubuntu ────────────────────────────

echo ""
echo "🔧 Step 4.5: Setting up ISOLINUX boot files..."

# live-build in debian mode expects isolinux files at /root/isolinux/
# but Ubuntu installs them to /usr/lib/ISOLINUX/ and /usr/lib/syslinux/modules/bios/
sudo mkdir -p /root/isolinux

# Copy isolinux.bin from the isolinux package
if [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
    sudo cp /usr/lib/ISOLINUX/isolinux.bin /root/isolinux/
    echo "   Copied isolinux.bin"
fi

# Copy syslinux modules (vesamenu.c32, ldlinux.c32, libutil.c32, etc.)
if [ -d /usr/lib/syslinux/modules/bios ]; then
    sudo cp /usr/lib/syslinux/modules/bios/*.c32 /root/isolinux/
    echo "   Copied syslinux .c32 modules"
fi

# Also copy from syslinux-common if available
if [ -d /usr/share/syslinux ]; then
    sudo cp /usr/share/syslinux/vesamenu.c32 /root/isolinux/ 2>/dev/null || true
    sudo cp /usr/share/syslinux/menu.c32 /root/isolinux/ 2>/dev/null || true
fi

echo "   Contents of /root/isolinux/:"
ls -la /root/isolinux/

# ─── Step 5: Build ISO ──────────────────────────────────────────────────

echo ""
echo "🔥 Step 5: Building ISO (this takes ~10 minutes)..."
echo "   Full output below:"
echo "   ─────────────────────────────────────────────────────"
sudo lb build 2>&1
echo "   ─────────────────────────────────────────────────────"

# ─── Step 5.5: Diagnostics ──────────────────────────────────────────────

echo ""
echo "🔍 Step 5.5: Checking build output..."

# Show what files were produced
echo "   ISO files found:"
ls -lh *.iso 2>/dev/null || echo "   (none at top level)"

echo "   Checking for boot directories:"
ls -la binary/isolinux/ 2>/dev/null && echo "   ✅ isolinux directory exists" || echo "   ⚠️ No isolinux directory"
ls -la binary/boot/grub/ 2>/dev/null && echo "   ✅ grub directory exists" || echo "   ⚠️ No grub directory"

# Find the ISO file
ISO_FILE=""
for f in binary.hybrid.iso binary.iso live-image-amd64.hybrid.iso live-image-amd64.iso; do
    if [ -f "$f" ]; then
        ISO_FILE="$f"
        echo "   Found ISO: $f"
        break
    fi
done

if [ -z "$ISO_FILE" ]; then
    echo "   Searching for any .iso file..."
    ISO_FILE=$(find . -maxdepth 1 -name "*.iso" -print -quit)
    if [ -n "$ISO_FILE" ]; then
        echo "   Found ISO: $ISO_FILE"
    fi
fi

# ─── Step 6: Validate & Move output ────────────────────────────────────

echo ""
echo "📀 Step 6: Collecting output..."
mkdir -p "$SCRIPT_DIR/output"

if [ -n "$ISO_FILE" ] && [ -f "$ISO_FILE" ]; then
    # Show ISO info for debugging
    echo "   ISO file info:"
    file "$ISO_FILE"

    # Check for El Torito boot record
    echo "   Boot record check:"
    xorriso -indev "$ISO_FILE" -report_el_torito as_mkisofs 2>&1 | head -5 || true

    # Try to make it hybrid-bootable (adds MBR so it can boot from USB + CD)
    if command -v isohybrid &>/dev/null; then
        echo "   Attempting to make ISO hybrid-bootable..."
        if isohybrid "$ISO_FILE" 2>&1; then
            echo "   ✅ ISO is now hybrid-bootable (USB + CD-ROM)"
        else
            echo "   ⚠️ isohybrid failed — ISO will still boot as CD-ROM"
        fi
    fi

    mv "$ISO_FILE" "$SCRIPT_DIR/output/${OUTPUT_NAME}.iso"
fi

ISO_PATH="$SCRIPT_DIR/output/${OUTPUT_NAME}.iso"

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(du -h "$ISO_PATH" | cut -f1)
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  ✅ ISO built successfully!"
    echo "  📀 File: $ISO_PATH"
    echo "  📏 Size: $ISO_SIZE"
    echo ""
    echo "  To copy to Proxmox ISO storage:"
    echo "    scp $ISO_PATH root@<proxmox-ip>:/var/lib/vz/template/iso/"
    echo "═══════════════════════════════════════════════════════════"
else
    echo ""
    echo "❌ ISO build failed — no output file found"
    echo ""
    echo "   Build directory contents:"
    ls -la "$BUILD_DIR/"
    echo ""
    echo "   Looking for any ISO files recursively:"
    find "$BUILD_DIR" -name "*.iso" -ls 2>/dev/null
    echo ""
    echo "   Check the full build log above for errors."
    exit 1
fi
