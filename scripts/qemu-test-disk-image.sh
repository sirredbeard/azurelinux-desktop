#!/usr/bin/env bash
# qemu-test-disk-image.sh
#
# Purpose: Boot a qcow2/VHDX (or converted) disk image under UEFI QEMU.
#   Snapshot mode by default so the file is not written back.
# Usage:   ./scripts/qemu-test-disk-image.sh IMAGE
# Needs:   qemu, OVMF; see qemu-uefi-common.sh.
# CI:      Referenced from docs/findings; not a required Actions job.

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
