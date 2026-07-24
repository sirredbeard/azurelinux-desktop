#!/usr/bin/env bash
# Filesystem validation for the Azure Linux Desktop live ISO.
# Extracts the ISO squashfs, mounts the nested rootfs.img, and checks key files.
#
# Both the live ISO and installer ISO use a nested layout:
#   LiveOS/squashfs.img → LiveOS/rootfs.img (ext4)
# This script handles both by mounting the inner ext4 when present.
# Requires sudo for the loop mount of rootfs.img.
#
# Usage: validate-live-iso-filesystem.sh <path-to-live.iso> [work-dir]
set -euo pipefail

ISO="${1:?Usage: $0 <live.iso> [work-dir]}"
WORKDIR="${2:-$HOME/azl-work/live-validate-$(date +%Y%m%d-%H%M%S)}"
ROOTFS="$WORKDIR/rootfs"
LOG="$WORKDIR/filesystem-check.log"
PASS=0
FAIL=0
MOUNTED_ROOTFS=0

mkdir -p "$WORKDIR"
exec > >(tee "$LOG") 2>&1

pass() { echo "  PASS  $1"; (( PASS++ )) || true; }
fail() { echo "  FAIL  $1"; (( FAIL++ )) || true; }
check() {
    local label="$1" file="$2" pattern="${3:-}"
    if [ ! -e "$ROOTFS$file" ]; then
        fail "$label ($file missing)"
        return
    fi
    if [ -n "$pattern" ] && ! grep -qF "$pattern" "$ROOTFS$file" 2>/dev/null; then
        fail "$label (pattern not found: $pattern)"
        echo "    content: $(head -5 "$ROOTFS$file" 2>/dev/null)"
        return
    fi
    pass "$label"
}

echo "========================================"
echo "Azure Linux Desktop live ISO filesystem check"
echo "ISO:     $ISO"
echo "Workdir: $WORKDIR"
echo "========================================"

# Extract squashfs
echo ""
echo "--- Extracting ISO squashfs ---"
mkdir -p "$WORKDIR/iso-extract"
7z x "$ISO" "LiveOS/squashfs.img" -o"$WORKDIR/iso-extract/" -y 2>/dev/null | grep -E "^(Everything|Error)"
SQUASHFS_FILE="$WORKDIR/iso-extract/LiveOS/squashfs.img"

# Both the live ISO and installer ISO use a nested layout:
# squashfs.img → LiveOS/rootfs.img (ext4).  unsquashfs the outer layer
# then loop-mount the inner ext4 to get a real filesystem to check.
SQUASH_OUTER="$WORKDIR/squash-outer"
echo "  Extracting squashfs (takes ~1-2 min)..."
unsquashfs -d "$SQUASH_OUTER" "$SQUASHFS_FILE" 2>&1 | tail -3

INNER_IMG="$SQUASH_OUTER/LiveOS/rootfs.img"
if [ -f "$INNER_IMG" ]; then
    echo "  Nested LiveOS/rootfs.img found — mounting inner ext4..."
    mkdir -p "$ROOTFS"
    sudo mount -o ro,loop "$INNER_IMG" "$ROOTFS"
    MOUNTED_ROOTFS=1
else
    echo "  No nested rootfs.img — treating squashfs root as rootfs directly"
    ROOTFS="$SQUASH_OUTER"
    MOUNTED_ROOTFS=0
fi

cleanup_rootfs() {
    [ "${MOUNTED_ROOTFS:-0}" -eq 1 ] && sudo umount "$ROOTFS" 2>/dev/null || true
}
trap cleanup_rootfs EXIT

echo ""
echo "--- GRUB config ---"
mkdir -p "$WORKDIR/grub"
7z x "$ISO" "boot/grub2/grub.cfg" -o"$WORKDIR/grub/" -y 2>/dev/null | grep -E "^(Everything|Error)"
GRUB="$WORKDIR/grub/boot/grub2/grub.cfg"
grep -q "gfxpayload=keep" "$GRUB" && pass "GRUB: gfxpayload=keep" || fail "GRUB: gfxpayload=keep missing"
grep -q "efi_gop\|all_video" "$GRUB"  && pass "GRUB: video modules present" || fail "GRUB: video modules missing"
grep -q "console=ttyS0" "$GRUB" && fail "GRUB: console=ttyS0 in cmdline (should be gone)" || pass "GRUB: no console=ttyS0 in cmdline"
grep -q "rhgb" "$GRUB" && pass "GRUB: rhgb in cmdline" || fail "GRUB: rhgb missing"

echo ""
echo "--- Plymouth ---"
check "Plymouth theme installed" "/usr/share/plymouth/themes/azurelinux/azurelinux.script"
check "Plymouth: ScaleLogoToFit (Issue 4)" "/usr/share/plymouth/themes/azurelinux/azurelinux.script" "ScaleLogoToFit"
check "Plymouth: logo file present" "/usr/share/plymouth/themes/azurelinux/azurelinuxlogo.png"

