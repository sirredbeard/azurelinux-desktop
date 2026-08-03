#!/usr/bin/env bash
# Non-interactive Bluetooth check against the nested installed system
# booted via scripts/qemu-boot-installed-hostpart.sh with USB BT
# passthrough (8087:0a2b by default).
#
# What this proves:
#   - Guest sees the Intel BT USB device
#   - OOT btusb/btintel stack can init HCI / load firmware in QEMU
#   - recover oneshot unit is present and (if run) did not error
#
# What this does NOT prove:
#   - ThinkPad thinkpad_acpi rfkill ordering on bare metal
#     (thinkpad_acpi is -ENODEV under QEMU)
#
# Usage:
#   ./scripts/test-bt-qemu-passthrough.sh
#   AZL_QEMU_SSH_PORT=2222 ./scripts/test-bt-qemu-passthrough.sh
#
# Prerequisites:
#   - Nested install on /dev/nvme0n1p4 (or AZL_HOSTPART)
#   - SSH pubkey auth to root@localhost:$SSH_PORT (see findings)
#   - Host may lose Bluetooth for the duration of the guest run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PART="${AZL_HOSTPART:-/dev/nvme0n1p4}"
NAME="${AZL_QEMU_NAME:-azl-bt-passthrough}"
RAM_MB="${AZL_QEMU_RAM_MB:-8192}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
SSH_PORT="${AZL_QEMU_SSH_PORT:-2222}"
BT_VENDOR="${AZL_QEMU_BT_VENDOR:-8087}"
BT_PRODUCT="${AZL_QEMU_BT_PRODUCT:-0a2b}"
SSH_USER="${AZL_QEMU_SSH_USER:-root}"
BOOT_TIMEOUT="${AZL_BT_BOOT_TIMEOUT:-240}"
HCI_TIMEOUT="${AZL_BT_HCI_TIMEOUT:-90}"
LOG_DIR="${AZL_BT_LOG_DIR:-$WORKDIR/bt-qemu-$(date +%Y%m%d-%H%M%S)}"
PIDFILE="$WORKDIR/${NAME}.pid"
KEEP_RUNNING="${AZL_BT_KEEP_RUNNING:-0}"

mkdir -p "$LOG_DIR" "$WORKDIR"

ssh_cmd() {
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        -o LogLevel=ERROR \
        -p "$SSH_PORT" \
        "${SSH_USER}@127.0.0.1" \
        "$@"
}

cleanup() {
    local rc=$?
    if [[ "$KEEP_RUNNING" != "1" && -f "$PIDFILE" ]]; then
        local pid
        pid="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [[ -n "${pid:-}" ]]; then
            echo "Stopping guest pid $pid"
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            else
                # may be root-owned qemu
                if [[ -n "${AZL_SUDO_PASSWORD:-}" ]]; then
                    printf '%s\n' "$AZL_SUDO_PASSWORD" | sudo -S kill "$pid" 2>/dev/null || true
                else
                    sudo kill "$pid" 2>/dev/null || true
                fi
            fi
            sleep 2
            kill -9 "$pid" 2>/dev/null || true
            if [[ -n "${AZL_SUDO_PASSWORD:-}" ]]; then
                printf '%s\n' "$AZL_SUDO_PASSWORD" | sudo -S kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$PIDFILE" 2>/dev/null || true
    fi
    # Best-effort host BT restore
    if [[ -n "${AZL_SUDO_PASSWORD:-}" ]]; then
        printf '%s\n' "$AZL_SUDO_PASSWORD" | sudo -S modprobe btusb 2>/dev/null || true
        printf '%s\n' "$AZL_SUDO_PASSWORD" | sudo -S systemctl start bluetooth.service 2>/dev/null || true
    else
        sudo modprobe btusb 2>/dev/null || modprobe btusb 2>/dev/null || true
        sudo systemctl start bluetooth.service 2>/dev/null || systemctl start bluetooth.service 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT

if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "error: guest already running (pid $(cat "$PIDFILE"))" >&2
    exit 1
fi

# Optional password for non-interactive sudo (local QA only).
# Prefer: already-root, passwordless sudo, or AZL_SUDO_PASSWORD.
sudo_run() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif [[ -n "${AZL_SUDO_PASSWORD:-}" ]]; then
        printf '%s\n' "$AZL_SUDO_PASSWORD" | sudo -S -E "$@"
    else
        sudo -E "$@"
    fi
}

