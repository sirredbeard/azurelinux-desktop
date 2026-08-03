#!/usr/bin/env bash
# Headless boot smoke test for a built qcow2. This is the CI-safe
# counterpart to the local/manual QEMU scripts: UEFI only, serial log only.
# Uses KVM automatically when /dev/kvm is present and usable (real hardware,
# self-hosted/nested-virt runners), falling back to TCG software emulation
# otherwise. The software-emulation path needs a longer timeout, so the
# deliberately generous - a full GNOME boot under TCG can take 10-15+
# minutes even when the image is healthy; under KVM it is usually well
# under a minute.

set -euo pipefail

IMAGE="${1:?usage: $0 /path/to/azurelinux-desktop-live.qcow2 [timeout_seconds] [marker_regex]}"
TIMEOUT_SECONDS="${2:-1200}"
MARKER_REGEX="${3:-login:|Started GNOME Display Manager|Reached target .*Graphical Interface|Started Getty on tty1|Started Serial Getty on ttyS0}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work/boot-smoke}"
RAM_MB="${AZL_QEMU_RAM_MB:-4096}"
VCPUS="${AZL_QEMU_VCPUS:-2}"
POLL_SECONDS="${AZL_QEMU_POLL_SECONDS:-10}"
SAFE_NAME="$(basename "$IMAGE")-smoke-$$"
SAFE_NAME="$(printf '%s\n' "$SAFE_NAME" | tr -c 'A-Za-z0-9._-' '_')"
LOG="$WORKDIR/${SAFE_NAME}.serial.log"
PIDFILE="$WORKDIR/${SAFE_NAME}.pid"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/qemu-uefi-common.sh
source "$SCRIPT_DIR/qemu-uefi-common.sh"

case "$IMAGE" in
    *.qcow2) ;;
    *)
        echo "ERROR: this serial-marker smoke test only supports qcow2 images; use qemu-test-live-iso.sh for a graphical ISO test." >&2
        exit 2
        ;;
esac

azl_find_ovmf
mkdir -p "$WORKDIR"
OVMF_VARS="$(azl_prepare_ovmf_vars "$WORKDIR" "$SAFE_NAME")"
# shellcheck disable=SC2329
cleanup() {
    local pid

    if [ -f "$PIDFILE" ]; then
        pid="$(cat "$PIDFILE")"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT

# /dev/kvm is a plain kernel device node, so this detection works
# identically whether the script runs on Fedora (dev machine) or Ubuntu
# (GitHub-hosted CI runners) - no distro-specific kvm-ok tooling needed.
mapfile -t ACCEL_ARGS < <(azl_qemu_accel_args)

QEMU_ARGS=(
    -name "azl-boot-smoke"
    -m "$RAM_MB" -smp "$VCPUS"
    -machine q35
    "${ACCEL_ARGS[@]}"
    -drive "if=pflash,format=raw,readonly=on,file=$AZL_OVMF_CODE"
    -drive "if=pflash,format=raw,file=$OVMF_VARS"
    -nographic
    -display none
    -monitor none
    -serial "file:$LOG"
    -net nic -net user
    -no-reboot
)

QEMU_ARGS+=(
    -drive "file=$IMAGE,format=qcow2,if=virtio,snapshot=on"
)

: > "$LOG"
qemu-system-x86_64 "${QEMU_ARGS[@]}" &
echo "$!" > "$PIDFILE"

echo "Image:          $IMAGE"
echo "Serial log:     $LOG"
echo "Timeout:        ${TIMEOUT_SECONDS}s"
echo "Marker regex:   $MARKER_REGEX"
if [ "${ACCEL_ARGS[1]}" = "kvm" ]; then
    echo "Acceleration:   KVM (hardware-accelerated)"
else
    echo "Acceleration:   TCG (software emulation, no /dev/kvm available)"
fi
echo

elapsed=0
while [ "$elapsed" -lt "$TIMEOUT_SECONDS" ]; do
    if grep -Eq "$MARKER_REGEX" "$LOG"; then
        echo "PASS: boot marker found after ${elapsed}s"
        grep -Em1 "$MARKER_REGEX" "$LOG"
        exit 0
    fi

    if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "FAIL: qemu exited before any expected boot marker appeared" >&2
        tail -n 80 "$LOG" >&2 || true
        exit 1
    fi

    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
done

echo "FAIL: timed out after ${TIMEOUT_SECONDS}s waiting for a boot marker" >&2
tail -n 120 "$LOG" >&2 || true
exit 1