echo ""
echo "--- KMS drivers ---"
check "early-kms.conf: virtio_gpu" "/etc/dracut.conf.d/early-kms.conf" "virtio_gpu"
check "early-kms.conf: hyperv_drm (Issue 3b)" "/etc/dracut.conf.d/early-kms.conf" "hyperv_drm"
check "early-kms.conf: bochs_drm (Issue 3b)" "/etc/dracut.conf.d/early-kms.conf" "bochs_drm"

echo ""
echo "--- Desktop launchers ---"
check "edit.desktop present" "/usr/share/applications/edit.desktop"
check "edit.desktop: icon path" "/usr/share/applications/edit.desktop" "Icon=/usr/share/pixmaps/edit.svg"
check "edit.desktop: Categories" "/usr/share/applications/edit.desktop" "Categories="
check "dotnet.desktop: drops to shell" "/usr/share/applications/dotnet.desktop" "shell"
check "PowerShell.desktop present" "/usr/share/applications/org.azurelinux.PowerShell.desktop"
check "PowerShell.desktop: StartupWMClass" "/usr/share/applications/org.azurelinux.PowerShell.desktop" "StartupWMClass=org.azurelinux.PowerShell"

echo ""
echo "--- Custom launchers ---"
check "azl-powershell-terminal present" "/usr/local/bin/azl-powershell-terminal"
check "azl-powershell-terminal: app-id" "/usr/local/bin/azl-powershell-terminal" "org.azurelinux.PowerShell"
check "azl-dotnet-terminal present" "/usr/local/bin/azl-dotnet-terminal"
check "azl-dotnet-terminal: drops to shell" "/usr/local/bin/azl-dotnet-terminal" 'exec "${SHELL:-/bin/bash}"'

echo ""
echo "--- D-Bus PowerShell service ---"
check "D-Bus service file present" "/usr/share/dbus-1/services/org.azurelinux.PowerShell.service"
check "D-Bus service: correct app-id" "/usr/share/dbus-1/services/org.azurelinux.PowerShell.service" "org.azurelinux.PowerShell"

echo ""
echo "--- dconf defaults ---"
DCONF_FILE=""
for f in "$ROOTFS/etc/dconf/db/local.d/"*; do
    [ -f "$f" ] && DCONF_FILE="$f" && break
done
if [ -n "$DCONF_FILE" ]; then
    pass "dconf local.d has config ($(basename "$DCONF_FILE"))"
    grep -q "color-scheme" "$DCONF_FILE" && pass "dconf: color-scheme set" || fail "dconf: color-scheme missing"
    grep -q "picture-uri" "$DCONF_FILE"  && pass "dconf: picture-uri set"  || fail "dconf: picture-uri missing"
    grep -q "adwaita-l.jxl\|\.jxl" "$DCONF_FILE" && fail "dconf: still pointing at JXL (AZL can't render JXL)" || pass "dconf: no JXL paths"
    # Live ISO sets favorites via the livesys-gnome script at runtime (not dconf).
    # Accept either a dconf local.d file with favorite-apps OR the livesys-gnome patch.
    LIVESYS_GNOME="$ROOTFS/usr/libexec/livesys/sessions.d/livesys-gnome"
    if grep -q "favorite-apps\|favorite" "$ROOTFS/etc/dconf/db/local.d/"* 2>/dev/null; then
        pass "dconf: favorite-apps set"
    elif [ -f "$LIVESYS_GNOME" ] && grep -q "microsoft-edge-canary\|azurelinux" "$LIVESYS_GNOME" 2>/dev/null; then
        pass "dconf: favorites set via livesys-gnome script (live ISO mechanism)"
    else
        fail "dconf: favorite-apps missing (not in dconf local.d or livesys-gnome)"
    fi
else
    fail "dconf: no local.d config files found"
fi
[ -f "$ROOTFS/etc/dconf/profile/user" ] && pass "dconf: profile/user present" || fail "dconf: profile/user missing"

echo ""
echo "--- Wallpapers ---"
if [ -d "$ROOTFS/usr/share/backgrounds/azurelinux" ]; then
    pass "Wallpaper dir /usr/share/backgrounds/azurelinux present"
    check "adwaita-l.jpg present" "/usr/share/backgrounds/azurelinux/adwaita-l.jpg"
    check "adwaita-d.jpg present" "/usr/share/backgrounds/azurelinux/adwaita-d.jpg"
else
    fail "Wallpaper dir missing — build predates wallpaper fix or copy step failed"
fi

echo ""
echo "--- Icons ---"
check "edit.svg icon" "/usr/share/pixmaps/edit.svg"
check "powershell.png icon" "/usr/share/pixmaps/powershell.png"
check "dotnet.svg icon" "/usr/share/pixmaps/dotnet.svg"

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "Log: $LOG"
echo "========================================"
[ "$FAIL" -eq 0 ]
