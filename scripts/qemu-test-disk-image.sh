#!/usr/bin/env bash
# Boot a pre-built azurelinux-desktop-live.qcow2 (or a VHDX, converted to
# qcow2 first) disk image in QEMU, headless, over a serial console, using
# real UEFI (OVMF) firmware - not BIOS - since this project's disk images
# are built as genuine UEFI/GPT images (see findings/gh-actions-
# live-iso-build.md, "Switch disk-image build from forced BIOS/MBR to
# real UEFI/GPT"). This is a smoke test only: it confirms the image is a
# valid, bootable UEFI disk (shim -> grub -> kernel -> systemd all start),
# not a full interactive desktop test - there is no display attached and
# no way to interact with it, only to watch serial output scroll by and
# confirm it reaches a login prompt / gets as far as expected before the
# timeout kills it.
#
# Usage:
#   ./scripts/qemu-test-disk-image.sh /path/to/azurelinux-desktop-live.qcow2 [timeout_seconds]
#
# For a VHDX artifact, convert it to qcow2 first (this project's own
# images are qemu-img-converted the other direction at build time, so the
# round trip is lossless):
#   qemu-img convert -O qcow2 azurelinux-desktop-live.vhdx test.qcow2
#   ./scripts/qemu-test-disk-image.sh test.qcow2
#
# Notes learned the hard way:
#   - OVMF_CODE.fd/OVMF_VARS.fd come from the edk2-ovmf package. The
#     shared helper this script now sources checks the same Fedora/QEMU
#     path variants the newer CI smoke tests use too, so local/manual and
#     CI boot tests stay on the same firmware-discovery path.
#   - Booting this project's images with plain BIOS/-bios seabios.bin
#     will NOT work and is not a valid way to test them - they are
#     GPT-partitioned with an EFI System Partition and no BIOS boot
#     partition at all (see `fdisk -l` on the image: one "EFI System"
#     partition, one Linux filesystem partition, nothing else). Real
#     OVMF UEFI firmware is required.
#   - -snapshot is used so this test never writes back into the real
#     disk-image file - safe to run against a just-downloaded release
#     artifact without risking corrupting it.
#   - -nographic + a serial console (console=ttyS0 already baked into
#     this project's kickstart's kernel command line via lorax defaults)
#     is what actually produces readable boot output here; a real GTK
#     window has nothing to attach to over an SSH-only/headless session.
#   - This cannot verify the graphical desktop actually renders (GNOME,
#     Wayland/GDM, etc.) - only that the kernel boots and systemd starts
#     bringing up services. Use scripts/qemu-test-live-iso.sh from a real
#     graphical session for that level of verification.

set -euo pipefail

DISK_IMAGE="${1:?usage: $0 /path/to/azurelinux-desktop-live.qcow2 [timeout_seconds]}"
TIMEOUT_SECONDS="${2:-120}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
RAM_MB="${AZL_QEMU_RAM_MB:-4096}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/qemu-uefi-common.sh
source "$SCRIPT_DIR/qemu-uefi-common.sh"

azl_find_ovmf
mkdir -p "$WORKDIR"
OVMF_VARS="$(azl_prepare_ovmf_vars "$WORKDIR" "$(azl_qemu_safe_name "$DISK_IMAGE")")"

echo "Disk image:   $DISK_IMAGE"
echo "OVMF code:     $AZL_OVMF_CODE"
echo "OVMF vars:     $OVMF_VARS (scratch copy, safe to discard)"
echo "Timeout:       ${TIMEOUT_SECONDS}s"
echo "Mode:          headless, serial console, -snapshot (image itself is never modified)"
echo

timeout --signal=TERM "$TIMEOUT_SECONDS" \
    qemu-system-x86_64 \
    -name azl-disk-boot-test \
    -m "$RAM_MB" -smp 2 \
    -enable-kvm \
    -cpu host \
    -machine q35 \
    -drive if=pflash,format=raw,readonly=on,file="$AZL_OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -drive file="$DISK_IMAGE",format=qcow2,if=virtio,snapshot=on \
    -nographic \
    -serial mon:stdio \
    -net nic -net user \
    || rc=$?

rc="${rc:-0}"
if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then
    echo
    echo "Timed out after ${TIMEOUT_SECONDS}s (expected for a smoke test with"
    echo "nothing to log into/shut it down - review the serial output above"
    echo "for how far it got: shim -> grub -> kernel -> systemd -> login"
    echo "prompt is the expected sequence for a healthy image)."
    exit 0
fi
exit "$rc"
