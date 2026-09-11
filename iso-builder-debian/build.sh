#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOWNLOADS_DIR="$(dirname "$PROJECT_ROOT")"
SOURCE_ISO="${BLACKGATE_DEBIAN_SOURCE_ISO:-$DOWNLOADS_DIR/debian-13.6.0-amd64-netinst.iso}"
DESKTOPVIDEO_DEB="${BLACKGATE_DESKTOPVIDEO_DEB:-$DOWNLOADS_DIR/Blackmagic_Desktop_Video_Linux_16.0.1/deb/x86_64/desktopvideo_16.0.1a2_amd64.deb}"
RELEASE_TARBALL="${BLACKGATE_DEBIAN_RELEASE:-$SCRIPT_DIR/files/blackgate-release-debian13.tar.gz}"
OUTPUT_ISO="$SCRIPT_DIR/output/blackgate-debian13-installer-amd64.iso"
CACHE_DIR="${BLACKGATE_DEBIAN_CACHE:-$SCRIPT_DIR/cache/debs}"
WORK_DIR="$(mktemp -d)"
EXTRACT_DIR="$WORK_DIR/iso"
XORRISO_ROOT="$WORK_DIR/xorriso"
XORRISO_BIN="$XORRISO_ROOT/usr/bin/xorriso"
PROFILE_TOOL="$WORK_DIR/decklink-profile-config"
APT_LIST="$WORK_DIR/debian-trixie.list"
APT_LISTS="$WORK_DIR/apt-lists"
RELEASE_STAGE="$WORK_DIR/release-stage"
CLEAN_RELEASE="$WORK_DIR/blackgate-release.tar.gz"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

for file in "$SOURCE_ISO" "$DESKTOPVIDEO_DEB" "$RELEASE_TARBALL" \
  "$SCRIPT_DIR/preseed.cfg" "$SCRIPT_DIR/offline-packages.txt"; do
    [ -f "$file" ] || { echo "Missing required file: $file"; exit 1; }
done

for command in apt-get dpkg-deb dpkg-scanpackages g++ rsync; do
    command -v "$command" >/dev/null || { echo "Missing host command: $command"; exit 1; }
done

mkdir -p "$CACHE_DIR/partial" "$XORRISO_ROOT"
mkdir -p "$APT_LISTS/partial"

