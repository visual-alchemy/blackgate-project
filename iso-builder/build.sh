#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOWNLOADS_DIR="$(dirname "$PROJECT_ROOT")"
UBUNTU_ISO="${BLACKGATE_SOURCE_ISO:-$DOWNLOADS_DIR/ubuntu-24.04.4-live-server-amd64.iso}"
DESKTOPVIDEO_DEB="${BLACKGATE_DESKTOPVIDEO_DEB:-$DOWNLOADS_DIR/Blackmagic_Desktop_Video_Linux_16.0.1/deb/x86_64/desktopvideo_16.0.1a2_amd64.deb}"
OUTPUT_ISO="$SCRIPT_DIR/output/blackgate-installer-amd64.iso"
WORK_DIR="$(mktemp -d)"
EXTRACT_DIR="$WORK_DIR/iso-extract"
PROFILE_TOOL="$WORK_DIR/decklink-profile-config"
PROJECT_BUILD_DIR="$WORK_DIR/project-build"
OFFLINE_PACKAGE_LIST="$SCRIPT_DIR/offline-packages.txt"
OFFLINE_CACHE_DIR="${BLACKGATE_OFFLINE_CACHE_DIR:-$SCRIPT_DIR/cache/offline-packages}"
OFFLINE_REPO_DIR="$EXTRACT_DIR/blackgate/offline-repo"
XORRISO_BIN="$(command -v xorriso || true)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "═══════════════════════════════════════════════════════════"
echo "  Blackgate Installer ISO Builder (Bare-metal)"
echo "═══════════════════════════════════════════════════════════"

# ─── Pre-flight checks ──────────────────────────────────────────────────

if [ "$EUID" -eq 0 ]; then
    echo "❌ Do not run as root."
    exit 1
fi

if [ ! -f "$UBUNTU_ISO" ]; then
    echo "❌ Ubuntu 24.04 ISO not found: $UBUNTU_ISO"
    exit 1
fi

if [ ! -f "$DESKTOPVIDEO_DEB" ]; then
    echo "❌ Desktop Video driver not found: $DESKTOPVIDEO_DEB"
    exit 1
fi

if ! command -v mkfs.vfat &>/dev/null; then
    echo "❌ mkfs.vfat not found: sudo apt-get install -y dosfstools"
    exit 1
fi

if ! command -v g++ &>/dev/null; then
    echo "❌ g++ not found: sudo apt-get install -y g++"
    exit 1
fi

if ! command -v rsync &>/dev/null; then
    echo "❌ rsync not found: sudo apt-get install -y rsync"
    exit 1
fi

if ! command -v apt-get &>/dev/null; then
    echo "❌ apt-get not found (required to assemble offline package repository)"
    exit 1
fi

if ! command -v dpkg-scanpackages &>/dev/null; then
    echo "❌ dpkg-scanpackages not found: sudo apt-get install -y dpkg-dev"
    exit 1
fi

