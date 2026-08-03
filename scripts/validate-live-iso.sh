#!/usr/bin/env bash
# Filesystem validation for the Azure Linux Desktop live ISO.
# Extracts the ISO -> squashfs -> rootfs.img and checks each expected fix.
# Reports pass/fail immediately after each check; exits non-zero on any failure.
#
# Usage: validate-live-iso.sh <path-to-live.iso> [work-dir]
#
# work-dir defaults to a temp directory under ~/azl-work/iso-validate-<date>.
set -euo pipefail

ISO="${1:?Usage: $0 <live.iso> [work-dir]}"
WORKDIR="${2:-$HOME/azl-work/iso-validate-$(date +%Y%m%d-%H%M%S)}"
LOG="$WORKDIR/validate-live-iso.log"
PASS=0
FAIL=0

mkdir -p "$WORKDIR"
exec > >(tee "$LOG") 2>&1

pass() { echo "  PASS  $1"; (( PASS++ )) || true; }
fail() { echo "  FAIL  $1"; (( FAIL++ )) || true; }

check_rootfs_file() {
    local label="$1" path="$2" pattern="$3"
    local out
    if [ -n "$pattern" ]; then
        out=$(debugfs -R "cat $path" "$ROOTFS" 2>/dev/null) || { fail "$label (debugfs read error)"; return; }
        if echo "$out" | grep -qF "$pattern"; then
            pass "$label"
        else
            fail "$label (pattern '$pattern' not found)"
            echo "    content preview: $(echo "$out" | head -5)"
        fi
    else
        if debugfs -R "stat $path" "$ROOTFS" 2>/dev/null | grep -q "Type:"; then
            pass "$label"
        else
            fail "$label (file not found in rootfs)"
        fi
    fi
}

echo "========================================"
echo "Azure Linux Desktop live ISO validation"
echo "ISO:     $ISO"
echo "Workdir: $WORKDIR"
echo "========================================"
echo ""

# ------------------------------------------------------------------
# Step 1: ISO contents
# ------------------------------------------------------------------
echo "--- Step 1: ISO structure ---"
ISO_LIST="$WORKDIR/iso-list.txt"
7z l "$ISO" > "$ISO_LIST" 2>&1
if grep -qi "squashfs\|LiveOS" "$ISO_LIST"; then
    pass "ISO is readable and contains LiveOS"
else
    fail "ISO structure unexpected"
    cat "$ISO_LIST" | head -30
    exit 1
fi

# Check EFI/GRUB config for gfxterm fix (Issue 1)
echo ""
echo "--- Step 2: GRUB config (Issue 1 - graphical GOP mode) ---"
GRUB_EXTRACT="$WORKDIR/grub-extract"
mkdir -p "$GRUB_EXTRACT"
# Try EFI grub.cfg first, then boot/grub2
for GRUB_PATH in "boot/grub2/grub.cfg" "EFI/BOOT/grub.cfg" "EFI/BOOT/BOOT.cfg"; do
    if 7z x "$ISO" "$GRUB_PATH" -o"$GRUB_EXTRACT" -y > /dev/null 2>&1; then
        GRUB_CFG="$GRUB_EXTRACT/$GRUB_PATH"
        break
    fi
done

if [ -f "${GRUB_CFG:-}" ]; then
    grep -q "terminal_output gfxterm"  "$GRUB_CFG" && pass "GRUB: terminal_output gfxterm"  || fail "GRUB: terminal_output gfxterm missing"
    grep -q "gfxpayload=keep"          "$GRUB_CFG" && pass "GRUB: gfxpayload=keep"           || fail "GRUB: gfxpayload=keep missing"
    grep -q "insmod.*efi_gop\|efi_gop" "$GRUB_CFG" && pass "GRUB: efi_gop insmod"            || fail "GRUB: efi_gop insmod missing"
    grep -q "console=ttyS0"            "$GRUB_CFG" && fail "GRUB: console=ttyS0 still present (should be gone)" || pass "GRUB: no console=ttyS0 in cmdline"
else
    fail "GRUB config not found in ISO (checked boot/grub2, EFI/BOOT)"
fi

# ------------------------------------------------------------------
# Step 3: Extract squashfs
# ------------------------------------------------------------------
echo ""
echo "--- Step 3: Extract squashfs ---"
SQUASHFS_PATH=$(7z l "$ISO" 2>/dev/null | grep -i "squashfs.img" | awk '{print $NF}' | head -1)
if [ -z "$SQUASHFS_PATH" ]; then
    fail "squashfs.img not found in ISO"
    exit 1
