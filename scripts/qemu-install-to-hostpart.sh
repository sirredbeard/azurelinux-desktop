#!/usr/bin/env bash
# Boot the Azure Linux Desktop installer ISO with a single host partition
# attached as the only installable disk. Use this for nested dual-boot
# installs/reinstalls on a live Fedora host.
#
# Safety:
#   - Pass a partition node only (e.g. /dev/nvmeXnYpZ), never the whole
#     disk, so Fedora ESP/root/bootloader stay out of the guest.
#   - Unmounts host kpartx mappings of nested partitions first.
#
# Input modes (AZL_INSTALLER_INPUT):
#   gtk (default)
#     - console=tty0 only, no serial device
#     - installer auto-starts on graphical tty1 (kiwi .bash_profile)
#     - type in the GTK window using QEMU's emulated PS/2 keyboard
#     - AZL stock kernel still lacks in-tree usbhid; project initrd ships
#       out-of-tree usbhid (and usb-storage/uas). PS/2 remains the reliable
#       QEMU path; USB tablet works once usbhid loads from the live initrd.
#   serial
#     - console=ttyS0 + tty0; serial socket for typing
#     - GTK window is watch-only (tty1 shows install-azl shell banner)
#     - connect: socat STDIO,raw,echo=0,escape=0x1d UNIX-CONNECT:$sock
#
# Usage:
#   ./scripts/qemu-install-to-hostpart.sh /path/to/install.iso [/dev/nvmeXnYpZ] [name] [ram_mb]
#
# Env:
#   AZL_INSTALLER_INPUT=gtk|serial   (default gtk)
#   AZL_KEEP_OVMF_VARS=1             reuse NVRAM vars
#   AZL_QEMU_GL=off|on               (default off)
#   AZL_INSTALLER_CMDLINE=...        override full kernel cmdline
#
# After install finishes and the guest shuts down:
#   ./scripts/qemu-boot-installed-hostpart.sh /dev/nvme0n1p4
# WARNING: can install onto a real host partition. Triple-check the target device.

set -euo pipefail

ISO="${1:?usage: $0 /path/to/install.iso [/dev/nvmeXnYpZ] [name] [ram_mb]}"
PART="${2:-/dev/nvme0n1p4}"
NAME="${3:-azl-installer-hostpart}"
RAM_MB="${4:-8192}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
SSH_PORT="${AZL_QEMU_SSH_PORT:-2222}"
GL_MODE="${AZL_QEMU_GL:-off}"
INPUT_MODE="${AZL_INSTALLER_INPUT:-gtk}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/qemu-uefi-common.sh
source "$SCRIPT_DIR/qemu-uefi-common.sh"

case "$INPUT_MODE" in
    gtk|serial) ;;
    *)
        echo "error: AZL_INSTALLER_INPUT must be gtk or serial (got: $INPUT_MODE)" >&2
        exit 1
        ;;
esac

if [ ! -f "$ISO" ]; then
    echo "error: ISO not found: $ISO" >&2
    exit 1
fi
if [ ! -b "$PART" ]; then
    echo "error: $PART is not a block device" >&2
    exit 1
fi
if [ ! -r "$PART" ] || [ ! -w "$PART" ]; then
    echo "error: need read/write access to $PART" >&2
    exit 1
fi

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

OVMF_VARS="$WORKDIR/${NAME}.ovmf-vars.fd"
if [ "${AZL_KEEP_OVMF_VARS:-0}" != "1" ] || [ ! -f "$OVMF_VARS" ]; then
    cp -f "$AZL_OVMF_VARS_SRC" "$OVMF_VARS"
    echo "OVMF vars: fresh copy (set AZL_KEEP_OVMF_VARS=1 to reuse)"
else
    echo "OVMF vars: reusing $OVMF_VARS"
fi
chmod 644 "$OVMF_VARS"

MONITOR_SOCK="$(azl_qemu_monitor_socket "$WORKDIR" "$NAME")"
PIDFILE="$WORKDIR/${NAME}.pid"
SERIAL_SOCK="$WORKDIR/${NAME}-serial.sock"
SERIAL_LOG="$WORKDIR/${NAME}-serial.log"
STDOUT_LOG="$WORKDIR/${NAME}-qemu-stdout.log"
BOOTDIR="$WORKDIR/${NAME}-boot"
: >"$STDOUT_LOG"
rm -f "$SERIAL_SOCK"

if [ -f "$PIDFILE" ]; then
    oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "${oldpid:-}" ] && [ -d "/proc/${oldpid}" ]; then
        echo "error: $NAME already running as pid ${oldpid}" >&2
        exit 1
    fi
    rm -f "$PIDFILE"
fi

if command -v kpartx >/dev/null 2>&1; then
    kpartx -d "$PART" 2>/dev/null || true
fi

# Extract loader kernel/initrd so cmdline controls which VT auto-starts
# the installer (see kiwi/config.sh root .bash_profile rules).
if ! command -v 7z >/dev/null 2>&1; then
    echo "error: 7z is required to extract the installer kernel/initrd" >&2
    exit 1