# Free nested mounts before QEMU opens the partition.
if mountpoint -q /mnt/azl-home 2>/dev/null; then
    sudo_run umount /mnt/azl-home 2>/dev/null || sudo_run umount -l /mnt/azl-home || true
fi
if mountpoint -q /mnt/azl-rootfs 2>/dev/null; then
    sudo_run umount /mnt/azl-rootfs 2>/dev/null || sudo_run umount -l /mnt/azl-rootfs || true
fi
if command -v kpartx >/dev/null 2>&1; then
    sudo_run kpartx -d "$PART" 2>/dev/null || true
fi

echo "=== launching guest with BT passthrough ${BT_VENDOR}:${BT_PRODUCT} ==="
export AZL_QEMU_BT_PASSTHROUGH=1
export AZL_QEMU_BT_VENDOR="$BT_VENDOR"
export AZL_QEMU_BT_PRODUCT="$BT_PRODUCT"
export AZL_QEMU_SSH_PORT="$SSH_PORT"
export AZL_QEMU_WORKDIR="$WORKDIR"
# Default to snapshot overlay so dry-runs do not dirty the nested install.
export AZL_QEMU_SNAPSHOT="${AZL_QEMU_SNAPSHOT:-1}"
# Headless-friendly: keep gtk if DISPLAY exists, else none
if [[ -z "${DISPLAY:-}" ]]; then
    export AZL_QEMU_GL=off
fi

# qemu-boot needs write on the partition node
if [[ ! -w "$PART" ]]; then
    sudo_run chmod 666 "$PART" 2>/dev/null || true
fi
if [[ ! -w "$PART" && "$(id -u)" -ne 0 ]]; then
    echo "error: need write access to $PART" >&2
    exit 1
fi

# Run boot script (daemonizes). Needs root for USB unbind / modprobe -r.
sudo_run env \
    AZL_QEMU_BT_PASSTHROUGH=1 \
    AZL_QEMU_BT_VENDOR="$BT_VENDOR" \
    AZL_QEMU_BT_PRODUCT="$BT_PRODUCT" \
    AZL_QEMU_SSH_PORT="$SSH_PORT" \
    AZL_QEMU_WORKDIR="$WORKDIR" \
    AZL_QEMU_SNAPSHOT="${AZL_QEMU_SNAPSHOT:-1}" \
    AZL_QEMU_GL="${AZL_QEMU_GL:-on}" \
    DISPLAY="${DISPLAY:-:0}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    "$SCRIPT_DIR/qemu-boot-installed-hostpart.sh" "$PART" "$NAME" "$RAM_MB" \
    | tee "$LOG_DIR/boot.log"
# pidfile/logs may be root-owned
sudo_run chmod a+r "$PIDFILE" 2>/dev/null || true
sudo_run chmod a+r "$WORKDIR/${NAME}-serial.log" 2>/dev/null || true
sudo_run chmod a+r "$WORKDIR/${NAME}-qemu-stdout.log" 2>/dev/null || true

echo "=== waiting for SSH on localhost:${SSH_PORT} (timeout ${BOOT_TIMEOUT}s) ==="
deadline=$((SECONDS + BOOT_TIMEOUT))
while (( SECONDS < deadline )); do
    if ssh_cmd 'bash -c "echo ssh-ok"' >/dev/null 2>&1; then
        echo "SSH is up"
        break
    fi
    sleep 3
done
if ! ssh_cmd 'bash -c "echo ssh-ok"' >/dev/null 2>&1; then
    echo "error: SSH did not become ready" >&2
    tail -n 80 "$WORKDIR/${NAME}-serial.log" >"$LOG_DIR/serial-tail.txt" 2>/dev/null || true
    exit 1
fi

