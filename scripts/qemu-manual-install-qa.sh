#!/usr/bin/env bash
# Launch the installer ISO in a GTK window for manual QA while recording
# firmware/kernel/installer serial output to a persistent log.
set -euo pipefail

ISO="${1:?usage: $0 /path/to/azurelinux-desktop-install.iso [name] [ram_mb] [disk_gb]}"
NAME="${2:-azl-installer-manual-qa}"
RAM_MB="${3:-8192}"
DISK_GB="${4:-30}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK="$WORKDIR/${NAME}.qcow2"
SERIAL_LOG="$WORKDIR/${NAME}-serial.log"
QEMU_LOG="$WORKDIR/${NAME}-qemu.log"

# shellcheck source=scripts/qemu-uefi-common.sh
source "$SCRIPT_DIR/qemu-uefi-common.sh"

if [ ! -f "$ISO" ]; then
    echo "installer ISO not found: $ISO" >&2
    exit 1
fi

mkdir -p "$WORKDIR"
azl_find_ovmf
OVMF_VARS="$(azl_prepare_ovmf_vars "$WORKDIR" "$(azl_qemu_safe_name "$NAME")")"
MONITOR_SOCK="$(azl_qemu_monitor_socket "$WORKDIR" "$NAME")"
mapfile -t ACCEL_ARGS < <(azl_qemu_accel_args)

if [ ! -f "$DISK" ]; then
    echo "Creating new ${DISK_GB}G install target: $DISK"
    qemu-img create -f qcow2 "$DISK" "${DISK_GB}G"
else
    echo "Reusing install target: $DISK"
    echo "Remove it before launching for a clean install."
fi

rm -f "$MONITOR_SOCK" "$SERIAL_LOG" "$QEMU_LOG"

echo "Launching $ISO in GTK as $NAME"
echo "Install target: $DISK"
echo "Serial log:     $SERIAL_LOG"
echo "QEMU log:       $QEMU_LOG"
echo "Monitor socket: $MONITOR_SOCK"

DISPLAY="${DISPLAY:-:0}" setsid qemu-system-x86_64 \
    -name "$NAME" \
    -m "$RAM_MB" -smp 2 \
    "${ACCEL_ARGS[@]}" \
    -machine q35 \
    -drive if=pflash,format=raw,readonly=on,file="$AZL_OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -cdrom "$ISO" \
    -boot d \
    -drive file="$DISK",format=qcow2,if=virtio \
    -display gtk \
    -device virtio-vga \
    -serial "file:$SERIAL_LOG" \
    -monitor "unix:$MONITOR_SOCK,server,nowait" \
    -net nic -net user \
    >"$QEMU_LOG" 2>&1 &

PID=$!
sleep 3
if ! kill -0 "$PID" 2>/dev/null; then
    echo "QEMU exited during launch. See $QEMU_LOG" >&2
    exit 1
fi

echo "QEMU PID: $PID"
echo "Follow serial output: tail -f $SERIAL_LOG"