fi

SQUASH_EXTRACT="$WORKDIR/squash-extract"
mkdir -p "$SQUASH_EXTRACT"
echo "  Extracting $SQUASHFS_PATH from ISO..."
7z x "$ISO" "$SQUASHFS_PATH" -o"$SQUASH_EXTRACT" -y > /dev/null
SQUASHFS_FILE=$(find "$SQUASH_EXTRACT" -name "squashfs.img" | head -1)
[ -f "$SQUASHFS_FILE" ] && pass "squashfs.img extracted ($(du -sh "$SQUASHFS_FILE" | cut -f1))" || { fail "squashfs.img not found after extraction"; exit 1; }

echo ""
echo "--- Step 4: Extract squashfs contents ---"
SQUASH_DIR="$WORKDIR/squash-root"
echo "  Running unsquashfs (may take a minute)..."
unsquashfs -d "$SQUASH_DIR" "$SQUASHFS_FILE" > /dev/null 2>&1
[ -d "$SQUASH_DIR" ] && pass "squashfs extracted to $SQUASH_DIR" || { fail "unsquashfs failed"; exit 1; }

# ------------------------------------------------------------------
# Step 4: Find rootfs.img and check size
# ------------------------------------------------------------------
echo ""
echo "--- Step 5: rootfs.img size (live rootfs space fix) ---"
ROOTFS=$(find "$SQUASH_DIR" -name "rootfs.img" 2>/dev/null | head -1)
if [ -z "$ROOTFS" ]; then
    fail "rootfs.img not found inside squashfs"
    exit 1
fi
ROOTFS_SIZE_GB=$(du -BG "$ROOTFS" 2>/dev/null | awk '{print $1}' | tr -d 'G')
echo "  rootfs.img size: ${ROOTFS_SIZE_GB}G"
if [ "${ROOTFS_SIZE_GB:-0}" -ge 7 ]; then
    pass "rootfs.img is ${ROOTFS_SIZE_GB}G (>= 7G, Flatpak space fix OK)"
else
    fail "rootfs.img is only ${ROOTFS_SIZE_GB}G (expected >= 7G for Flatpak installs)"
fi

# ------------------------------------------------------------------
# Step 5: Filesystem checks inside rootfs.img via debugfs
# ------------------------------------------------------------------
echo ""
echo "--- Step 6: rootfs.img filesystem checks ---"

# Issue 4: Plymouth ScaleLogoToFit
check_rootfs_file \
    "Plymouth: ScaleLogoToFit in azurelinux.script (Issue 4)" \
    "/usr/share/plymouth/themes/azurelinux/azurelinux.script" \
    "ScaleLogoToFit"

# azl-dotnet-terminal drops to shell
check_rootfs_file \
    "azl-dotnet-terminal: drops to \$SHELL after dotnet --info" \
    "/usr/local/bin/azl-dotnet-terminal" \
    'exec "${SHELL:-/bin/bash}"'

# edit.desktop icon restored
check_rootfs_file \
    "edit.desktop: Icon=/usr/share/pixmaps/edit.svg" \
    "/usr/share/applications/edit.desktop" \
    "Icon=/usr/share/pixmaps/edit.svg"

# D-Bus PowerShell service file
check_rootfs_file \
    "D-Bus PowerShell service file present" \
    "/usr/share/dbus-1/services/org.azurelinux.PowerShell.service" \
    "org.azurelinux.PowerShell"

# PowerShell desktop StartupWMClass
check_rootfs_file \
    "PowerShell.desktop: StartupWMClass=org.azurelinux.PowerShell" \
    "/usr/share/applications/org.azurelinux.PowerShell.desktop" \
    "StartupWMClass=org.azurelinux.PowerShell"

# dotnet.desktop comment
check_rootfs_file \
    "dotnet.desktop: Comment mentions shell" \
    "/usr/share/applications/dotnet.desktop" \
    "shell"

# early-kms.conf drivers (may be in /etc/dracut.conf.d/ on live rootfs)
check_rootfs_file \
    "early-kms.conf: hyperv_drm bochs_drm added (Issue 3b)" \
    "/etc/dracut.conf.d/early-kms.conf" \
    "hyperv_drm"

# dconf wallpaper setting
check_rootfs_file \
    "dconf: wallpaper configured in local.d" \
    "/etc/dconf/db/local.d/00-azl-desktop-defaults" \
    "picture-uri"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "Log: $LOG"
echo "========================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
