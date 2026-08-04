#!/usr/bin/env bash
# qemu-boot-installed-hostpart.sh
#
# Purpose: Boot the nested dual-boot install from the host partition in QEMU
#   (optional BT USB passthrough / snapshot modes).
# Usage:   ./scripts/qemu-boot-installed-hostpart.sh
# Needs:   qemu, OVMF; correct host partition env. Can be host-sensitive.
# CI:      No.

set -euo pipefail

PART="${1:-/dev/nvme0n1p4}"
NAME="${2:-azl-installed-partition}"
RAM_MB="${3:-8192}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
SSH_PORT="${AZL_QEMU_SSH_PORT:-2222}"
GL_MODE="${AZL_QEMU_GL:-on}"
# Optional USB Bluetooth passthrough (host must release the device first).
# AZL_QEMU_BT_PASSTHROUGH=1 uses 8087:0a2b by default.
# Override with AZL_QEMU_BT_VENDOR / AZL_QEMU_BT_PRODUCT (hex without 0x).
BT_PASSTHROUGH="${AZL_QEMU_BT_PASSTHROUGH:-0}"
BT_VENDOR="${AZL_QEMU_BT_VENDOR:-8087}"
BT_PRODUCT="${AZL_QEMU_BT_PRODUCT:-0a2b}"
# AZL_QEMU_SNAPSHOT=1 → QEMU temporary overlay (no writes to the host
# partition). Use for dry-run / BT passthrough QA before bare metal.
SNAPSHOT_MODE="${AZL_QEMU_SNAPSHOT:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/qemu-uefi-common.sh
source "$SCRIPT_DIR/qemu-uefi-common.sh"

if [ ! -b "$PART" ]; then
    echo "error: $PART is not a block device" >&2
    exit 1
fi
if [ ! -r "$PART" ] || [ ! -w "$PART" ]; then
    echo "error: need read/write access to $PART (e.g. chmod 666 once, or run via a group with disk access)" >&2
    exit 1
fi

# Refuse whole-disk nodes (nvme0n1, sda) - only partitions.
base="$(basename "$PART")"
case "$base" in
    nvme*n*p[0-9]*|mmcblk*p[0-9]*|sd*[0-9]*|vd*[0-9]*|xvd*[0-9]*) ;;
    *)
        echo "error: refusing whole-disk path $PART; pass a partition only" >&2
        exit 1
        ;;
esac

mkdir -p "$WORKDIR"
azl_find_ovmf

INSTALLER_VARS="$WORKDIR/azl-installer-hostpart.ovmf-vars.fd"
OVMF_VARS="$WORKDIR/${NAME}.ovmf-vars.fd"
if [ -f "$INSTALLER_VARS" ]; then
    cp -f "$INSTALLER_VARS" "$OVMF_VARS"
    echo "OVMF vars: reused installer NVRAM ($INSTALLER_VARS)"
else
    cp -f "$AZL_OVMF_VARS_SRC" "$OVMF_VARS"
    echo "OVMF vars: fresh copy from $AZL_OVMF_VARS_SRC"
fi
chmod 644 "$OVMF_VARS"

MONITOR_SOCK="$(azl_qemu_monitor_socket "$WORKDIR" "$NAME")"
PIDFILE="$WORKDIR/${NAME}.pid"
SERIAL_LOG="$WORKDIR/${NAME}-serial.log"
STDOUT_LOG="$WORKDIR/${NAME}-qemu-stdout.log"
mapfile -t AUDIO_ARGS < <(azl_qemu_audio_args)
: >"$SERIAL_LOG"
: >"$STDOUT_LOG"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "error: $NAME already running as pid $(cat "$PIDFILE")" >&2
    exit 1
fi

# Drop stale host mappings of nested partitions so QEMU can open the node.
if command -v kpartx >/dev/null 2>&1; then
    kpartx -d "$PART" 2>/dev/null || true
fi

# Unmount nested FS mounts if still attached (hostpart must be free).
if mountpoint -q /mnt/azl-home 2>/dev/null; then
    umount /mnt/azl-home 2>/dev/null || umount -l /mnt/azl-home || true
fi
if mountpoint -q /mnt/azl-rootfs 2>/dev/null; then
    umount /mnt/azl-rootfs 2>/dev/null || umount -l /mnt/azl-rootfs || true
fi

