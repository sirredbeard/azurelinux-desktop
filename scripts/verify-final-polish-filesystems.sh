#!/usr/bin/env bash
# Validate on-disk final-polish expectations across live ISO, installer ISO,
# and (optionally) an installed qcow2 root LV.
set -euo pipefail

LIVE_ISO="${1:?usage: $0 /path/live.iso /path/installer.iso [installed.qcow2] [output_dir]}"
INSTALLER_ISO="${2:?usage: $0 /path/live.iso /path/installer.iso [installed.qcow2] [output_dir]}"
INSTALLED_QCOW="${3:-}"
OUTPUT_DIR="${4:-$HOME/azl-work/final-polish-validation}"

if [ ! -f "$LIVE_ISO" ]; then
    echo "live ISO not found: $LIVE_ISO" >&2
    exit 1
fi
if [ ! -f "$INSTALLER_ISO" ]; then
    echo "installer ISO not found: $INSTALLER_ISO" >&2
    exit 1
fi
if [ -n "$INSTALLED_QCOW" ] && [ ! -f "$INSTALLED_QCOW" ]; then
    echo "installed qcow2 not found: $INSTALLED_QCOW" >&2
    exit 1
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)"
WORK="$OUTPUT_DIR/$RUN_ID"
LOG="$WORK/final-polish-filesystem-validation.log"

LIVE_ISO_MNT="$WORK/mnt/live_iso"
LIVE_ROOT_MNT="$WORK/mnt/live_root"
LIVE_PAYLOAD_MNT="$LIVE_ROOT_MNT"
LIVE_ROOTIMG_MNT="$WORK/mnt/live_rootimg"
INSTALLER_ISO_MNT="$WORK/mnt/installer_iso"
INSTALLER_ROOT_MNT="$WORK/mnt/installer_root"
INSTALLER_PAYLOAD_MNT="$INSTALLER_ROOT_MNT"
INSTALLER_ROOTIMG_MNT="$WORK/mnt/installer_rootimg"
INSTALLED_ROOT_MNT="$WORK/mnt/installed_root"

mkdir -p "$LIVE_ISO_MNT" "$LIVE_ROOT_MNT" "$LIVE_ROOTIMG_MNT" \
    "$INSTALLER_ISO_MNT" "$INSTALLER_ROOT_MNT" "$INSTALLER_ROOTIMG_MNT" "$INSTALLED_ROOT_MNT"

cleanup() {
    set +e
    mountpoint -q "$INSTALLED_ROOT_MNT" && sudo umount "$INSTALLED_ROOT_MNT"
    if sudo lvs --noheadings anaconda_azurelinux-desktop/root >/dev/null 2>&1; then
        sudo vgchange -an anaconda_azurelinux-desktop >/dev/null 2>&1 || true
    fi
    sudo qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true

    mountpoint -q "$INSTALLER_ROOTIMG_MNT" && sudo umount "$INSTALLER_ROOTIMG_MNT"
    mountpoint -q "$INSTALLER_ROOT_MNT" && sudo umount "$INSTALLER_ROOT_MNT"
    mountpoint -q "$INSTALLER_ISO_MNT" && sudo umount "$INSTALLER_ISO_MNT"
    mountpoint -q "$LIVE_ROOTIMG_MNT" && sudo umount "$LIVE_ROOTIMG_MNT"
    mountpoint -q "$LIVE_ROOT_MNT" && sudo umount "$LIVE_ROOT_MNT"
    mountpoint -q "$LIVE_ISO_MNT" && sudo umount "$LIVE_ISO_MNT"
}
trap cleanup EXIT

sudo mount -o loop "$LIVE_ISO" "$LIVE_ISO_MNT"
sudo mount -o loop "$LIVE_ISO_MNT/LiveOS/squashfs.img" "$LIVE_ROOT_MNT"
if sudo test -f "$LIVE_ROOT_MNT/LiveOS/rootfs.img"; then
    sudo mount -o loop "$LIVE_ROOT_MNT/LiveOS/rootfs.img" "$LIVE_ROOTIMG_MNT"
    LIVE_PAYLOAD_MNT="$LIVE_ROOTIMG_MNT"
