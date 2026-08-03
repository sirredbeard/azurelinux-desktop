#!/usr/bin/env bash
# Boot a dedicated test qcow2 (same desktop, extra oneshot test unit baked
# in) and wait for the guest itself to print PASS/FAIL markers over the
# serial console. The guest does the real work - upgrade, repo-origin
# assertions, and package/flatpak installs - because that is less fragile
# here than trying to type a full session over ttyS0 on a slow TCG VM.

set -euo pipefail

IMAGE="${1:?usage: $0 /path/to/azurelinux-desktop-live-test.qcow2 [timeout_seconds]}"
# Resolve to an absolute path before it's ever used as a qemu-img backing
# file: `qemu-img create -b <relative path>` stores that path literally,
# and it gets resolved relative to the *overlay's own directory* when
# opened, not the process's cwd - a relative $IMAGE here silently pointed
# at the wrong place once WORKDIR wasn't the same directory as $IMAGE
# (exactly what happens in CI, where WORKDIR is test-work/guest-checks
# but the downloaded qcow2 lives at dist/... under $GITHUB_WORKSPACE).
IMAGE="$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")"
TIMEOUT_SECONDS="${2:-2400}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work/post-boot-checks}"
RAM_MB="${AZL_QEMU_RAM_MB:-6144}"
VCPUS="${AZL_QEMU_VCPUS:-2}"
POLL_SECONDS="${AZL_QEMU_POLL_SECONDS:-15}"
SAFE_NAME="$(basename "$IMAGE")-guest-$$"
SAFE_NAME="$(printf '%s\n' "$SAFE_NAME" | tr -c 'A-Za-z0-9._-' '_')"
LOG="$WORKDIR/${SAFE_NAME}.serial.log"
OVERLAY="$WORKDIR/${SAFE_NAME}.overlay.qcow2"
PIDFILE="$WORKDIR/${SAFE_NAME}.pid"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/qemu-uefi-common.sh
source "$SCRIPT_DIR/qemu-uefi-common.sh"

azl_find_ovmf
mkdir -p "$WORKDIR"
OVMF_VARS="$(azl_prepare_ovmf_vars "$WORKDIR" "$SAFE_NAME")"
qemu-img create -q -f qcow2 -F qcow2 -b "$IMAGE" "$OVERLAY"

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

: > "$LOG"
qemu-system-x86_64 \
    -name azl-post-boot-test \
    -m "$RAM_MB" -smp "$VCPUS" \
    -machine q35 \
    -accel tcg,thread=multi \
    -cpu max \
    -drive if=pflash,format=raw,readonly=on,file="$AZL_OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -drive file="$OVERLAY",format=qcow2,if=virtio \
    -nographic \
    -display none \
    -monitor none \
    -serial "file:$LOG" \
    -net nic -net user \
    -no-reboot &
echo "$!" > "$PIDFILE"

echo "Image:          $IMAGE"
echo "Overlay:        $OVERLAY"
echo "Serial log:     $LOG"
echo "Timeout:        ${TIMEOUT_SECONDS}s"
echo

elapsed=0
while [ "$elapsed" -lt "$TIMEOUT_SECONDS" ]; do
    if grep -q 'AZL_TEST_RESULT PASS' "$LOG"; then
        echo "PASS: guest checks reported success after ${elapsed}s"
        tail -n 40 "$LOG"
        exit 0
    fi

    if grep -q 'AZL_TEST_RESULT FAIL' "$LOG"; then
        echo "FAIL: guest checks reported failure" >&2
        tail -n 120 "$LOG" >&2 || true
        exit 1
    fi

    if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "FAIL: qemu exited before the guest printed a final PASS/FAIL marker" >&2
        tail -n 120 "$LOG" >&2 || true
        exit 1
    fi

    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
done

echo "FAIL: timed out after ${TIMEOUT_SECONDS}s waiting for guest checks to finish" >&2
tail -n 120 "$LOG" >&2 || true
exit 1