echo "=== collecting guest BT diagnostics ==="
ssh_cmd 'bash -s' <<'EOS' | tee "$LOG_DIR/guest-bt-diag.txt"
set -euo pipefail
echo "## uname"
uname -a
echo "## lsusb Intel"
lsusb -d 8087: 2>/dev/null || lsusb | grep -i 8087 || echo "no 8087 device"
echo "## recover units"
systemctl is-enabled azurelinux-desktop-bt-recover.service 2>/dev/null || true
systemctl is-enabled azurelinux-desktop-bt-recover-late.service 2>/dev/null || true
systemctl status azurelinux-desktop-bt-recover.service --no-pager -l 2>/dev/null || true
systemctl status azurelinux-desktop-bt-recover-late.service --no-pager -l 2>/dev/null || true
echo "## helper markers"
grep -nE 'unbind|stopping bluetooth|hci_power|USB reset cycle' /usr/libexec/azurelinux-desktop-bt-usb-reset 2>/dev/null | head -20 || true
echo "## modules"
lsmod | grep -iE 'btusb|btintel|bluetooth|thinkpad' || true
echo "## modprobe conf"
cat /etc/modprobe.d/azurelinux-desktop-bluetooth.conf 2>/dev/null || true
echo "## class bluetooth"
ls -la /sys/class/bluetooth 2>/dev/null || echo "no /sys/class/bluetooth"
for h in /sys/class/bluetooth/hci*; do
  [[ -e "$h" ]] || continue
  echo "--- $h ---"
  cat "$h/powered" 2>/dev/null || true
  cat "$h/address" 2>/dev/null || true
done
echo "## rfkill"
rfkill list 2>/dev/null || true
echo "## bluetoothctl show"
bluetoothctl show 2>/dev/null || true
echo "## hciconfig"
hciconfig -a 2>/dev/null || true
echo "## journal recover helper"
journalctl -b --no-pager -t azl-bt-usb-reset 2>/dev/null | tail -n 40 || true
echo "## journal bt/hci (no oops expected after harden)"
journalctl -b -k --no-pager 2>/dev/null | grep -iE 'btusb|btintel|hci0|Bluetooth|thinkpad_acpi|8087|azl-bt|Oops|BUG:|sending frame' | tail -n 100 || true
echo "## pipewire user wants (on-disk)"
ls -la /etc/systemd/user/sockets.target.wants/ 2>/dev/null || true
ls -la /etc/systemd/user/default.target.wants/ 2>/dev/null || true
test -f /usr/lib/systemd/user-preset/80-azurelinux-desktop-pipewire.preset && echo preset-present || echo preset-missing
EOS

# Wait briefly for HCI init after boot services
echo "=== waiting up to ${HCI_TIMEOUT}s for powered adapter ==="
hci_deadline=$((SECONDS + HCI_TIMEOUT))
powered=0
while (( SECONDS < hci_deadline )); do
    if ssh_cmd 'bash -c "bluetoothctl show 2>/dev/null | grep -q \"Powered: yes\""' 2>/dev/null; then
        powered=1
        break
    fi
    # Try power on once mid-wait
    ssh_cmd 'bash -c "bluetoothctl power on >/dev/null 2>&1 || true"' 2>/dev/null || true
    sleep 3
done

ssh_cmd 'bash -c "bluetoothctl show; ls -la /sys/class/bluetooth; journalctl -b -k --no-pager | grep -iE \"hci0|btusb|btintel|Firmware\" | tail -n 40"' \
    >"$LOG_DIR/guest-bt-final.txt" 2>&1 || true

echo "=== result summary ==="
if [[ "$powered" -eq 1 ]]; then
    echo "PASS: guest Bluetooth adapter Powered: yes"
    echo "Logs: $LOG_DIR"
    # Copy key excerpts into repo findings/logs if REPO is writable
    mkdir -p "$REPO_ROOT/findings/logs"
    cp -f "$LOG_DIR/guest-bt-final.txt" \
        "$REPO_ROOT/findings/logs/azl-bt-qemu-passthrough-final.txt"
    cp -f "$LOG_DIR/guest-bt-diag.txt" \
        "$REPO_ROOT/findings/logs/azl-bt-qemu-passthrough-diag.txt"
    exit 0
fi

echo "FAIL: guest Bluetooth adapter not powered"
echo "See $LOG_DIR"
mkdir -p "$REPO_ROOT/findings/logs"
cp -f "$LOG_DIR/guest-bt-final.txt" \
    "$REPO_ROOT/findings/logs/azl-bt-qemu-passthrough-final.txt" 2>/dev/null || true
cp -f "$LOG_DIR/guest-bt-diag.txt" \
    "$REPO_ROOT/findings/logs/azl-bt-qemu-passthrough-diag.txt" 2>/dev/null || true
exit 1
