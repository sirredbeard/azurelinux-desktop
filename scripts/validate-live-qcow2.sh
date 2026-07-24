#!/usr/bin/env bash
# Filesystem validation for the Azure Linux Desktop live qcow2 disk image.
# Uses qemu-nbd to expose the image, mounts it, and runs the same checks
# as validate-live-iso.sh against the live rootfs.
#
# Requires: qemu-nbd (qemu-img package), sudo for mount/modprobe.
# Usage: validate-live-qcow2.sh <path-to.qcow2> [work-dir]
set -euo pipefail

QCOW2="${1:?Usage: $0 <live.qcow2> [work-dir]}"
WORKDIR="${2:-$HOME/azl-work/qcow2-validate-$(date +%Y%m%d-%H%M%S)}"
LOG="$WORKDIR/validate-qcow2.log"
MOUNTPOINT="$WORKDIR/mnt"
NBD_DEV="/dev/nbd0"
PASS=0
FAIL=0

mkdir -p "$WORKDIR" "$MOUNTPOINT"
exec > >(tee "$LOG") 2>&1

pass() { echo "  PASS  $1"; (( PASS++ )) || true; }
fail() { echo "  FAIL  $1"; (( FAIL++ )) || true; }

check_file() {
    local label="$1" path="$2" pattern="${3:-}"
    local full="$MOUNTPOINT$path"
    if [ ! -f "$full" ]; then
        fail "$label (not found: $path)"
        return
    fi
    if [ -n "$pattern" ]; then
        if grep -qF "$pattern" "$full"; then
            pass "$label"
        else
            fail "$label (pattern '$pattern' not found in $path)"
            echo "    preview: $(head -5 "$full")"
        fi
    else
        pass "$label (present)"
    fi
}

cleanup() {
    echo ""
    echo "--- Cleanup ---"
    sudo umount "$MOUNTPOINT" 2>/dev/null || true
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    echo "  Done."
    echo ""
    echo "========================================"
    echo "Results: $PASS passed, $FAIL failed"
    echo "Log: $LOG"
    echo "========================================"
    [ "$FAIL" -eq 0 ]
}
trap cleanup EXIT

echo "========================================"
echo "Azure Linux Desktop qcow2 validation"
echo "Image:   $QCOW2 ($(du -sh "$QCOW2" | cut -f1))"
echo "Workdir: $WORKDIR"
echo "========================================"
echo ""

# ------------------------------------------------------------------
# Step 1: Load nbd module and attach image
# ------------------------------------------------------------------
echo "--- Step 1: Attach qcow2 via qemu-nbd ---"
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect="$NBD_DEV" "$QCOW2"
sleep 2

# List partitions
PARTS=$(sudo fdisk -l "$NBD_DEV" 2>/dev/null | grep "^$NBD_DEV" | awk '{print $1}')
echo "  Partitions found: $(echo "$PARTS" | tr '\n' ' ')"

if [ -z "$PARTS" ]; then
    # No partition table — raw filesystem directly on the device
    ROOT_PART="$NBD_DEV"
    echo "  No partition table — trying $NBD_DEV directly"
else
    # Skip EFI/vfat partitions (nbd0p1 is typically EFI System Partition).
    # The root partition is the first non-vfat partition with a supported fs.
    ROOT_PART=""
    for PART in $PARTS; do
        PTYPE=$(sudo blkid -o value -s TYPE "$PART" 2>/dev/null || true)
        if [ "$PTYPE" != "vfat" ] && [ -n "$PTYPE" ]; then
            ROOT_PART="$PART"
            echo "  Using root partition: $ROOT_PART (type: $PTYPE)"
            break
        else
            echo "  Skipping $PART (type: ${PTYPE:-unknown})"
        fi
    done
    if [ -z "$ROOT_PART" ]; then
        ROOT_PART=$(echo "$PARTS" | head -1)
        echo "  Fallback to first partition: $ROOT_PART"
    fi
fi

# ------------------------------------------------------------------
# Step 2: Mount root filesystem
# ------------------------------------------------------------------
echo ""
echo "--- Step 2: Mount root filesystem ---"
FS_TYPE=$(sudo blkid -o value -s TYPE "$ROOT_PART" 2>/dev/null || echo "unknown")
echo "  Filesystem type: $FS_TYPE"

