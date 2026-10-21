#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Any Ubuntu 24.04.x live-server ISO placed beside this script is accepted: point releases come and go,
# and hardcoding one name breaks the build the moment the operator downloaded another point release.
UBUNTU_ISO="${UBUNTU_ISO:-$(ls -1 "$SCRIPT_DIR"/ubuntu-24.04*-live-server-amd64.iso 2>/dev/null | head -1)}"
OUTPUT_ISO="$SCRIPT_DIR/output/blackgate-installer-amd64.iso"
WORK_DIR="$(mktemp -d)"
EXTRACT_DIR="$WORK_DIR/iso-extract"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

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
    echo "❌ No Ubuntu 24.04.x live-server ISO found in $SCRIPT_DIR"
    echo "   expected: ubuntu-24.04*-live-server-amd64.iso"
    exit 1
fi

for command_name in xorriso mkfs.vfat fdisk git meson ninja mix npm dpkg-scanpackages; do
    if ! command -v "$command_name" &>/dev/null; then
        echo "❌ $command_name not found; install ISO and Blackgate build dependencies"
        exit 1
    fi
done

# Verify all required files exist
REQUIRED=(
    "autoinstall/user-data"
    "autoinstall/meta-data"
    "files/blackgate.service"
    "files/blackgate-firstboot.sh"
    "files/blackgate-firstboot.service"
    "files/99-blackgate-motd.sh"
    "files/blackgate-system-action"
    "files/blackgate-system-action.sudoers"
    "files/blackgate-updater"
    "release-version"
    "files/support-authorized-keys"
    "packages.list"
)
for f in "${REQUIRED[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$f" ]; then
        echo "❌ Missing required file: $f"
        exit 1
    fi
done

echo "✅ Pre-flight checks passed"

# ─── Step 1: Build Elixir Release ───────────────────────────────────────

echo ""
echo "🔨 Step 1: Building Blackgate Elixir release..."
cd "$PROJECT_ROOT"
mix local.hex --force
mix local.rebar --force
MIX_ENV=prod mix deps.get
npm --prefix web_app ci
MIX_ENV=prod mix release --overwrite

RELEASE_DIR="$PROJECT_ROOT/_build/prod/rel/blackgate"
if [ ! -d "$RELEASE_DIR" ]; then
    echo "❌ Release directory not found: $RELEASE_DIR"
    exit 1
fi

if ! compgen -G "$RELEASE_DIR/erts-*" >/dev/null; then
    echo "❌ Bundled ERTS missing from release"
    exit 1
fi

if ! compgen -G "$RELEASE_DIR/lib/blackgate-*/priv/native/build/blackgate-engine" >/dev/null; then
    echo "❌ Rust engine missing from release"
    exit 1
fi

echo "   Packaging release tarball..."
tar czf "$SCRIPT_DIR/files/blackgate-release.tar.gz" -C "$PROJECT_ROOT/_build/prod/rel" blackgate
echo "   Release size: $(du -h "$SCRIPT_DIR/files/blackgate-release.tar.gz" | cut -f1)"

echo "   Building GStreamer 1.24.2 DeckLink plugin..."
git clone --depth 1 --branch 1.24.2 \
    https://gitlab.freedesktop.org/gstreamer/gstreamer.git \
    "$WORK_DIR/gstreamer"
meson setup "$WORK_DIR/gstreamer/subprojects/gst-plugins-bad/builddir" \
    "$WORK_DIR/gstreamer/subprojects/gst-plugins-bad" \
    -Ddecklink=enabled \
    -Dcpp_args="-I$PROJECT_ROOT/native/vendor/decklink-sdk" \
    --prefix=/usr
ninja -C "$WORK_DIR/gstreamer/subprojects/gst-plugins-bad/builddir" \
    sys/decklink/libgstdecklink.so
cp "$WORK_DIR/gstreamer/subprojects/gst-plugins-bad/builddir/sys/decklink/libgstdecklink.so" \
    "$SCRIPT_DIR/files/libgstdecklink.so"

# ─── Step 1b: Local package pool ────────────────────────────────────────
# The appliance has to install with no network at all, so the image carries the runtime packages listed in
# packages.list plus everything apt would pull for them, indexed as a local apt source.
#
# The closure is resolved against an EMPTY dpkg status on purpose: against this machine's own status apt
# answers "already installed" and the pool comes out a few MB short of what a fresh machine needs.
echo ""
echo "📦 Step 1b: Building the local package pool..."

