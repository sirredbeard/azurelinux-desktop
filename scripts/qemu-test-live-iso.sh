#!/usr/bin/env bash
# Boot a built azurelinux-desktop-live.iso in QEMU for manual testing, with
# a real GTK window (not -nographic/VNC) so the desktop can actually be
# looked at, plus a QEMU monitor socket for scripted checks (screendump,
# system_powerdown, etc.) alongside just watching the window directly.
#
# This is the exact invocation used to test GH Actions run 3's ISO - it's
# recorded here so it doesn't have to be re-derived from scratch (or from
# session history) every time. Usage:
#
#   ./scripts/qemu-test-live-iso.sh /path/to/azurelinux-desktop-live.iso
#
# Notes learned the hard way:
#   - DISPLAY must point at a real, already-running X/Wayland session on
#     this host (-display gtk opens an actual window there) - this only
#     works when run from/against a graphical desktop session, not a
#     headless SSH-only box.
#   - The QEMU monitor's own `screendump` command produces visibly
#     corrupted/striped PPM captures in this environment (a capture-path
#     artifact, not a guest bug) - don't trust screendump PNGs/PPMs for
#     pixel-level verification. Looking directly at the real GTK window
#     (or having a human screenshot it) is the reliable way to check
#     on-screen state; screendump is only good for coarse checks like
#     "did grub load" via readable text.
#   - -m 4096 (4GB) reproduced a live-session "out of disk space" report
#     within minutes of testing flatpak installs - that's dracut's RAM-
#     backed tmpfs overlay for the live root, sized as a fraction of
#     total VM RAM, not a real free-space problem. Give the VM more RAM
#     (8192+) if you intend to install/test anything substantial in the
#     live session itself, or add rd.live.overlay.size=/rd.live.ram=
#     kernel args - see findings/ for the details.
#   - A second virtio drive (a throwaway qcow2) is attached so there's a
#     writable disk present at boot in case the installable variant or
#     any persistence testing needs one later; the live ISO itself boots
#     and runs entirely from the -cdrom device.
#   - -cpu host is required, not optional. Without it QEMU defaults to
#     -cpu qemu64 even with -enable-kvm, a conservative baseline missing
#     SSE4.1/SSE4.2/POPCNT - real modern CPU features .NET's runtime
#     expects and hard-crashes without ("Fatal error. The current CPU is
#     missing one or more of the following instruction sets..."). This
#     was mistaken for a .NET/dotnet.desktop problem at first; it's a
#     test-VM CPU model problem, not a build problem.

set -euo pipefail

ISO="${1:?usage: $0 /path/to/azurelinux-desktop-live.iso [name] [ram_mb]}"
NAME="${2:-azl-live-test}"
RAM_MB="${3:-8192}"
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
    qemu-img create -f qcow2 "$DISK" 20G
fi

echo "Booting $ISO as '$NAME' (${RAM_MB}MB RAM)"
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

# Example of talking to the monitor socket afterward:
#   echo "screendump /tmp/shot.ppm" | socat - "UNIX-CONNECT:$MONITOR_SOCK"
#   echo "system_powerdown" | socat - "UNIX-CONNECT:$MONITOR_SOCK"