BT_QEMU_ARGS=()
if [[ "$BT_PASSTHROUGH" == "1" || "$BT_PASSTHROUGH" == "yes" || "$BT_PASSTHROUGH" == "true" ]]; then
    if ! lsusb -d "${BT_VENDOR}:${BT_PRODUCT}" >/dev/null 2>&1; then
        echo "error: BT USB ${BT_VENDOR}:${BT_PRODUCT} not present on host" >&2
        exit 1
    fi
    # Release host btusb claim so usb-host can attach the device.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop bluetooth.service 2>/dev/null || true
    fi
    modprobe -r btusb 2>/dev/null || true
    # Unbind any remaining interfaces for this vendor:product.
    for dev in /sys/bus/usb/devices/*; do
        [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
        v="$(cat "$dev/idVendor" 2>/dev/null || true)"
        p="$(cat "$dev/idProduct" 2>/dev/null || true)"
        [[ "$v" == "$BT_VENDOR" && "$p" == "$BT_PRODUCT" ]] || continue
        for iface in "$dev"/[0-9]*:[0-9]*; do
            [[ -e "$iface/driver" ]] || continue
            basen="$(basename "$iface")"
            echo "$basen" >"$iface/driver/unbind" 2>/dev/null || true
        done
    done
    BT_QEMU_ARGS+=(
        -device "usb-host,vendorid=0x${BT_VENDOR},productid=0x${BT_PRODUCT},bus=xhci.0,id=btusb0"
    )
    echo "BT passthrough: ${BT_VENDOR}:${BT_PRODUCT} -> guest xhci"
fi

DISK_DRIVE_OPTS="id=sysdisk,if=none,file=${PART},format=raw"
if [[ "$SNAPSHOT_MODE" == "1" || "$SNAPSHOT_MODE" == "yes" || "$SNAPSHOT_MODE" == "true" ]]; then
    # Temporary write overlay — nested install partition stays unchanged.
    DISK_DRIVE_OPTS+=",snapshot=on,cache=unsafe"
    echo "Storage:  snapshot overlay (dry-run; no host writes to $PART)"
else
    DISK_DRIVE_OPTS+=",cache=none,discard=unmap,aio=threads,detect-zeroes=unmap"
    echo "Storage:  NVMe direct (writes go to $PART)"
fi

echo "Booting installed system on $PART as '$NAME'"
echo "Firmware: UEFI ($AZL_OVMF_CODE)"
echo "Display:  gtk,gl=$GL_MODE"
echo "Serial:   $SERIAL_LOG"
echo "SSH:      localhost:${SSH_PORT} -> guest:22"
echo "Monitor:  $MONITOR_SOCK"
echo "Log:      $STDOUT_LOG"

DISPLAY="${DISPLAY:-:0}" qemu-system-x86_64 \
    -name "$NAME" \
    -machine q35,accel=kvm,kernel-irqchip=on \
    -cpu host \
    -smp 4,sockets=1,cores=2,threads=2 \
    -m "$RAM_MB" \
    -drive if=pflash,format=raw,readonly=on,file="$AZL_OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -drive "$DISK_DRIVE_OPTS" \
    -device nvme,drive=sysdisk,serial=AZL-NVME01,bootindex=1 \
    -device qemu-xhci,id=xhci \
    -device usb-tablet,bus=xhci.0 \
    -device usb-kbd,bus=xhci.0 \
    "${BT_QEMU_ARGS[@]}" \
    -device e1000e,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-rng-pci \
    "${AUDIO_ARGS[@]}" \
    -vga virtio \
    -display "gtk,gl=${GL_MODE},grab-on-hover=on" \
    -serial "file:$SERIAL_LOG" \
    -monitor "unix:$MONITOR_SOCK,server,nowait" \
    -rtc base=utc,clock=host \
    -smbios type=1,manufacturer=QEMU,product=AzureLinuxDesktopHostLike,version=1 \
    -daemonize -pidfile "$PIDFILE" \
    >"$STDOUT_LOG" 2>&1

echo "launched pid $(cat "$PIDFILE")"
sleep 3
ls -la "$MONITOR_SOCK" 2>&1 || echo "monitor socket not up yet - check $STDOUT_LOG"
echo
echo "Watch serial with:  tail -f $SERIAL_LOG"
echo "Stop with:          kill \$(cat $PIDFILE)"
