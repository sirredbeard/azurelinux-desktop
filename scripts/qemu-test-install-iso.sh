#!/usr/bin/env bash
# Boot a built azurelinux-desktop-install.iso in QEMU for manual install
# testing, with a real GTK window (not -nographic/VNC) so the Anaconda
# install and first-boot desktop can actually be looked at, plus a QEMU
# monitor socket for scripted checks alongside just watching the window
# directly. Companion to scripts/qemu-test-live-iso.sh - see that script
# for the notes on -cpu host, RAM sizing, and screendump captures being
# unreliable in this environment; they apply here too and are not
# repeated below.
#
# Usage:
#   ./scripts/qemu-test-install-iso.sh /path/to/azurelinux-desktop-install.iso [name] [ram_mb] [disk_gb]
#
# Unlike the live ISO (which boots and runs entirely from the -cdrom
# device), the installer ISO's whole point is to install onto a real
# disk, so this script always creates/reuses a persistent, expandable
# qcow2 disk (30G by default) under $AZL_QEMU_WORKDIR (default
# $HOME/azl-work) and boots off the CD-ROM first so Anaconda can
# partition and install onto that disk. Attached via virtio-blk
# (-drive if=virtio), the standard low-overhead paravirtualized block
# transport for a QEMU target disk - not virtiofs, which is a shared-
# directory/filesystem passthrough mechanism (virtiofsd + a memory
# backend), not a block device, so Anaconda has nothing to partition
# or install a bootloader onto if the "disk" were virtiofs instead.
# Re-run the same script with the same $NAME afterward (with -boot d
# dropped, see the boot-from-disk invocation printed at the end) to boot
# the freshly installed system instead of the installer media again.
# WARNING: writes the target disk image. Do not point this at a disk you care about without a backup.

set -euo pipefail

ISO="${1:?usage: $0 /path/to/azurelinux-desktop-install.iso [name] [ram_mb] [disk_gb]}"
NAME="${2:-azl-installer-test}"
RAM_MB="${3:-8192}"
DISK_GB="${4:-30}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
DISK="$WORKDIR/${NAME}.qcow2"
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

if [ ! -f "$DISK" ]; then
    echo "Creating new ${DISK_GB}G target disk: $DISK"
    qemu-img create -f qcow2 "$DISK" "${DISK_GB}G"
else
    echo "Reusing existing target disk: $DISK"
    echo "Delete it first (rm $DISK) for a clean install instead of an upgrade/reinstall over it."
fi

echo "Booting $ISO as '$NAME' (${RAM_MB}MB RAM, installing to $DISK)"
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
    -cdrom "$ISO" \
    -boot d \
    -drive file="$DISK",format=qcow2,if=virtio \
    "${INPUT_ARGS[@]}" \
    -display gtk \
    -monitor "unix:$MONITOR_SOCK,server,nowait" \
    -vga virtio \
    -net nic -net user \
    > "$LOG" 2>&1 &

echo "launched pid $!"
sleep 5
ls -la "$MONITOR_SOCK" 2>&1 || echo "monitor socket not up yet - check $LOG"

echo
echo "Once the install finishes and the VM has shut down, boot the"
echo "installed disk directly (no -cdrom/-boot d) with:"
echo
echo "  qemu-system-x86_64 -name $NAME -m $RAM_MB -smp 2 -enable-kvm -cpu host \\"
echo "      -drive file=$DISK,format=qcow2,if=virtio \\"
echo "      -display gtk -vga virtio -net nic -net user"

# Example of talking to the monitor socket afterward:
#   echo "screendump /tmp/shot.ppm" | socat - "UNIX-CONNECT:$MONITOR_SOCK"
#   echo "system_powerdown" | socat - "UNIX-CONNECT:$MONITOR_SOCK"