POOL_DIR="$SCRIPT_DIR/files/pool"
# packages.list is the single source of truth for what the appliance needs at runtime: the pool below and
# the first-boot install both read it, and it is committed, so the two cannot drift.
PACKAGES_LIST="$SCRIPT_DIR/packages.list"
[ -f "$PACKAGES_LIST" ] || { echo "❌ missing $PACKAGES_LIST" >&2; exit 1; }

# Reuse a pool this build already produced for the same package list: the download is ~400 MB and a data
# change elsewhere in the tree should not pay for it again. A stale index or a different list rebuilds it.
# The cache key covers the list AND the apt options: changing either changes the pool, and silently reusing
# a pool built with different options is how a "slimmed" image ships with the old fat pool inside.
POOL_KEY="$( { md5sum "$PACKAGES_LIST"; echo "--no-install-recommends"; } | md5sum | cut -d' ' -f1 )"
POOL_STAMP="$POOL_DIR/.packages.key"
POOL_CACHE_OK=0
if [ -s "$POOL_DIR/Packages.gz" ] && [ -f "$POOL_STAMP" ] \
   && [ "$POOL_KEY" = "$(cat "$POOL_STAMP")" ] \
   && [ "$(ls "$POOL_DIR"/*.deb 2>/dev/null | wc -l)" = "$(zcat "$POOL_DIR/Packages.gz" | grep -c '^Package:')" ] \
   && [ "$(ls "$POOL_DIR"/*.deb 2>/dev/null | wc -l)" -gt 50 ]; then
    POOL_CACHE_OK=1
    echo "   reusing the pool from a previous build ($(ls "$POOL_DIR"/*.deb | wc -l) packages)"
fi

if [ "$POOL_CACHE_OK" = "0" ]; then
rm -rf "$POOL_DIR"
mkdir -p "$POOL_DIR"
# Debug::NoLocking: with the status file redirected, apt derives its lock from that path (/dev/lock-*)
# and refuses to run as an unprivileged user.
apt-get -o Dir::State::status=/dev/null -o Debug::NoLocking=1 -o Dir::Cache::archives="$POOL_DIR" \
    -y --no-install-recommends --download-only install $(tr '\n' ' ' < "$PACKAGES_LIST") \
    || { echo "❌ could not build the package pool — is /var/lib/apt/lists current? (apt-get update)" >&2; exit 1; }

command -v dpkg-scanpackages >/dev/null \
    || { echo "❌ dpkg-scanpackages missing (install dpkg-dev)" >&2; exit 1; }
# Run it from inside the pool: dpkg-scanpackages writes Filename relative to the directory it is given,
# and an absolute path there makes apt join the repo root twice (file:/pool/pool/x.deb).
(cd "$POOL_DIR" && dpkg-scanpackages -m . /dev/null 2>/dev/null | gzip -9 > Packages.gz)

# --no-install-recommends cuts the pool from ~380 MB to ~110 MB, which is only safe if the packages the
# appliance cannot start without are still in it: DKMS builds the decklink module (gcc/make/dpkg-dev are its
# Depends, not Recommends), and the media runtime needs the gstreamer plugins and libsrt.
# Decompress the index once, and say how many entries it had when it fails to match: a check that only
# reports "missing" cannot tell a short pool from an unreadable index.
POOL_INDEX="$(mktemp)"
zcat "$POOL_DIR/Packages.gz" > "$POOL_INDEX" 2>/dev/null || true
POOL_MISSING=""
for pkg in gcc make dpkg-dev dkms linux-headers-generic libgl1 gstreamer1.0-plugins-bad \
           gstreamer1.0-plugins-good gstreamer1.0-libav gstreamer1.0-vaapi libsrt1.5-gnutls \
           libcjson1 ffmpeg iproute2 curl; do
    grep -q "^Package: $pkg$" "$POOL_INDEX" || POOL_MISSING="$POOL_MISSING $pkg"
done
if [ -n "$POOL_MISSING" ]; then
    echo "❌ pool index has $(grep -c '^Package:' "$POOL_INDEX") entries and is missing:$POOL_MISSING" >&2
    rm -f "$POOL_INDEX"
    exit 1
