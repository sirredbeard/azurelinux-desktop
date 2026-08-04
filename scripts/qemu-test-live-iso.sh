#!/usr/bin/env bash
# qemu-test-live-iso.sh
#
# Purpose: Boot a live ISO in QEMU (graphical or serial helpers).
# Usage:   ./scripts/qemu-test-live-iso.sh LIVE.iso
# Needs:   qemu, OVMF; display or VNC as configured.
# CI:      No.

set -euo pipefail

ISO="${1:?usage: $0 /path/to/azurelinux-desktop-live.iso [name] [ram_mb]}"
NAME="${2:-azl-live-test}"
RAM_MB="${3:-8192}"
SMP="${AZL_QEMU_SMP:-4}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
DISK="$WORKDIR/${NAME}.qcow2"
LOG="$WORKDIR/${NAME}-qemu-stdout.log"
SERIAL_LOG="$WORKDIR/${NAME}-serial.log"
INPUT_DEVICE="${AZL_QEMU_INPUT_DEVICE:-usb-tablet}"
# Host port forwarded to guest :22. Live kickstart disables sshd - start it
# in the guest (passwordless liveuser) before ssh -p works.
SSH_HOST_PORT="${AZL_QEMU_SSH_PORT:-2222}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/qemu-uefi-common.sh
source "$SCRIPT_DIR/qemu-uefi-common.sh"

mkdir -p "$WORKDIR"
MONITOR_SOCK="$(azl_qemu_monitor_socket "$WORKDIR" "$NAME")"
azl_find_ovmf
OVMF_VARS="$(azl_prepare_ovmf_vars "$WORKDIR" "$NAME")"
mapfile -t AUDIO_ARGS < <(azl_qemu_audio_args)

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
    qemu-img create -f qcow2 "$DISK" 20G
fi

: > "$SERIAL_LOG"

echo "Booting $ISO as '$NAME' (${RAM_MB}MB RAM, smp=$SMP)"
echo "Input: $INPUT_DEVICE"
echo "Firmware: UEFI ($AZL_OVMF_CODE)"
echo "Monitor socket: $MONITOR_SOCK"
echo "Serial log: $SERIAL_LOG (file only; no console=ttyS0 so Plymouth stays graphical)"
echo "SSH forward: host 127.0.0.1:${SSH_HOST_PORT} -> guest :22 (start sshd in guest first)"
echo "Log: $LOG"

# -serial file: capture early printk without putting ttyS0 on the kernel
# cmdline (that path suppresses graphical Plymouth on this product).
DISPLAY="${DISPLAY:-:0}" qemu-system-x86_64 \
    -name "$NAME" \
    -m "$RAM_MB" -smp "$SMP" \
    -enable-kvm \
    -cpu host \
    -drive if=pflash,format=raw,readonly=on,file="$AZL_OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -cdrom "$ISO" \
    -boot d \
    -drive file="$DISK",format=qcow2,if=virtio \
    "${INPUT_ARGS[@]}" \
    "${AUDIO_ARGS[@]}" \
    -display gtk \
    -monitor "unix:$MONITOR_SOCK,server,nowait" \
    -serial "file:$SERIAL_LOG" \
    -vga virtio \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_HOST_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    > "$LOG" 2>&1 &

echo "launched pid $!"
sleep 5
ls -la "$MONITOR_SOCK" 2>&1 || echo "monitor socket not up yet - check $LOG"

# Example of talking to the monitor socket afterward:
#   echo "screendump /tmp/shot.ppm" | socat - "UNIX-CONNECT:$MONITOR_SOCK"
#   echo "system_powerdown" | socat - "UNIX-CONNECT:$MONITOR_SOCK"
# SSH after guest: sudo systemctl start sshd
#   ssh -p "$SSH_HOST_PORT" -o StrictHostKeyChecking=no liveuser@127.0.0.1
