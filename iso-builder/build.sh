#!/bin/bash
set -e

#
# Blackgate ISO Builder (Ubuntu 22.04)
# Builds a bootable Ubuntu Jammy ISO with Blackgate Docker image pre-installed.
#
# Usage:
#   ./build.sh                    # Build with default version 1.0.0
#   VERSION=2.0.0 ./build.sh      # Build with custom version
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build"
VERSION="${VERSION:-1.0.0}"
OUTPUT_NAME="blackgate-${VERSION}-amd64"

echo "═══════════════════════════════════════════════════════════"
echo "  Blackgate Server ISO Builder v${VERSION}"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ─── Pre-flight checks ─────────────────────────────────────────────────

if ! command -v docker &>/dev/null; then
    echo "❌ Docker is not installed."
    echo "   sudo apt-get install -y docker.io"
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "❌ Docker daemon not running or no permission."
    exit 1
fi

# ─── Step 1: Install prerequisites ──────────────────────────────────────

echo "📦 Step 1: Installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    live-build debootstrap \
    syslinux-utils isolinux syslinux syslinux-common \
    xorriso mtools dosfstools squashfs-tools \
    ubuntu-keyring

echo "   ✅ All dependencies installed"

# ─── Step 2: Build Blackgate Docker Image ───────────────────────────────

echo ""
echo "🐳 Step 2: Building Blackgate Docker Image..."
cd "$PROJECT_ROOT"
docker build -t blackgate/app:latest .
echo "   ✅ Docker image built"

# ─── Step 3: Prepare live-build ─────────────────────────────────────────

echo ""
echo "🏗️  Step 3: Preparing live-build..."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# KEY: --mode ubuntu + --bootloader none
# --mode ubuntu: avoids debian compatibility issues (broken syslinux themes, wrong kernel names)
# --bootloader none: completely skips lb_binary_syslinux (which has hardcoded broken paths)
# --binary-images none: skip ISO creation (we'll do it manually with xorriso)
# We handle ISOLINUX boot + ISO creation ourselves after the build.
lb config \
    --mode ubuntu \
    --system live \
    --bootloader none \
    --mirror-bootstrap "http://id.archive.ubuntu.com/ubuntu/" \
    --mirror-chroot "http://id.archive.ubuntu.com/ubuntu/" \
    --mirror-binary "http://id.archive.ubuntu.com/ubuntu/" \
    --security false \
    --distribution jammy \
    --binary-images none \
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

echo "   ✅ live-build configured (bootloader=none, we handle boot manually)"

# ─── Step 4: Copy configuration files ──────────────────────────────────

echo ""
echo "📋 Step 4: Copying configuration files..."

mkdir -p config/package-lists
cp "$SCRIPT_DIR/config/package-lists/blackgate.list.chroot" config/package-lists/

# Blackgate app
mkdir -p config/includes.chroot/opt/blackgate
mkdir -p config/includes.chroot/var/lib/blackgate
echo "   Exporting Docker image to tar..."
docker save blackgate/app:latest | gzip > config/includes.chroot/opt/blackgate/blackgate-image.tar.gz
echo "   Docker image size: $(du -h config/includes.chroot/opt/blackgate/blackgate-image.tar.gz | cut -f1)"
cp "$SCRIPT_DIR/config/includes.chroot/opt/blackgate/docker-compose.yml" \
   config/includes.chroot/opt/blackgate/

# Systemd services
mkdir -p config/includes.chroot/etc/systemd/system
cp "$SCRIPT_DIR/config/includes.chroot/etc/systemd/system/blackgate.service" \
   config/includes.chroot/etc/systemd/system/
cp "$SCRIPT_DIR/config/includes.chroot/etc/systemd/system/var-lib-docker.mount" \
   config/includes.chroot/etc/systemd/system/

# Docker daemon config
mkdir -p config/includes.chroot/etc/docker
cp "$SCRIPT_DIR/config/includes.chroot/etc/docker/daemon.json" \
   config/includes.chroot/etc/docker/

# Netplan
mkdir -p config/includes.chroot/etc/netplan
cp "$SCRIPT_DIR/config/includes.chroot/etc/netplan/01-blackgate.yaml" \
   config/includes.chroot/etc/netplan/

# SSH config
mkdir -p config/includes.chroot/etc/ssh/sshd_config.d
cp "$SCRIPT_DIR/config/includes.chroot/etc/ssh/sshd_config.d/99-blackgate.conf" \
   config/includes.chroot/etc/ssh/sshd_config.d/

# Sysctl
mkdir -p config/includes.chroot/etc/sysctl.d
cp "$SCRIPT_DIR/config/includes.chroot/etc/sysctl.d/99-blackgate.conf" \
   config/includes.chroot/etc/sysctl.d/

# MOTD & issue
cp "$SCRIPT_DIR/config/includes.chroot/etc/motd"  config/includes.chroot/etc/
cp "$SCRIPT_DIR/config/includes.chroot/etc/issue" config/includes.chroot/etc/

