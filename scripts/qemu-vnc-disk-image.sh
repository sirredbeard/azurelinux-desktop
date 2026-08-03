#!/usr/bin/env bash
# Boot a downloaded Azure Linux Desktop qcow2 through QEMU's localhost-only
# VNC display backend. This bypasses the host GTK/SDL Wayland grab path while
# preserving the same UEFI, KVM, and guest input setup used by the normal
# disk-image tests.
#
# Usage:
#   ./scripts/qemu-vnc-disk-image.sh /path/to/azurelinux-desktop-live.qcow2
#   AZL_QEMU_INPUT_DEVICE=virtio-tablet ./scripts/qemu-vnc-disk-image.sh /path/to/azurelinux-desktop-live.qcow2
#
# Connect from the same host with:
#   vncviewer 127.0.0.1:5901
set -euo pipefail

DISK_IMAGE="${1:?usage: $0 /path/to/azurelinux-desktop-live.qcow2}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
RAM_MB="${AZL_QEMU_RAM_MB:-4096}"
VNC_DISPLAY="${AZL_QEMU_VNC_DISPLAY:-1}"
INPUT_DEVICE="${AZL_QEMU_INPUT_DEVICE:-usb-tablet}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/qemu-uefi-common.sh
source "$SCRIPT_DIR/qemu-uefi-common.sh"

case "$VNC_DISPLAY" in
    ''|*[!0-9]*)
        echo "error: AZL_QEMU_VNC_DISPLAY must be a numeric VNC display" >&2
        exit 1
        ;;
esac

if [ ! -f "$DISK_IMAGE" ]; then
    echo "error: disk image not found: $DISK_IMAGE" >&2
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
OVMF_VARS="$(azl_prepare_ovmf_vars "$WORKDIR" "$(azl_qemu_safe_name "$DISK_IMAGE")-vnc")"
mapfile -t ACCEL_ARGS < <(azl_qemu_accel_args)

echo "Disk image: $DISK_IMAGE"
echo "VNC:        127.0.0.1:$((5900 + VNC_DISPLAY))"
echo "Input:      $INPUT_DEVICE"
echo "Mode:       UEFI, snapshot disk"
echo "Connect with: vncviewer 127.0.0.1:$((5900 + VNC_DISPLAY))"

exec qemu-system-x86_64 \
    -name azl-vnc-input-test \
    -m "$RAM_MB" -smp 2 \
    "${ACCEL_ARGS[@]}" \
    -machine q35 \
    -drive if=pflash,format=raw,readonly=on,file="$AZL_OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -drive file="$DISK_IMAGE",format=qcow2,if=virtio,snapshot=on \
    "${INPUT_ARGS[@]}" \
    -display "vnc=127.0.0.1:$VNC_DISPLAY" \
    -net nic -net user