echo "Building private xorriso..."
(
    cd "$WORK_DIR"
    apt-get download xorriso libisoburn1t64 libburn4t64 libisofs6t64
    for deb in ./*.deb; do dpkg-deb -x "$deb" "$XORRISO_ROOT"; done
)
export LD_LIBRARY_PATH="$XORRISO_ROOT/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cat > "$APT_LIST" <<'EOF'
deb [trusted=yes] https://deb.debian.org/debian trixie main non-free-firmware
EOF

mapfile -t packages < <(grep -Ev '^[[:space:]]*(#|$)' "$SCRIPT_DIR/offline-packages.txt")
echo "Downloading Debian 13 offline package closure..."
apt-get \
    -o Debug::NoLocking=true \
    -o Dir::State::status=/dev/null \
    -o Dir::State::lists="$APT_LISTS" \
    -o Dir::Etc::sourcelist="$APT_LIST" \
    -o Dir::Etc::sourceparts=- \
    -o Dir::Cache::archives="$CACHE_DIR" \
    -o APT::Architecture=amd64 \
    -o Acquire::Languages=none update
apt-get \
    -o Debug::NoLocking=true \
    -o Dir::State::status=/dev/null \
    -o Dir::State::lists="$APT_LISTS" \
    -o Dir::Etc::sourcelist="$APT_LIST" \
    -o Dir::Etc::sourceparts=- \
    -o Dir::Cache::archives="$CACHE_DIR" \
    -o APT::Architecture=amd64 \
    -o Acquire::Languages=none \
    --download-only --no-install-recommends -y install "${packages[@]}"

echo "Compiling DeckLink profile utility..."
g++ -std=c++11 \
    -I "$PROJECT_ROOT/native/decklink-sdk" \
    "$SCRIPT_DIR/tools/decklink-profile-config.cpp" \
    "$PROJECT_ROOT/native/decklink-sdk/DeckLinkAPIDispatch.cpp" \
    -ldl -lpthread -o "$PROFILE_TOOL"

echo "Sanitizing Debian release payload..."
mkdir -p "$RELEASE_STAGE"
tar xzf "$RELEASE_TARBALL" -C "$RELEASE_STAGE"
rm -rf "$RELEASE_STAGE/blackgate/tmp"
tar czf "$CLEAN_RELEASE" -C "$RELEASE_STAGE" blackgate

echo "Extracting Debian netinst ISO..."
mkdir -p "$EXTRACT_DIR"
"$XORRISO_BIN" -osirrox on -indev "$SOURCE_ISO" -extract / "$EXTRACT_DIR" >/dev/null
chmod -R u+w "$EXTRACT_DIR"

mkdir -p "$EXTRACT_DIR/blackgate/offline-repo"
cp "$SCRIPT_DIR/preseed.cfg" "$EXTRACT_DIR/preseed.cfg"
cp "$CLEAN_RELEASE" "$EXTRACT_DIR/blackgate/blackgate-release.tar.gz"
cp "$DESKTOPVIDEO_DEB" "$EXTRACT_DIR/blackgate/desktopvideo_16.0.1a2_amd64.deb"
cp "$PROFILE_TOOL" "$EXTRACT_DIR/blackgate/decklink-profile-config"
cp "$SCRIPT_DIR/files/blackgate-firstboot.sh" "$EXTRACT_DIR/blackgate/"
cp "$SCRIPT_DIR/files/blackgate-firstboot.service" "$EXTRACT_DIR/blackgate/"
cp "$SCRIPT_DIR/files/blackgate.service" "$EXTRACT_DIR/blackgate/"
cp "$SCRIPT_DIR/files/99-blackgate-login-info.sh" "$EXTRACT_DIR/blackgate/"
find "$CACHE_DIR" -maxdepth 1 -type f -name '*.deb' -exec cp -t "$EXTRACT_DIR/blackgate/offline-repo" {} +

(
    cd "$EXTRACT_DIR/blackgate/offline-repo"
    dpkg-scanpackages . /dev/null > Packages
    gzip -9c Packages > Packages.gz
)

cat > "$EXTRACT_DIR/isolinux/txt.cfg" <<'EOF'
label install
  menu label ^Install Blackgate Debian Appliance
  kernel /install.amd/vmlinuz
  append auto=true priority=critical preseed/file=/cdrom/preseed.cfg --- quiet
EOF

cat > "$EXTRACT_DIR/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=5
if loadfont /boot/grub/font.pf2; then
  set gfxmode=800x600
  set gfxpayload=keep
  terminal_output gfxterm
fi
menuentry 'Install Blackgate Debian Appliance' {
  linux /install.amd/vmlinuz auto=true priority=critical preseed/file=/cdrom/preseed.cfg --- quiet
  initrd /install.amd/initrd.gz
}
menuentry 'Install Blackgate Debian Appliance (safe graphics)' {
  linux /install.amd/vmlinuz auto=true priority=critical preseed/file=/cdrom/preseed.cfg nomodeset --- quiet
  initrd /install.amd/initrd.gz
}
EOF

(
    cd "$EXTRACT_DIR"
    find . -type f ! -name md5sum.txt -print0 | sort -z | xargs -0 md5sum > md5sum.txt
)

mkdir -p "$SCRIPT_DIR/output"
rm -f "$OUTPUT_ISO" "$OUTPUT_ISO.sha256"
echo "Repacking Debian BIOS+UEFI installer ISO..."
"$XORRISO_BIN" -as mkisofs \
    -r -V BLACKGATE_DEBIAN13 \
    --isohybrid-mbr --interval:local_fs:0s-15s:zero_mbrpt,zero_gpt,zero_apm:"$SOURCE_ISO" \
    -partition_cyl_align on -partition_offset 0 -partition_hd_cyl 64 -partition_sec_hd 32 \
    --mbr-force-bootable -apm-block-size 2048 -iso_mbr_part_type 0x00 \
    -c /isolinux/boot.cat -b /isolinux/isolinux.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e /boot/grub/efi.img -no-emul-boot -boot-load-size 7360 \
    -isohybrid-gpt-basdat -isohybrid-apm-hfsplus \
    -o "$OUTPUT_ISO" "$EXTRACT_DIR"

sha256sum "$OUTPUT_ISO" > "$OUTPUT_ISO.sha256"
echo "Built: $OUTPUT_ISO"
echo "SHA256: $(cut -d' ' -f1 "$OUTPUT_ISO.sha256")"