fi
rm -f "$POOL_INDEX"
echo "   ✅ pool covers the critical packages"
echo "$POOL_KEY" > "$POOL_STAMP"
fi
echo "   pool: $(ls "$POOL_DIR"/*.deb | wc -l) packages, $(du -sh "$POOL_DIR" | cut -f1) (index $(du -sh "$POOL_DIR/Packages.gz" | cut -f1))"

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
    blackgate-release.tar.gz \
    blackgate.service \
    blackgate-firstboot.sh \
    blackgate-firstboot.service \
    99-blackgate-motd.sh \
    blackgate-system-action \
    blackgate-system-action.sudoers \
    blackgate-updater \
    support-authorized-keys \
    libgstdecklink.so; do
    cp "$SCRIPT_DIR/files/$f" "$EXTRACT_DIR/blackgate/$f"
    echo "   ✅ $f ($(du -h "$SCRIPT_DIR/files/$f" | cut -f1))"
done

# The release version lives at iso-builder/release-version (the packaging script, the installer and the
# ISO all read it there); the appliance gets it as /opt/blackgate/release-version, which is where first
# boot looks for it. Requiring it under files/ is what broke this pre-flight every single time.
cp "$SCRIPT_DIR/release-version" "$EXTRACT_DIR/blackgate/release-version"
echo "   ✅ release-version ($(tr -d '\r\n' < "$SCRIPT_DIR/release-version"))"

# The Blackmagic Desktop Video .deb (~250 MB) is what makes SDI work on a fresh appliance: without it the
# gateway runs but no frames reach the card. Vendor binary, so it is gitignored and the build only carries
# it when the operator put it beside the other payload files.
# The package pool and its index: the installed system keeps them as a local apt source (see the
# late-commands in autoinstall/user-data), which is what makes a first boot without network possible.
mkdir -p "$EXTRACT_DIR/blackgate/pool"
cp -r "$POOL_DIR"/. "$EXTRACT_DIR/blackgate/pool/"
cp "$PACKAGES_LIST" "$EXTRACT_DIR/blackgate/packages.list"
echo "   ✅ pool/ + Packages.gz + packages.list"

# License server: an appliance has no Makefile to copy it from, so carry the endpoint the app has to reach
# (config/runtime.exs reads LICENSE_SERVER_URL and otherwise falls back to http://localhost:3000, which
# makes the dashboard's activation fail). Explicit env var wins, then the repository Makefile.
LICENSE_URL="${LICENSE_SERVER_URL:-}"
[ -n "$LICENSE_URL" ] || LICENSE_URL="$(grep -m1 -oP '(?<=LICENSE_SERVER_URL=)\S+' "$SCRIPT_DIR/../Makefile" 2>/dev/null || true)"
if [ -n "$LICENSE_URL" ]; then
    printf '%s\n' "$LICENSE_URL" > "$EXTRACT_DIR/blackgate/license-server-url"
    echo "   ✅ license-server-url ($LICENSE_URL)"
else
    echo "   ⚠️  no LICENSE_SERVER_URL (env or Makefile) — license activation will not work on the appliance"
fi

DESKTOP_VIDEO_DEB="$SCRIPT_DIR/files/blackmagic-desktopvideo.deb"
if [ -f "$DESKTOP_VIDEO_DEB" ]; then
    cp "$DESKTOP_VIDEO_DEB" "$EXTRACT_DIR/blackgate/blackmagic-desktopvideo.deb"
    echo "   ✅ blackmagic-desktopvideo.deb ($(du -h "$DESKTOP_VIDEO_DEB" | cut -f1))"
else
    echo "   ⚠️  blackmagic-desktopvideo.deb missing — the image will need the DeckLink driver by hand"
fi

# The first boot installs the unit/helper/sudoers/updater/keypair through this script rather than
# duplicating the logic: it is the same installer a manual install runs.
cp "$PROJECT_ROOT/scripts/install-system-actions.sh" "$EXTRACT_DIR/blackgate/blackgate-install-system-actions.sh"
echo "   ✅ blackgate-install-system-actions.sh"

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
    exit 1
fi

EFI_START=$(echo "$EFI_INFO" | awk '{print $2}')
EFI_END=$(echo   "$EFI_INFO" | awk '{print $3}')
EFI_SIZE=$(( EFI_END - EFI_START + 1 ))

echo "   EFI partition: start=${EFI_START} end=${EFI_END} size=${EFI_SIZE} sectors"
dd if="$UBUNTU_ISO" bs=512 skip="$EFI_START" count="$EFI_SIZE" of="$EFI_IMG" 2>/dev/null
echo "   ✅ EFI partition extracted ($(du -h "$EFI_IMG" | cut -f1))"

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
    exit 1
fi