fi

sudo mount -o loop "$INSTALLER_ISO" "$INSTALLER_ISO_MNT"
sudo mount -o loop "$INSTALLER_ISO_MNT/LiveOS/squashfs.img" "$INSTALLER_ROOT_MNT"
if sudo test -f "$INSTALLER_ROOT_MNT/LiveOS/rootfs.img"; then
    sudo mount -o loop "$INSTALLER_ROOT_MNT/LiveOS/rootfs.img" "$INSTALLER_ROOTIMG_MNT"
    INSTALLER_PAYLOAD_MNT="$INSTALLER_ROOTIMG_MNT"
fi

if [ -n "$INSTALLED_QCOW" ]; then
    sudo modprobe nbd max_part=16 || true
    sudo qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true
    sudo qemu-nbd --read-only --connect=/dev/nbd0 "$INSTALLED_QCOW"
    sleep 1
    sudo pvscan --cache -aay >/dev/null
    sudo vgchange -ay anaconda_azurelinux-desktop >/dev/null
    sudo mount -t ext4 -o ro,noload /dev/anaconda_azurelinux-desktop/root "$INSTALLED_ROOT_MNT"
fi

{
    echo "=== BUILD IDENTIFIERS ==="
    sha256sum "$LIVE_ISO" "$INSTALLER_ISO"
    [ -n "$INSTALLED_QCOW" ] && sha256sum "$INSTALLED_QCOW"
    echo

    echo "=== LIVE ISO BOOT CONFIG HIGHLIGHTS ==="
    grep -R --line-number -E 'linuxefi|append|rhgb|quiet|overlay|rd.live|inst.text|console=' \
        "$LIVE_ISO_MNT/EFI/BOOT" "$LIVE_ISO_MNT/isolinux" 2>/dev/null | head -n 160 || true
    echo

    echo "=== INSTALLER ISO BOOT CONFIG HIGHLIGHTS ==="
    grep -R --line-number -E 'linuxefi|append|rhgb|quiet|overlay|rd.live|inst.text|console=' \
        "$INSTALLER_ISO_MNT/EFI/BOOT" "$INSTALLER_ISO_MNT/isolinux" 2>/dev/null | head -n 200 || true
    if [ -f "$INSTALLER_ISO_MNT/EFI/BOOT/grub.cfg" ]; then
        echo "--- installer EFI/BOOT/grub.cfg ---"
        grep -n -E 'linux|rhgb|quiet|console|inst.text' "$INSTALLER_ISO_MNT/EFI/BOOT/grub.cfg" || true
    fi
    echo

    echo "=== LIVE ROOT: DESKTOP/LAUNCHER FILES ==="
    grep -n '^Exec=' "$LIVE_PAYLOAD_MNT/usr/share/applications/dotnet.desktop"
    grep -n 'org.azurelinux.PowerShell' "$LIVE_PAYLOAD_MNT/usr/local/bin/azl-powershell-terminal"
    cat "$LIVE_PAYLOAD_MNT/usr/share/dbus-1/services/org.azurelinux.PowerShell.service"
    echo

    echo "=== LIVE ROOT: DCONF DEFAULTS ==="
    grep -R --line-number -E 'picture-uri|picture-uri-dark|favorite-apps|org.azurelinux.PowerShell|dotnet.desktop|edit.desktop' \
        "$LIVE_PAYLOAD_MNT/etc/dconf" 2>/dev/null | head -n 200 || true
    echo

    echo "=== LIVE ROOT: FLATPAK POLICY ==="
    grep -R --line-number -E 'min-free-space-size|languages' "$LIVE_PAYLOAD_MNT/etc/flatpak" 2>/dev/null || true
    echo

    echo "=== LIVE ROOT: ROOTFS IMAGE SIZE ==="
    ls -lh "$LIVE_ISO_MNT/LiveOS/squashfs.img"
    if sudo test -f "$LIVE_ROOT_MNT/LiveOS/rootfs.img"; then
        ls -lh "$LIVE_ROOT_MNT/LiveOS/rootfs.img"
    fi
    echo

    echo "=== INSTALLER RUNTIME: STAGED ASSET SIGNALS ==="
    for p in \
        /opt/azl-desktop-assets/desktop/dotnet.desktop \
        /opt/azl-desktop-assets/bin/azl-dotnet-terminal \
        /opt/azl-desktop-assets/bin/azl-powershell-terminal \
        /opt/azl-desktop-assets/dbus/org.azurelinux.PowerShell.service \
        /root/azl-install.ks; do
        if sudo test -e "$INSTALLER_PAYLOAD_MNT$p"; then
            echo "present: $p"
        else
            echo "missing: $p"
        fi
    done
    if sudo test -f "$INSTALLER_PAYLOAD_MNT/opt/azl-desktop-assets/desktop/dotnet.desktop"; then
        sudo grep -n '^Exec=' "$INSTALLER_PAYLOAD_MNT/opt/azl-desktop-assets/desktop/dotnet.desktop" || true
    fi
    if sudo test -f "$INSTALLER_PAYLOAD_MNT/opt/azl-desktop-assets/bin/azl-powershell-terminal"; then
        sudo grep -n 'app-id org.azurelinux.PowerShell' "$INSTALLER_PAYLOAD_MNT/opt/azl-desktop-assets/bin/azl-powershell-terminal" || true
    fi
    if sudo test -f "$INSTALLER_PAYLOAD_MNT/root/azl-install.ks"; then
        sudo grep -n -- '--shell=/usr/bin/pwsh' "$INSTALLER_PAYLOAD_MNT/root/azl-install.ks" || true
    fi
    echo

    if [ -n "$INSTALLED_QCOW" ]; then
        echo "=== INSTALLED ROOT SNAPSHOT: DESKTOP/LAUNCHER FILES ==="
        sudo grep -n '^Exec=' "$INSTALLED_ROOT_MNT/usr/share/applications/dotnet.desktop" || true
        if sudo test -f "$INSTALLED_ROOT_MNT/usr/local/bin/azl-dotnet-terminal"; then
            sudo ls -l "$INSTALLED_ROOT_MNT/usr/local/bin/azl-dotnet-terminal"
        else
            echo "missing: /usr/local/bin/azl-dotnet-terminal"
        fi
        if sudo test -f "$INSTALLED_ROOT_MNT/usr/share/dbus-1/services/org.azurelinux.PowerShell.service"; then
            sudo cat "$INSTALLED_ROOT_MNT/usr/share/dbus-1/services/org.azurelinux.PowerShell.service"
        else
            echo "missing: org.azurelinux.PowerShell.service"
        fi
        sudo grep -n ':/usr/bin/pwsh$' "$INSTALLED_ROOT_MNT/etc/passwd" || true
        echo

        echo "=== PACKAGE COUNTS (LIVE ROOT vs INSTALLED SNAPSHOT) ==="
        sudo rpm --root "$LIVE_PAYLOAD_MNT" -qa | sort > "$WORK/live-packages.txt"
        sudo rpm --root "$INSTALLED_ROOT_MNT" -qa | sort > "$WORK/installed-packages.txt"
        wc -l "$WORK/live-packages.txt" "$WORK/installed-packages.txt"
        echo

        echo "=== PACKAGE DIFF (TOP 200 LINES) ==="
        diff -u "$WORK/live-packages.txt" "$WORK/installed-packages.txt" | sed -n '1,200p' || true
    fi
} | tee "$LOG"

echo "validation log: $LOG"
