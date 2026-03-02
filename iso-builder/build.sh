#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UBUNTU_ISO="$SCRIPT_DIR/ubuntu-22.04.5-live-server-amd64.iso"
OUTPUT_ISO="$SCRIPT_DIR/output/blackgate-installer-amd64.iso"
WORK_DIR="$(mktemp -d)"
EXTRACT_DIR="$WORK_DIR/iso-extract"
DOCKER_PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "═══════════════════════════════════════════════════════════"
echo "  Blackgate Installer ISO Builder"
echo "═══════════════════════════════════════════════════════════"

# ─── Pre-flight checks ──────────────────────────────────────────────────

if [ "$EUID" -eq 0 ]; then
    echo "❌ Do not run as root."
    exit 1
fi

if [ ! -f "$UBUNTU_ISO" ]; then
    echo "❌ Ubuntu ISO not found: $UBUNTU_ISO"
    exit 1
fi

if ! command -v xorriso &>/dev/null; then
    echo "❌ xorriso not found: sudo apt-get install -y xorriso"
    exit 1
fi

if ! command -v mkfs.vfat &>/dev/null; then
    echo "❌ mkfs.vfat not found: sudo apt-get install -y dosfstools"
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "❌ Docker not running or no permission."
    exit 1
fi

# Verify all required files exist
REQUIRED=(
    "autoinstall/user-data"
    "autoinstall/meta-data"
    "files/docker-compose.yml"
    "files/blackgate.service"
    "files/daemon.json"
    "files/blackgate-firstboot.sh"
    "files/blackgate-firstboot.service"
    "files/99-blackgate-motd.sh"
)
for f in "${REQUIRED[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$f" ]; then
        echo "❌ Missing required file: $f"
        exit 1
    fi
done

echo "✅ Pre-flight checks passed"

# ─── Step 1: Build Docker image ─────────────────────────────────────────

echo ""
echo "🐳 Step 1: Building Blackgate Docker image..."
cd "$DOCKER_PROJECT_ROOT"
docker build -t blackgate/app:latest .
docker save blackgate/app:latest | gzip > "$SCRIPT_DIR/files/blackgate-image.tar.gz"
echo "   Image size: $(du -h "$SCRIPT_DIR/files/blackgate-image.tar.gz" | cut -f1)"

# ─── Step 2: Extract Ubuntu ISO ─────────────────────────────────────────

echo ""
echo "📦 Step 2: Extracting Ubuntu ISO..."
mkdir -p "$EXTRACT_DIR"
xorriso -osirrox on -indev "$UBUNTU_ISO" -extract / "$EXTRACT_DIR" 2>/dev/null
chmod -R u+w "$EXTRACT_DIR"
echo "   ✅ Extracted"

# ─── Step 3: Inject autoinstall config ──────────────────────────────────

echo ""
echo "💉 Step 3: Injecting autoinstall config..."
mkdir -p "$EXTRACT_DIR/nocloud"
cp "$SCRIPT_DIR/autoinstall/user-data" "$EXTRACT_DIR/nocloud/user-data"
cp "$SCRIPT_DIR/autoinstall/meta-data" "$EXTRACT_DIR/nocloud/meta-data"
echo "   ✅ user-data & meta-data injected"

# ─── Step 4: Copy Blackgate payload files ───────────────────────────────

echo ""
echo "📋 Step 4: Copying Blackgate files..."
mkdir -p "$EXTRACT_DIR/blackgate"
for f in \
    blackgate-image.tar.gz \
    docker-compose.yml \
    blackgate.service \
    blackgate-firstboot.sh \
    blackgate-firstboot.service \
    daemon.json \
    99-blackgate-motd.sh; do
    cp "$SCRIPT_DIR/files/$f" "$EXTRACT_DIR/blackgate/$f"
    echo "   ✅ $f ($(du -h "$SCRIPT_DIR/files/$f" | cut -f1))"
done