case "$FS_TYPE" in
    ext4|ext3|ext2)
        sudo mount -o ro "$ROOT_PART" "$MOUNTPOINT"
        ;;
    btrfs)
        sudo mount -o ro,subvol=/ "$ROOT_PART" "$MOUNTPOINT" 2>/dev/null || \
        sudo mount -o ro "$ROOT_PART" "$MOUNTPOINT"
        ;;
    xfs)
        sudo mount -o ro,norecovery "$ROOT_PART" "$MOUNTPOINT"
        ;;
    squashfs)
        sudo mount -o ro "$ROOT_PART" "$MOUNTPOINT"
        ;;
    *)
        fail "Unrecognized filesystem type: $FS_TYPE — cannot mount"
        exit 1
        ;;
esac

pass "Root filesystem mounted ($FS_TYPE) at $MOUNTPOINT"
df -h "$MOUNTPOINT"

# ------------------------------------------------------------------
# Step 3: Package list from installed RPM database
# ------------------------------------------------------------------
echo ""
echo "--- Step 3: Package presence checks ---"
RPM_DB="$MOUNTPOINT/usr/lib/sysimage/rpm/rpmdb.sqlite"
if [ -f "$RPM_DB" ]; then
    pass "RPM database present"
    # Use chroot rpm -qa for reliable package queries; direct SQLite on the
    # rpmdb.sqlite schema is fragile (key-value store, not a simple table).
    PKG_COUNT=$(sudo chroot "$MOUNTPOINT" rpm -qa 2>/dev/null | wc -l || echo "?")
    echo "  Installed packages: $PKG_COUNT"
    for PKG in powershell dotnet-sdk-11.0 gnome-shell flatpak microsoft-edge-canary; do
        if sudo chroot "$MOUNTPOINT" rpm -q "$PKG" >/dev/null 2>&1; then
            pass "RPM: $PKG installed"
        else
            fail "RPM: $PKG not found"
        fi
    done
else
    fail "RPM database not found at expected path"
fi

# ------------------------------------------------------------------
# Step 4: Key file checks (same as live ISO rootfs validation)
# ------------------------------------------------------------------
echo ""
echo "--- Step 4: Key file checks ---"

check_file "Plymouth: ScaleLogoToFit (Issue 4)" \
    "/usr/share/plymouth/themes/azurelinux/azurelinux.script" \
    "ScaleLogoToFit"

check_file "azl-dotnet-terminal: drops to \$SHELL" \
    "/usr/local/bin/azl-dotnet-terminal" \
    'exec "${SHELL:-/bin/bash}"'

check_file "edit.desktop: Icon=/usr/share/pixmaps/edit.svg" \
    "/usr/share/applications/edit.desktop" \
    "Icon=/usr/share/pixmaps/edit.svg"

check_file "D-Bus PowerShell service" \
    "/usr/share/dbus-1/services/org.azurelinux.PowerShell.service" \
    "org.azurelinux.PowerShell"

check_file "PowerShell.desktop: StartupWMClass" \
    "/usr/share/applications/org.azurelinux.PowerShell.desktop" \
    "StartupWMClass=org.azurelinux.PowerShell"

check_file "early-kms.conf: hyperv_drm bochs_drm (Issue 3b)" \
    "/etc/dracut.conf.d/early-kms.conf" \
    "hyperv_drm"

check_file "dconf: picture-uri configured" \
    "/etc/dconf/db/local.d/00-dark-mode" \
    "picture-uri"

check_file "azl-powershell-terminal present" \
    "/usr/local/bin/azl-powershell-terminal" \
    ""

# ------------------------------------------------------------------
# Step 5: Compare against live ISO package list if available
# ------------------------------------------------------------------
echo ""
echo "--- Step 5: Package list cross-check ---"
ISO_PKG_LIST=$(find "$WORKDIR/.." -name "final-package-list.txt" 2>/dev/null | head -1)
if [ -n "$ISO_PKG_LIST" ]; then
    echo "  Comparing against: $ISO_PKG_LIST"
    QCOW2_PKGS=$(sqlite3 "$RPM_DB" \
        "SELECT name || '-' || version || '-' || release || '.' || arch FROM Packages ORDER BY name;" \
        2>/dev/null || echo "")
    if [ -n "$QCOW2_PKGS" ]; then
        ISO_COUNT=$(wc -l < "$ISO_PKG_LIST")
        QCOW2_COUNT=$(echo "$QCOW2_PKGS" | wc -l)
        echo "  Live ISO packages: $ISO_COUNT"
        echo "  qcow2 packages:    $QCOW2_COUNT"
        DIFF=$(( ISO_COUNT - QCOW2_COUNT ))
        [ "${DIFF#-}" -le 5 ] && pass "Package counts within 5 of each other ($DIFF delta)" \
                               || fail "Package count delta $DIFF is unexpectedly large"
    fi
else
    echo "  No live ISO package list found nearby — skipping cross-check"
    echo "  (Run from alongside the live validation workdir, or pass explicit path)"
fi
