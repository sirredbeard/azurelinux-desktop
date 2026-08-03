#!/usr/bin/env bash
# Boot a live ISO through QEMU's localhost-only VNC backend with the same
# UEFI, KVM, q35, and selectable input setup used by the Azure disk VNC test.
# This is suitable for a control image as well as Azure Linux Desktop.
#
# Usage:
#   ./scripts/qemu-vnc-live-iso.sh /path/to/live.iso [vnc_display]
#   AZL_QEMU_INPUT_DEVICE=virtio-tablet ./scripts/qemu-vnc-live-iso.sh /path/to/live.iso
#
# Connect from the same host with:
#   vncviewer 127.0.0.1:<5900 + vnc_display>
set -euo pipefail

ISO="${1:?usage: $0 /path/to/live.iso [vnc_display]}"
VNC_DISPLAY="${2:-2}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
RAM_MB="${AZL_QEMU_RAM_MB:-8192}"
INPUT_DEVICE="${AZL_QEMU_INPUT_DEVICE:-usb-tablet}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/qemu-uefi-common.sh
source "$SCRIPT_DIR/qemu-uefi-common.sh"

case "$VNC_DISPLAY" in
    ''|*[!0-9]*)
        echo "error: VNC display must be numeric" >&2
        exit 1
        ;;
esac

if [ ! -f "$ISO" ]; then
    echo "error: ISO not found: $ISO" >&2
    exit 1
fi

case "$INPUT_DEVICE" in
    usb-tablet)
        INPUT_ARGS=(-device qemu-xhci -device usb-tablet)
        ;;
    usb-mouse)
        INPUT_ARGS=(-device qemu-xhci -device usb-mouse)
        ;;
    virtio-tablet)
        INPUT_ARGS=(-device virtio-tablet-pci)
        ;;
    virtio-mouse)
        INPUT_ARGS=(-device virtio-mouse-pci)
        ;;
    *)
        echo "error: AZL_QEMU_INPUT_DEVICE must be usb-tablet, usb-mouse, virtio-tablet, or virtio-mouse" >&2
        exit 1
        ;;
esac

azl_find_ovmf
mkdir -p "$WORKDIR"
OVMF_VARS="$(azl_prepare_ovmf_vars "$WORKDIR" "$(azl_qemu_safe_name "$ISO")-vnc")"
mapfile -t ACCEL_ARGS < <(azl_qemu_accel_args)

echo "Live ISO:    $ISO"
echo "VNC:         127.0.0.1:$((5900 + VNC_DISPLAY))"
echo "Input:       $INPUT_DEVICE"
echo "Mode:        UEFI, read-only ISO"
echo "Connect with: vncviewer 127.0.0.1:$((5900 + VNC_DISPLAY))"

exec qemu-system-x86_64 \
    -name live-iso-vnc-input-test \
    -m "$RAM_MB" -smp 2 \
    "${ACCEL_ARGS[@]}" \
    -machine q35 \
    -drive if=pflash,format=raw,readonly=on,file="$AZL_OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -cdrom "$ISO" \
    -boot d \
    "${INPUT_ARGS[@]}" \
    -display "vnc=127.0.0.1:$VNC_DISPLAY" \
    -net nic -net user