if [ -z "$XORRISO_BIN" ]; then
    echo "   xorriso not installed; staging private copy..."
    XORRISO_ROOT="$WORK_DIR/xorriso-root"
    mkdir -p "$XORRISO_ROOT"
    (
        cd "$WORK_DIR"
        apt-get download xorriso libisoburn1t64 libburn4t64 libisofs6t64
        for deb in ./*.deb; do
            dpkg-deb -x "$deb" "$XORRISO_ROOT"
        done
    )
    XORRISO_BIN="$XORRISO_ROOT/usr/bin/xorriso"
    export LD_LIBRARY_PATH="$XORRISO_ROOT/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Verify all required files exist
REQUIRED=(
    "autoinstall/user-data"
    "autoinstall/meta-data"
    "offline-packages.txt"
    "files/blackgate.service"
    "files/blackgate-firstboot.sh"
    "files/blackgate-firstboot.service"
    "files/99-blackgate-motd.sh"
    "files/blackgate-system-action"
    "files/blackgate-system-action.sudoers"
)
for f in "${REQUIRED[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$f" ]; then
        echo "❌ Missing required file: $f"
        exit 1
    fi
done

echo "✅ Pre-flight checks passed"

# ─── Step 0: Assemble local APT repository ──────────────────────────────

echo ""
echo "📦 Step 0: Assembling offline Ubuntu package repository..."
mkdir -p "$OFFLINE_CACHE_DIR/partial"

mapfile -t OFFLINE_PACKAGES < <(grep -Ev '^[[:space:]]*(#|$)' "$OFFLINE_PACKAGE_LIST")
if [ "${#OFFLINE_PACKAGES[@]}" -eq 0 ]; then
    echo "❌ Offline package list is empty: $OFFLINE_PACKAGE_LIST"
    exit 1
fi

apt-get \
    -o Debug::NoLocking=true \
    -o Dir::State::status=/dev/null \
    -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources \
    -o Dir::Etc::sourceparts=- \
    -o Dir::Cache::archives="$OFFLINE_CACHE_DIR" \
    -o APT::Architecture=amd64 \
    -o Acquire::Languages=none \
    --download-only \
    --no-install-recommends \
    -y install "${OFFLINE_PACKAGES[@]}"

OFFLINE_DEB_COUNT=$(find "$OFFLINE_CACHE_DIR" -maxdepth 1 -type f -name '*.deb' | wc -l)
if [ "$OFFLINE_DEB_COUNT" -eq 0 ]; then
    echo "❌ Offline package download produced no .deb files"
    exit 1
fi
echo "   ✅ $OFFLINE_DEB_COUNT packages cached ($(du -sh "$OFFLINE_CACHE_DIR" | cut -f1))"

# ─── Step 1: Build release and DeckLink profile utility ────────────────

echo ""
echo "🔨 Step 1: Building Blackgate Elixir release..."
echo "   Creating isolated build tree (live installation remains untouched)..."
mkdir -p "$PROJECT_BUILD_DIR"
rsync -a \
    --exclude='.git/' \
    --exclude='iso-builder/output/' \
    --exclude='iso-builder/files/blackgate-release.tar.gz' \
    "$PROJECT_ROOT/" "$PROJECT_BUILD_DIR/"

cd "$PROJECT_BUILD_DIR"
make build

RELEASE_DIR="$PROJECT_BUILD_DIR/_build/prod/rel/blackgate"
if [ ! -d "$RELEASE_DIR" ]; then
    echo "❌ Release directory not found: $RELEASE_DIR"
    exit 1
fi

echo "   Packaging release tarball..."
tar czf "$SCRIPT_DIR/files/blackgate-release.tar.gz" -C "$PROJECT_BUILD_DIR/_build/prod/rel" blackgate
echo "   Release size: $(du -h "$SCRIPT_DIR/files/blackgate-release.tar.gz" | cut -f1)"

echo "   Building headless DeckLink profile utility..."
g++ -std=c++11 \
    -I "$PROJECT_ROOT/native/decklink-sdk" \
    "$SCRIPT_DIR/tools/decklink-profile-config.cpp" \
    "$PROJECT_ROOT/native/decklink-sdk/DeckLinkAPIDispatch.cpp" \
    -ldl -lpthread -o "$PROFILE_TOOL"

# ─── Step 2: Extract Ubuntu ISO ─────────────────────────────────────────

echo ""
echo "📦 Step 2: Extracting Ubuntu ISO..."
mkdir -p "$EXTRACT_DIR"
"$XORRISO_BIN" -osirrox on -indev "$UBUNTU_ISO" -extract / "$EXTRACT_DIR" 2>/dev/null
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
    blackgate-release.tar.gz \
    blackgate.service \
    blackgate-firstboot.sh \
    blackgate-firstboot.service \
    99-blackgate-motd.sh \
    blackgate-system-action \
    blackgate-system-action.sudoers; do
    cp "$SCRIPT_DIR/files/$f" "$EXTRACT_DIR/blackgate/$f"
    echo "   ✅ $f ($(du -h "$SCRIPT_DIR/files/$f" | cut -f1))"
done
cp "$DESKTOPVIDEO_DEB" "$EXTRACT_DIR/blackgate/desktopvideo_16.0.1a2_amd64.deb"
cp "$PROFILE_TOOL" "$EXTRACT_DIR/blackgate/decklink-profile-config"
echo "   ✅ Desktop Video 16.0.1 driver"
echo "   ✅ DeckLink 2dhd profile utility"

echo "   Creating offline APT repository..."
mkdir -p "$OFFLINE_REPO_DIR"
find "$OFFLINE_CACHE_DIR" -maxdepth 1 -type f -name '*.deb' -exec cp -t "$OFFLINE_REPO_DIR" {} +

# Desktop Video DKMS requires kernel headers. Reuse exact kernel/header set
# shipped by source ISO instead of downloading newer kernel from a mirror.
find "$EXTRACT_DIR/pool" -type f \
    \( -name 'linux-headers-[0-9]*_*.deb' -o -name 'linux-headers-generic_*.deb' \) \
    -exec cp -t "$OFFLINE_REPO_DIR" {} +

(
    cd "$OFFLINE_REPO_DIR"
    dpkg-scanpackages . /dev/null > Packages
    gzip -9c Packages > Packages.gz
)
REPO_DEB_COUNT=$(find "$OFFLINE_REPO_DIR" -maxdepth 1 -type f -name '*.deb' | wc -l)
echo "   ✅ Offline APT repository ($REPO_DEB_COUNT packages)"

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

# Extract EFI partition using fdisk to read partition table from ISO
EFI_INFO=$(fdisk -l "$UBUNTU_ISO" 2>/dev/null | grep "EFI System")

if [ -z "$EFI_INFO" ]; then
    echo "❌ EFI partition not found in ISO partition table"
    rm -rf "$WORK_DIR"
    exit 1
fi

EFI_START=$(echo "$EFI_INFO" | awk '{print $2}')
EFI_END=$(echo   "$EFI_INFO" | awk '{print $3}')
EFI_SIZE=$(( EFI_END - EFI_START + 1 ))

echo "   EFI partition: start=${EFI_START} end=${EFI_END} size=${EFI_SIZE} sectors"
dd if="$UBUNTU_ISO" bs=512 skip="$EFI_START" count="$EFI_SIZE" of="$EFI_IMG" 2>/dev/null
echo "   ✅ EFI partition extracted ($(du -h "$EFI_IMG" | cut -f1))"

"$XORRISO_BIN" -as mkisofs \
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

# ─── Done ───────────────────────────────────────────────────────────────

if [ -f "$OUTPUT_ISO" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  ✅ ISO ready!"
    echo "  📀 File : $OUTPUT_ISO"
    echo "  📏 Size : $(du -h "$OUTPUT_ISO" | cut -f1)"
    sha256sum "$OUTPUT_ISO" > "$OUTPUT_ISO.sha256"
    echo "  🔐 SHA256: $(cut -d' ' -f1 "$OUTPUT_ISO.sha256")"
    echo ""
    echo "  Copy to Proxmox:"
    echo "  scp $OUTPUT_ISO root@<proxmox-ip>:/var/lib/vz/template/iso/"
    echo "═══════════════════════════════════════════════════════════"
else
    echo "❌ ISO creation failed"
    exit 1
fi