# ─── Step 5: Patch GRUB ─────────────────────────────────────────────────

echo ""
echo "🥾 Step 5: Patching GRUB..."
GRUB_CFG="$EXTRACT_DIR/boot/grub/grub.cfg"
cp "$GRUB_CFG" "$GRUB_CFG.bak"

cat > "$GRUB_CFG" << 'GRUBEOF'
set default="0"
set timeout=5

loadfont unicode
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Install Blackgate Server" {
    set gfxpayload=keep
    linux   /casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/nocloud/ ---
    initrd  /casper/initrd
}

menuentry "Install Blackgate Server (Safe Mode)" {
    set gfxpayload=keep
    linux   /casper/vmlinuz nomodeset autoinstall ds=nocloud\;s=/cdrom/nocloud/ ---
    initrd  /casper/initrd
}
GRUBEOF
echo "   ✅ GRUB patched"

# ─── Step 6: Repack ISO ─────────────────────────────────────────────────

echo ""
echo "💿 Step 6: Repacking ISO..."
mkdir -p "$SCRIPT_DIR/output"

MBR_IMG="$WORK_DIR/mbr.img"
EFI_IMG="$WORK_DIR/efi.img"

# Extract MBR (first 432 bytes) from original Ubuntu ISO
dd if="$UBUNTU_ISO" bs=1 count=432 of="$MBR_IMG" 2>/dev/null
echo "   ✅ MBR extracted"

# Extract EFI partition using offset reported by xorriso
EFI_INTERVAL=$(xorriso -indev "$UBUNTU_ISO" -report_el_torito as_mkisofs 2>/dev/null \
    | grep -oP -- '--interval:\S+' | head -1)

echo "   EFI interval: $EFI_INTERVAL"

EFI_START=$(echo "$EFI_INTERVAL" | grep -oP 'start_\K[0-9]+(?=s)')
EFI_SIZE=$(echo  "$EFI_INTERVAL" | grep -oP 'size_\K[0-9]+(?=s)')

if [ -n "$EFI_START" ] && [ -n "$EFI_SIZE" ]; then
    dd if="$UBUNTU_ISO" bs=512 skip="$EFI_START" count="$EFI_SIZE" of="$EFI_IMG" 2>/dev/null
    echo "   ✅ EFI partition extracted ($(du -h "$EFI_IMG" | cut -f1))"
else
    # Fallback: create minimal FAT EFI image
    echo "   ⚠️  EFI interval not parsed, creating fallback EFI image..."
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=4 2>/dev/null
    mkfs.vfat "$EFI_IMG" 2>/dev/null
fi

xorriso -as mkisofs \
    -r \
    -V "BLACKGATE_INSTALLER" \
    --grub2-mbr "$MBR_IMG" \
    --protective-msdos-label \
    -partition_cyl_align off \
    -partition_offset 16 \
    -appended_part_as_gpt \
    -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$EFI_IMG" \
    -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
    -c '/boot.catalog' \
    -b '/boot/grub/i386-pc/eltorito.img' \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    --grub2-boot-info \
    -eltorito-alt-boot \
    -e '--interval:appended_partition_2:::' \
    -no-emul-boot \
    -o "$OUTPUT_ISO" \
    "$EXTRACT_DIR/"

rm -rf "$WORK_DIR"

# ─── Done ───────────────────────────────────────────────────────────────

if [ -f "$OUTPUT_ISO" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  ✅ ISO ready!"
    echo "  📀 File : $OUTPUT_ISO"
    echo "  📏 Size : $(du -h "$OUTPUT_ISO" | cut -f1)"
    echo ""
    echo "  Copy to Proxmox:"
    echo "  scp $OUTPUT_ISO root@<proxmox-ip>:/var/lib/vz/template/iso/"
    echo "═══════════════════════════════════════════════════════════"
else
    echo "❌ ISO creation failed"
    rm -rf "$WORK_DIR"
    exit 1
fi