fi
rm -rf "$BOOTDIR"
mkdir -p "$BOOTDIR"
7z x -y -o"$BOOTDIR" "$ISO" 'boot/x86_64/loader/linux' 'boot/x86_64/loader/initrd' >/dev/null
KERNEL="$BOOTDIR/boot/x86_64/loader/linux"
INITRD="$BOOTDIR/boot/x86_64/loader/initrd"
if [ ! -f "$KERNEL" ] || [ ! -f "$INITRD" ]; then
    echo "error: failed to extract kernel/initrd from $ISO" >&2
    exit 1
fi

BASE_OPTS='rhgb quiet enforcing=0 audit=0 inst.lang=en_US.UTF-8 inst.nokill root=live:CDLABEL=CDROM rd.live.image azl.autoinstall inst.nosave=all_ks'
if [ -n "${AZL_INSTALLER_CMDLINE:-}" ]; then
    CMDLINE="$AZL_INSTALLER_CMDLINE"
elif [ "$INPUT_MODE" = "serial" ]; then
    # Serial console: installer only on ttyS0. GTK shows install-azl shell.
    CMDLINE="console=ttyS0,115200 console=tty0 earlyprintk=serial,ttyS0,115200 ${BASE_OPTS}"
else
    # Graphical: installer only on tty1. No console=ttyS* so serial-getty
    # does not race a second launcher. Do not attach a serial device.
    CMDLINE="console=tty0 ${BASE_OPTS}"
fi

echo "Installer ISO: $ISO"
echo "Target part:   $PART (only this node is exposed to the guest)"
echo "Name:          $NAME (${RAM_MB}MB RAM)"
echo "Firmware:      UEFI ($AZL_OVMF_CODE)"
echo "Storage:       NVMe (host-like)"
echo "Boot:          direct kernel + ISO live root"
echo "Input mode:    $INPUT_MODE"
echo "Display:       gtk,gl=$GL_MODE"
if [ "$INPUT_MODE" = "serial" ]; then
    echo "Serial sock:   $SERIAL_SOCK"
    echo "Serial log:    $SERIAL_LOG"
fi
echo "SSH:           localhost:${SSH_PORT} -> guest:22"
echo "Monitor:       $MONITOR_SOCK"
echo "Log:           $STDOUT_LOG"
echo
if [ "$INPUT_MODE" = "serial" ]; then
    : >"$SERIAL_LOG"
    echo ">>> Type installer answers on serial (GTK is watch-only):"
    echo "  socat STDIO,raw,echo=0,escape=0x1d UNIX-CONNECT:$SERIAL_SOCK"
    echo "  (Ctrl-] detaches)"
else
    echo ">>> Type in the GTK window (PS/2 keyboard is the reliable path)."
    echo "    Click the window, wait for 'Administrator username:', then type."
    echo "    Project initrd includes usbhid/usb-storage; stick to PS/2 in QEMU."
fi
echo
echo "In Anaconda: use only the single NVMe disk (nested container partition)."

QEMU_ARGS=(
    -name "$NAME"
    -machine q35,accel=kvm,kernel-irqchip=on
    -cpu host
    -smp 4,sockets=1,cores=2,threads=2
    -m "$RAM_MB"
    -drive if=pflash,format=raw,readonly=on,file="$AZL_OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"
    -kernel "$KERNEL"
    -initrd "$INITRD"
    -append "$CMDLINE"
    -drive id=installiso,if=none,media=cdrom,readonly=on,file="$ISO"
    -device ide-cd,drive=installiso,bootindex=1
    -drive id=sysdisk,if=none,file="$PART",format=raw,cache=none,discard=unmap,aio=threads,detect-zeroes=unmap
    -device nvme,drive=sysdisk,serial=AZL-NVME01,bootindex=2
    -device e1000e,netdev=net0
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
    -device virtio-rng-pci
    # std VGA keeps classic PS/2 keyboard/mouse paths; avoid USB HID devices
    # until AZL ships usbhid (issue #5).
    -vga std
    -display "gtk,gl=${GL_MODE},grab-on-hover=off"
    -monitor "unix:$MONITOR_SOCK,server,nowait"
    -rtc base=utc,clock=host
    -smbios type=1,manufacturer=QEMU,product=AzureLinuxDesktopHostLike,version=1
    -daemonize -pidfile "$PIDFILE"
)

if [ "$INPUT_MODE" = "serial" ]; then
    QEMU_ARGS+=(
        -chardev "socket,id=serial0,path=${SERIAL_SOCK},server=on,wait=off,logfile=${SERIAL_LOG},logappend=on"
        -serial chardev:serial0
    )
else
    QEMU_ARGS+=(-serial none)
fi

DISPLAY="${DISPLAY:-:0}" qemu-system-x86_64 "${QEMU_ARGS[@]}" >"$STDOUT_LOG" 2>&1

echo "launched pid $(cat "$PIDFILE")"
sleep 2
if [ "$INPUT_MODE" = "serial" ]; then
    ls -la "$SERIAL_SOCK" 2>&1 || echo "serial socket not up yet - check $STDOUT_LOG"
    echo
    echo "Connect now:"
    echo "  socat STDIO,raw,echo=0,escape=0x1d UNIX-CONNECT:$SERIAL_SOCK"
else
    echo "Focus the GTK window and complete the offline installer there."
fi
echo "Stop with:     kill \$(cat $PIDFILE)"
echo "After install: ./scripts/qemu-boot-installed-hostpart.sh $PART"
