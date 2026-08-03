#!/usr/bin/env bash
# Filesystem validation for the Azure Linux Desktop installer ISO.
# Checks GRUB config, kernelcmdline, and installer environment files.
#
# Usage: validate-installer-iso.sh <path-to-installer.iso> [work-dir]
set -euo pipefail

ISO="${1:?Usage: $0 <installer.iso> [work-dir]}"
WORKDIR="${2:-$HOME/azl-work/iso-validate-installer-$(date +%Y%m%d-%H%M%S)}"
LOG="$WORKDIR/validate-installer-iso.log"
PASS=0
FAIL=0

mkdir -p "$WORKDIR"
exec > >(tee "$LOG") 2>&1

pass() { echo "  PASS  $1"; (( PASS++ )) || true; }
fail() { echo "  FAIL  $1"; (( FAIL++ )) || true; }

echo "=============================================="
echo "Azure Linux Desktop installer ISO validation"
echo "ISO:     $ISO"
echo "Workdir: $WORKDIR"
echo "=============================================="
echo ""

# ------------------------------------------------------------------
# Step 1: GRUB config checks (Issue 1)
# ------------------------------------------------------------------
echo "--- Step 1: GRUB config (Issue 1 - graphical GOP mode) ---"
GRUB_EXTRACT="$WORKDIR/grub-extract"
mkdir -p "$GRUB_EXTRACT"

for GRUB_PATH in "boot/grub2/grub.cfg" "EFI/BOOT/grub.cfg" "EFI/BOOT/BOOT.cfg"; do
    if 7z x "$ISO" "$GRUB_PATH" -o"$GRUB_EXTRACT" -y > /dev/null 2>&1; then
        GRUB_CFG="$GRUB_EXTRACT/$GRUB_PATH"
        echo "  Found GRUB config at $GRUB_PATH"
        break
    fi
done

if [ -f "${GRUB_CFG:-}" ]; then
    grep -q "terminal_output gfxterm"  "$GRUB_CFG" && pass "GRUB: terminal_output gfxterm"   || fail "GRUB: terminal_output gfxterm missing"
    grep -q "gfxpayload=keep"          "$GRUB_CFG" && pass "GRUB: gfxpayload=keep"            || fail "GRUB: gfxpayload=keep missing"
    grep -q "efi_gop"                  "$GRUB_CFG" && pass "GRUB: efi_gop insmod"             || fail "GRUB: efi_gop insmod missing"
    # kernelcmdline: no serial console (Issue 2)
    grep -q "console=ttyS0"            "$GRUB_CFG" && fail "GRUB: console=ttyS0 still in cmdline (Issue 2)" || pass "GRUB: no console=ttyS0 in installer cmdline (Issue 2)"
    # No inst.text forcing text mode (should have rhgb quiet instead)
    grep -q "rhgb"                     "$GRUB_CFG" && pass "GRUB: rhgb quiet in cmdline"      || fail "GRUB: rhgb quiet missing from cmdline"
    echo ""
    echo "  Full cmdline entries:"
    grep "linux\|linuxefi" "$GRUB_CFG" | head -5
else
    fail "GRUB config not found in ISO"
fi

# ------------------------------------------------------------------
# Step 2: Extract installer squashfs for environment checks
# ------------------------------------------------------------------
echo ""
echo "--- Step 2: Extract installer squashfs ---"
SQUASHFS_PATH=$(7z l "$ISO" 2>/dev/null | grep -i "squashfs.img" | awk '{print $NF}' | head -1)
if [ -z "$SQUASHFS_PATH" ]; then
    fail "squashfs.img not found in installer ISO"
    echo "  Skipping environment checks"
else
    SQUASH_EXTRACT="$WORKDIR/squash-extract"
    mkdir -p "$SQUASH_EXTRACT"
    echo "  Extracting squashfs from installer ISO..."
    7z x "$ISO" "$SQUASHFS_PATH" -o"$SQUASH_EXTRACT" -y > /dev/null
    SQUASHFS_FILE=$(find "$SQUASH_EXTRACT" -name "squashfs.img" | head -1)

    if [ -f "$SQUASHFS_FILE" ]; then
        pass "Installer squashfs extracted ($(du -sh "$SQUASHFS_FILE" | cut -f1))"
        SQUASH_OUTER="$WORKDIR/squash-outer"
        echo "  Running unsquashfs on installer environment..."
        unsquashfs -d "$SQUASH_OUTER" "$SQUASHFS_FILE" > /dev/null 2>&1

        # Both live ISO and installer ISO use a nested layout:
        # squashfs.img → LiveOS/rootfs.img (ext4). Mount the inner image.
        INNER_IMG="$SQUASH_OUTER/LiveOS/rootfs.img"
        SQUASH_DIR="$WORKDIR/squash-root"
        mkdir -p "$SQUASH_DIR"
        if [ -f "$INNER_IMG" ]; then
            echo "  Nested LiveOS/rootfs.img found — mounting inner ext4..."
            sudo mount -o ro,loop "$INNER_IMG" "$SQUASH_DIR"
            MOUNTED_SQUASH=1
        else
            echo "  No nested rootfs.img — treating squashfs root directly"
            SQUASH_DIR="$SQUASH_OUTER"
            MOUNTED_SQUASH=0
        fi
        cleanup_squash() { [ "${MOUNTED_SQUASH:-0}" -eq 1 ] && sudo umount "$SQUASH_DIR" 2>/dev/null || true; }
        trap cleanup_squash EXIT

        echo ""
        echo "--- Step 3: Installer environment file checks ---"

        # Plymouth theme present in installer environment
        SCRIPT="$SQUASH_DIR/usr/share/plymouth/themes/azurelinux/azurelinux.script"
        if [ -f "$SCRIPT" ]; then
            grep -q "ScaleLogoToFit" "$SCRIPT" && pass "Plymouth: ScaleLogoToFit in installer environment" || fail "Plymouth: ScaleLogoToFit missing from installer environment"
        else
            fail "Plymouth azurelinux theme not present in installer squashfs"
        fi

        # Check early-kms.conf in installer environment (added to kiwi/config.sh
        # alongside the plymouth dracut conf — needed for graphical Plymouth
        # during the installer boot itself)
        KMS="$SQUASH_DIR/etc/dracut.conf.d/early-kms.conf"
        if [ -f "$KMS" ]; then
            grep -q "hyperv_drm" "$KMS" && pass "early-kms.conf: hyperv_drm present in installer env" || fail "early-kms.conf: hyperv_drm missing from installer env"
            grep -q "bochs_drm"  "$KMS" && pass "early-kms.conf: bochs_drm present in installer env"  || fail "early-kms.conf: bochs_drm missing from installer env"
        else
            fail "early-kms.conf not found in installer squashfs (add to kiwi/config.sh)"
        fi

        # Custom installer launcher (assets are staged to the installed target
        # via %%post --nochroot, not baked into the Anaconda runtime)
        for ASSET in \
            "usr/local/bin/anaconda-launcher.sh"; do
            [ -f "$SQUASH_DIR/$ASSET" ] && pass "Installer env: $ASSET present" || fail "Installer env: $ASSET missing"
        done

    else
        fail "squashfs.img not found after extraction"
    fi
fi

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "=============================================="
echo "Results: $PASS passed, $FAIL failed"
echo "Log: $LOG"
echo "=============================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