mkdir -p config/hooks/live
cp "$SCRIPT_DIR/config/hooks/live/0100-setup.hook.chroot" config/hooks/live/
chmod +x config/hooks/live/*.hook.chroot

echo "   ✅ All configuration files copied"

# ─── Step 5: Build live filesystem ──────────────────────────────────────

echo ""
echo "🔥 Step 5: Building live filesystem (this takes ~10 minutes)..."
sudo lb build 2>&1
echo ""
echo "   ✅ live-build completed"

# ─── Step 6: Create squashfs & ISO manually ─────────────────────────────

echo ""
echo "🔧 Step 6: Creating bootable ISO..."

# Create the staging directory for the ISO contents
ISO_STAGING="$BUILD_DIR/iso-staging"
rm -rf "$ISO_STAGING"
mkdir -p "$ISO_STAGING/casper"
mkdir -p "$ISO_STAGING/isolinux"
mkdir -p "$ISO_STAGING/.disk"

# Create the squashfs filesystem from the chroot
echo "   Creating squashfs filesystem (this takes a few minutes)..."
if [ -d "chroot" ]; then
    sudo mksquashfs chroot "$ISO_STAGING/casper/filesystem.squashfs" \
        -comp xz -e boot
    echo "   SquashFS size: $(du -h "$ISO_STAGING/casper/filesystem.squashfs" | cut -f1)"
else
    echo "❌ No chroot directory found. live-build failed to create filesystem."
    exit 1
fi

# Copy kernel and initrd from chroot
echo "   Copying kernel and initrd..."
VMLINUZ=$(find chroot/boot -name "vmlinuz-*" | sort -V | tail -1)
INITRD=$(find chroot/boot -name "initrd.img-*" | sort -V | tail -1)

if [ -z "$VMLINUZ" ] || [ -z "$INITRD" ]; then
    echo "❌ Could not find kernel/initrd in chroot/boot/"
    ls -la chroot/boot/
    exit 1
fi

sudo cp "$VMLINUZ" "$ISO_STAGING/casper/vmlinuz"
sudo cp "$INITRD" "$ISO_STAGING/casper/initrd"
echo "   Kernel: $VMLINUZ"
echo "   Initrd: $INITRD"

# Set up ISOLINUX boot files
echo "   Setting up ISOLINUX boot..."
cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_STAGING/isolinux/"

for f in ldlinux.c32 libutil.c32 libcom32.c32 vesamenu.c32 menu.c32; do
    if [ -f "/usr/lib/syslinux/modules/bios/$f" ]; then
        cp "/usr/lib/syslinux/modules/bios/$f" "$ISO_STAGING/isolinux/"
    fi
done

# Create ISOLINUX boot config
cat > "$ISO_STAGING/isolinux/isolinux.cfg" << 'ISOLINUX_EOF'
UI menu.c32
PROMPT 0
TIMEOUT 30
DEFAULT blackgate

MENU TITLE Blackgate Server Boot Menu

LABEL blackgate
    MENU LABEL ^Start Blackgate Server
    KERNEL /casper/vmlinuz
    APPEND initrd=/casper/initrd boot=casper quiet splash ignore_uuid cdrom-detect/try-usb=true noprompt ---

LABEL blackgate-safe
    MENU LABEL ^Safe Mode (no graphics)
    KERNEL /casper/vmlinuz
    APPEND initrd=/casper/initrd boot=casper nomodeset ignore_uuid cdrom-detect/try-usb=true noprompt ---
ISOLINUX_EOF

# Create disk info
echo "Blackgate Server ${VERSION}" > "$ISO_STAGING/.disk/info"
touch "$ISO_STAGING/.disk/base_installable"

# Generate filesystem manifest
sudo chroot chroot dpkg-query -W --showformat='${Package} ${Version}\n' \
    > "$ISO_STAGING/casper/filesystem.manifest" 2>/dev/null || true

echo "   ISO staging contents:"
find "$ISO_STAGING" -maxdepth 2 -type f | head -20

# Create the bootable ISO with xorriso
echo ""
echo "   Running xorriso to create bootable ISO..."
mkdir -p "$SCRIPT_DIR/output"

ISO_VOLUME="BLACKGATE_${VERSION//./_}"

# Fix permissions from sudo lb build
sudo chmod -R a+r "$ISO_STAGING/"

xorriso -as mkisofs \
    -r -J \
    -V "${ISO_VOLUME}" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -o "$SCRIPT_DIR/output/${OUTPUT_NAME}.iso" \
    "$ISO_STAGING/"

ISO_PATH="$SCRIPT_DIR/output/${OUTPUT_NAME}.iso"

if [ -f "$ISO_PATH" ]; then
    ISO_SIZE=$(du -h "$ISO_PATH" | cut -f1)
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  ✅ ISO built successfully!"
    echo "  📀 File: $ISO_PATH"
    echo "  📏 Size: $ISO_SIZE"
    echo ""
    echo "  Boot info:"
    file "$ISO_PATH"
    echo ""
    echo "  To copy to Proxmox ISO storage:"
    echo "    scp $ISO_PATH root@<proxmox-ip>:/var/lib/vz/template/iso/"
    echo "═══════════════════════════════════════════════════════════"
else
    echo "❌ ISO creation failed"
    exit 1
fi
