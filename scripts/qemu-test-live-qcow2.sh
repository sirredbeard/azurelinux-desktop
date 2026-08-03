#!/usr/bin/env bash
# Boot a downloaded azurelinux-desktop-live.qcow2 in QEMU for manual QA,
# with a real GTK window so the desktop can be looked at directly.
# Companion to qemu-test-live-iso.sh - see that script's header for notes
# on -cpu host, RAM sizing, screendump limitations, and display requirements;
# they apply here too.
#
# A snapshot overlay is used so the downloaded qcow2 is never modified -
# every boot starts from the same clean state. The overlay lives under
# $AZL_QEMU_WORKDIR and is recreated fresh on each run.
#
# Usage:
#   ./scripts/qemu-test-live-qcow2.sh /path/to/azurelinux-desktop-live.qcow2 [name] [ram_mb]

set -euo pipefail

DISK_IMAGE="${1:?usage: $0 /path/to/azurelinux-desktop-live.qcow2 [name] [ram_mb]}"
NAME="${2:-azl-qcow2-test}"
RAM_MB="${3:-8192}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
LOG="$WORKDIR/${NAME}-qemu-stdout.log"
INPUT_DEVICE="${AZL_QEMU_INPUT_DEVICE:-usb-tablet}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/qemu-uefi-common.sh
source "$SCRIPT_DIR/qemu-uefi-common.sh"

mkdir -p "$WORKDIR"
MONITOR_SOCK="$(azl_qemu_monitor_socket "$WORKDIR" "$NAME")"
azl_find_ovmf
OVMF_VARS="$(azl_prepare_ovmf_vars "$WORKDIR" "$NAME")"

case "$INPUT_DEVICE" in
    usb-tablet)   INPUT_ARGS=(-device qemu-xhci -device usb-tablet) ;;
    usb-mouse)    INPUT_ARGS=(-device qemu-xhci -device usb-mouse) ;;
    virtio-tablet) INPUT_ARGS=(-device virtio-tablet-pci) ;;
    virtio-mouse)  INPUT_ARGS=(-device virtio-mouse-pci) ;;
    *)
        echo "error: AZL_QEMU_INPUT_DEVICE must be usb-tablet, usb-mouse, virtio-tablet, or virtio-mouse" >&2
        exit 1
        ;;
esac

# Fresh snapshot overlay — write-backs go here, never into the source image.
OVERLAY="$WORKDIR/${NAME}-overlay.qcow2"
rm -f "$OVERLAY"
qemu-img create -f qcow2 -b "$(realpath "$DISK_IMAGE")" -F qcow2 "$OVERLAY"

echo "Booting $DISK_IMAGE as '$NAME' (${RAM_MB}MB RAM, snapshot overlay)"
echo "Input: $INPUT_DEVICE"
echo "Firmware: UEFI ($AZL_OVMF_CODE)"
echo "Monitor socket: $MONITOR_SOCK"
echo "Log: $LOG"

DISPLAY="${DISPLAY:-:0}" qemu-system-x86_64 \
    -name "$NAME" \
    -m "$RAM_MB" -smp 2 \
    -enable-kvm \
    -cpu host \
    -drive if=pflash,format=raw,readonly=on,file="$AZL_OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -drive file="$OVERLAY",format=qcow2,if=virtio \
    "${INPUT_ARGS[@]}" \
    -display gtk \
    -monitor "unix:$MONITOR_SOCK,server,nowait" \
    -vga virtio \
    -net nic -net user \
    > "$LOG" 2>&1 &

echo "launched pid $!"
sleep 5
ls -la "$MONITOR_SOCK" 2>&1 || echo "monitor socket not up yet - check $LOG"
