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
    echo "   sudo systemctl start docker"
    echo "   sudo usermod -aG docker \$USER"
    exit 1
fi

# ─── Step 1: Install prerequisites ──────────────────────────────────────

echo "📦 Step 1: Installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    live-build debootstrap \
    syslinux-utils isolinux syslinux syslinux-common \
    xorriso mtools dosfstools \
    squashfs-tools \
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

# Use --bootloader "none" to skip live-build's broken syslinux integration.
# We'll set up ISOLINUX manually after the build.
lb config \
    --mode debian \
    --system live \
    --mirror-bootstrap "http://id.archive.ubuntu.com/ubuntu/" \
    --mirror-chroot "http://id.archive.ubuntu.com/ubuntu/" \
    --mirror-binary "http://id.archive.ubuntu.com/ubuntu/" \
    --security false \
    --distribution jammy \
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

echo "   ✅ live-build configured (no bootloader — we'll add ISOLINUX manually)"

# ─── Step 4: Copy configuration files ──────────────────────────────────

echo ""
echo "📋 Step 4: Copying configuration files..."

mkdir -p config/package-lists
cp "$SCRIPT_DIR/config/package-lists/blackgate.list.chroot" config/package-lists/

mkdir -p config/includes.chroot/opt/blackgate
mkdir -p config/includes.chroot/etc/systemd/system
mkdir -p config/includes.chroot/etc/ssh/sshd_config.d
mkdir -p config/includes.chroot/etc/sysctl.d
mkdir -p config/includes.chroot/var/lib/blackgate

echo "   Exporting Docker image to tar..."
docker save blackgate/app:latest | gzip > config/includes.chroot/opt/blackgate/blackgate-image.tar.gz
echo "   Docker image size: $(du -h config/includes.chroot/opt/blackgate/blackgate-image.tar.gz | cut -f1)"

cp "$SCRIPT_DIR/config/includes.chroot/opt/blackgate/docker-compose.yml" config/includes.chroot/opt/blackgate/
cp "$SCRIPT_DIR/config/includes.chroot/etc/systemd/system/blackgate.service" config/includes.chroot/etc/systemd/system/
cp "$SCRIPT_DIR/config/includes.chroot/etc/ssh/sshd_config.d/99-blackgate.conf" config/includes.chroot/etc/ssh/sshd_config.d/
cp "$SCRIPT_DIR/config/includes.chroot/etc/sysctl.d/99-blackgate.conf" config/includes.chroot/etc/sysctl.d/
cp "$SCRIPT_DIR/config/includes.chroot/etc/motd" config/includes.chroot/etc/
cp "$SCRIPT_DIR/config/includes.chroot/etc/issue" config/includes.chroot/etc/

mkdir -p config/hooks/live
cp "$SCRIPT_DIR/config/hooks/live/0100-setup.hook.chroot" config/hooks/live/
chmod +x config/hooks/live/*.hook.chroot

echo "   ✅ All configuration files copied"

# ─── Step 5: Build filesystem with live-build ────────────────────────────

echo ""
echo "� Step 5: Building live filesystem (this takes ~10 minutes)..."
sudo lb build 2>&1
echo ""

# ─── Step 6: Create bootable ISO manually ───────────────────────────────

echo "🔧 Step 6: Creating bootable ISO with ISOLINUX..."

# Check that live-build produced the binary directory
if [ ! -d "binary" ]; then
    echo "❌ live-build did not create binary/ directory"
    ls -la
    exit 1
fi

# Set up ISOLINUX boot directory in the binary staging area
mkdir -p binary/isolinux

# Copy ISOLINUX binary
cp /usr/lib/ISOLINUX/isolinux.bin binary/isolinux/
echo "   Copied isolinux.bin"

# Copy syslinux modules
for f in ldlinux.c32 libutil.c32 libcom32.c32 vesamenu.c32 menu.c32; do
    if [ -f "/usr/lib/syslinux/modules/bios/$f" ]; then
        cp "/usr/lib/syslinux/modules/bios/$f" binary/isolinux/
    fi
done
echo "   Copied syslinux .c32 modules"

# Find the kernel and initrd that live-build placed
VMLINUZ=$(find binary -name "vmlinuz*" -o -name "vmlinuz" | head -1)
INITRD=$(find binary -name "initrd*" -o -name "initrd.img*" | head -1)

if [ -z "$VMLINUZ" ]; then
    echo "   Looking for kernel in casper/..."
    VMLINUZ="binary/casper/vmlinuz"
    INITRD="binary/casper/initrd"
fi

echo "   Kernel: $VMLINUZ"
echo "   Initrd: $INITRD"

# Get relative paths for ISOLINUX config
VMLINUZ_REL=$(echo "$VMLINUZ" | sed 's|^binary/||')
INITRD_REL=$(echo "$INITRD" | sed 's|^binary/||')

# Create ISOLINUX boot config
cat > binary/isolinux/isolinux.cfg << ISOLINUX_EOF
DEFAULT blackgate
TIMEOUT 30
PROMPT 0

LABEL blackgate
    MENU LABEL Blackgate Server v${VERSION}
    KERNEL /${VMLINUZ_REL}
    APPEND initrd=/${INITRD_REL} boot=casper quiet splash ---
    
LABEL blackgate-safe
    MENU LABEL Blackgate Server (Safe Mode)
    KERNEL /${VMLINUZ_REL}
    APPEND initrd=/${INITRD_REL} boot=casper nomodeset ---
ISOLINUX_EOF

echo "   Created isolinux.cfg"
echo "   Boot files:"
ls -la binary/isolinux/

# Create the bootable ISO with xorriso
echo ""
echo "   Creating ISO with xorriso..."
mkdir -p "$SCRIPT_DIR/output"

xorriso -as mkisofs \
    -r -J \
    -V "BLACKGATE-${VERSION}" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -o "$SCRIPT_DIR/output/${OUTPUT_NAME}.iso" \
    binary/

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
