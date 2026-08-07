#!/usr/bin/env bash
# qemu-headless-install-to-qcow2.sh
#
# Purpose: Unattended installer ISO install into a fresh test qcow2
#   (not a host partition). Temporary kickstart:
#     - admin user/password (defaults fedora/fedora)
#     - only the virtio test disk
#     - clearpart + standard autopart (/, ESP on UEFI)
#     - reboot when Anaconda finishes
#   Product ISO stays interactive; this ks is local-test only.
# Usage:
#   ./scripts/qemu-headless-install-to-qcow2.sh INSTALL.iso [name] [ram_mb] [disk_gb]
# Env:
#   AZL_TEST_USER / AZL_TEST_PASS  admin account (default fedora/fedora)
#   AZL_INSTALL_DISK               guest disk name (default vda)
#   AZL_SSH_PORT / AZL_KS_PORT     host forwards (default 2222 / 8765)
#   AZL_QEMU_WORKDIR               default ~/azl-work
# Needs: qemu-kvm, OVMF, 7z, openssl, python3, ssh; sshpass recommended
# CI: No.

set -euo pipefail

ISO="${1:?usage: $0 /path/to/azurelinux-desktop-install.iso [name] [ram_mb] [disk_gb]}"
NAME="${2:-azl-installed-test}"
RAM_MB="${3:-8192}"
DISK_GB="${4:-40}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
DISK="$WORKDIR/${NAME}.qcow2"
STAGE="$WORKDIR/${NAME}-headless"
LOG="$WORKDIR/${NAME}-install-serial.log"
PIDFILE="$WORKDIR/${NAME}-install.pid"
SSH_PORT="${AZL_SSH_PORT:-2222}"
KS_PORT="${AZL_KS_PORT:-8765}"
ADMIN_USER="${AZL_TEST_USER:-fedora}"
ADMIN_PASS="${AZL_TEST_PASS:-fedora}"
INSTALL_DISK="${AZL_INSTALL_DISK:-vda}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/qemu-uefi-common.sh
source "$SCRIPT_DIR/qemu-uefi-common.sh"

[[ -f "$ISO" ]] || { echo "error: ISO not found: $ISO" >&2; exit 1; }
for bin in 7z openssl python3 qemu-system-x86_64 qemu-img; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: missing $bin" >&2; exit 1; }
done

mkdir -p "$WORKDIR"
rm -rf "$STAGE"
mkdir -p "$STAGE/bootextract"
azl_find_ovmf
OVMF_VARS="$(azl_prepare_ovmf_vars "$WORKDIR" "${NAME}-install")"

echo "Extracting installer kernel/initrd and product kickstart..."
7z x -y -o"$STAGE/bootextract" "$ISO" \
  "boot/x86_64/loader/linux" \
  "boot/x86_64/loader/initrd" \
  "root/azl-install.ks" >/dev/null
KERNEL="$STAGE/bootextract/boot/x86_64/loader/linux"
INITRD="$STAGE/bootextract/boot/x86_64/loader/initrd"
PROD_KS="$STAGE/bootextract/root/azl-install.ks"
if [[ ! -f "$KERNEL" || ! -f "$INITRD" ]]; then
  KERNEL="$(find "$STAGE/bootextract" -type f -name linux | head -1)"
  INITRD="$(find "$STAGE/bootextract" -type f -name initrd | head -1)"
fi
[[ -s "${KERNEL:-}" && -s "${INITRD:-}" ]] \
  || { echo "error: kernel/initrd missing after extract" >&2; find "$STAGE" -type f | head -40 >&2; exit 1; }
[[ -f "$PROD_KS" ]] \
  || { echo "error: product root/azl-install.ks not on ISO" >&2; exit 1; }

PASS_HASH="$(printf "%s\n" "$ADMIN_PASS" | openssl passwd -6 -stdin)"
KS="$STAGE/test-install.ks"

python3 - "$PROD_KS" "$KS" "$PASS_HASH" "$ADMIN_USER" "$INSTALL_DISK" <<'PY'
import sys
from pathlib import Path

prod, out, pw_hash, user, disk = sys.argv[1:6]
lines = Path(prod).read_text().splitlines()
out_lines = []
inserted_storage = False
skip_rootpw = False

storage_block = f"""
# --- headless QEMU test storage (local only; not on product ISO) ---
ignoredisk --only-use={disk}
zerombr
clearpart --all --initlabel --drives={disk}
autopart --type=plain
# --- end headless storage ---
""".strip("\n").splitlines()

account_block = [
    f"rootpw --iscrypted {pw_hash}",
    (
        f"user --name={user} --groups=wheel "
        f"--password={pw_hash} --iscrypted --shell=/usr/bin/pwsh"
    ),
]

for line in lines:
    stripped = line.strip()
    if stripped.startswith("rootpw"):
        if not skip_rootpw:
            out_lines.extend(account_block)
            skip_rootpw = True
        continue
    if stripped.startswith("user "):
        continue
    if stripped.startswith("bootloader") and not inserted_storage:
        out_lines.append(line)
        out_lines.extend(storage_block)
        inserted_storage = True
        continue
    out_lines.append(line)

if not skip_rootpw:
    out_lines = account_block + out_lines
if not inserted_storage:
    final = []
    done = False
    for line in out_lines:
        final.append(line)
        if (not done) and line.strip().startswith("repo "):
            final.extend(storage_block)
            done = True
    out_lines = final

if not any(l.strip().startswith("reboot") for l in out_lines):
    final = []
    placed = False
    for line in out_lines:
        if (not placed) and line.startswith("%"):
            final.append("reboot --eject")
            placed = True
        final.append(line)
    if not placed:
        final.append("reboot --eject")
    out_lines = final

Path(out).write_text("\n".join(out_lines) + "\n")
print(f"wrote {out} ({len(out_lines)} lines), disk={disk}, user={user}")
PY

for need in \
  "ignoredisk --only-use=${INSTALL_DISK}" \
  "clearpart --all --initlabel --drives=${INSTALL_DISK}" \
  "autopart" \
  "user --name=${ADMIN_USER}" \
  "repo --name=azl-offline" \
  "reboot"
 do
  grep -qF "$need" "$KS" || { echo "error: kickstart missing: $need" >&2; exit 1; }
done
grep -qE "user --name=.*--iscrypted" "$KS" || { echo "error: user line incomplete" >&2; exit 1; }

python3 - "$STAGE" "$KS_PORT" <<'PY' &
import http.server, socketserver, sys, os
root, port = sys.argv[1], int(sys.argv[2])
os.chdir(root)
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("0.0.0.0", port), H) as httpd:
    httpd.serve_forever()
PY
HTTPD_PID=$!

# Terminate a process by numeric PID only (graceful then force).
stop_pid() {
  local pid="${1:-}"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0
  if command -v /bin/kill >/dev/null 2>&1; then
    /bin/kill -0 "$pid" 2>/dev/null || return 0
    /bin/kill "$pid" 2>/dev/null || true
    sleep 1
    /bin/kill -0 "$pid" 2>/dev/null || return 0
    /bin/kill -9 "$pid" 2>/dev/null || true
  fi
}

cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    stop_pid "$(cat "$PIDFILE" 2>/dev/null || true)"
    rm -f "$PIDFILE"
  fi
  stop_pid "${HTTPD_PID:-}"
}
trap cleanup EXIT

rm -f "$DISK" "$LOG" "$PIDFILE"
qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" >/dev/null

# Direct-kernel boot. inst.ks= makes anaconda-launcher skip interactive
# username/password and disk TUI and run Anaconda on our temporary ks.
CMDLINE="console=ttyS0,115200 console=tty0 earlyprintk=serial,ttyS0,115200"
CMDLINE+=" rhgb quiet enforcing=0 audit=0 inst.lang=en_US.UTF-8"
CMDLINE+=" root=live:CDLABEL=CDROM rd.live.image"
CMDLINE+=" azl.autoinstall inst.nosave=all_ks"
CMDLINE+=" inst.ks=http://10.0.2.2:${KS_PORT}/test-install.ks"
CMDLINE+=" inst.text"

echo "=== headless install ==="
echo "ISO:     $ISO"
echo "Disk:    $DISK (${DISK_GB}G virtio -> guest /dev/${INSTALL_DISK})"
echo "Admin:   ${ADMIN_USER}"
echo "KS URL:  http://10.0.2.2:${KS_PORT}/test-install.ks"
echo "SSH:     localhost:${SSH_PORT} after reboot"
echo "Serial:  $LOG"
echo

: >"$LOG"
qemu-system-x86_64 \
  -name "${NAME}-install" \
  -machine q35,accel=kvm,kernel-irqchip=on \
  -cpu host \
  -smp 4 \
  -m "$RAM_MB" \
  -drive if=pflash,format=raw,readonly=on,file="$AZL_OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -append "$CMDLINE" \
  -drive id=installiso,if=none,media=cdrom,readonly=on,file="$ISO" \
  -device ide-cd,drive=installiso,bootindex=1 \
  -drive "id=sysdisk,if=none,file=${DISK},format=qcow2,cache=writeback,discard=unmap" \
  -device "virtio-blk-pci,drive=sysdisk,bootindex=2,serial=AZLTEST1" \
  -device virtio-net-pci,netdev=net0 \
  -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
  -device virtio-rng-pci \
  -display none \
  -serial "file:${LOG}" \
  -monitor none \
  -pidfile "$PIDFILE" \
  -daemonize

echo "QEMU pid $(cat "$PIDFILE")"
echo "Waiting for install + reboot (serial: $LOG)..."

deadline=$((SECONDS + 7200))
install_done=0
while (( SECONDS < deadline )); do
  if [[ -f "$LOG" ]]; then
    if grep -qE "installation failed|Traceback \(most recent|anaconda:.*failed|Error code [1-9]" "$LOG" 2>/dev/null; then
      echo "error: install failure signature in serial log" >&2
      tail -120 "$LOG" >&2 || true
      exit 1
    fi
    if grep -qE "Installation complete" "$LOG" 2>/dev/null; then
      install_done=1
      echo "Detected Installation complete."
      break
    fi
    if grep -qE "Installing boot loader|Performing post-installation" "$LOG" 2>/dev/null \
      && grep -qE "Restarting system|Reached target Reboot|reboot: Restarting" "$LOG" 2>/dev/null; then
      install_done=1
      echo "Detected post-install + reboot markers."
      break
    fi
  fi
  if [[ -f "$PIDFILE" ]]; then
    qpid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$qpid" && "$qpid" =~ ^[0-9]+$ ]] && ! /bin/kill -0 "$qpid" 2>/dev/null; then
      echo "error: QEMU exited before install completion" >&2
      tail -120 "$LOG" >&2 || true
      exit 1
    fi
  fi
  sleep 15
done
if [[ "$install_done" -ne 1 ]]; then
  echo "error: timed out waiting for install completion" >&2
  tail -120 "$LOG" >&2 || true
  exit 1
fi

echo "Waiting for SSH after reboot (${ADMIN_USER}@localhost:${SSH_PORT})..."
ssh_ok=0
ssh_deadline=$((SECONDS + 1800))
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$SSH_PORT")
while (( SECONDS < ssh_deadline )); do
  if command -v sshpass >/dev/null 2>&1; then
    if sshpass -p "$ADMIN_PASS" ssh "${SSH_OPTS[@]}" "${ADMIN_USER}@127.0.0.1" \
        "bash -c \"echo installed-ok && uname -a\"" 2>/dev/null; then
      ssh_ok=1
      break
    fi
  else
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${ADMIN_USER}@127.0.0.1" "true" 2>/dev/null; then
      ssh_ok=1
      break
    fi
  fi
  if [[ -f "$PIDFILE" ]]; then
    qpid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$qpid" && "$qpid" =~ ^[0-9]+$ ]] && ! /bin/kill -0 "$qpid" 2>/dev/null; then
      echo "warning: QEMU exited while waiting for SSH"
      break
    fi
  fi
  sleep 10
done

if [[ "$ssh_ok" -eq 1 ]]; then
  echo "Installed system is up over SSH; shutting down cleanly..."
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$ADMIN_PASS" ssh "${SSH_OPTS[@]}" "${ADMIN_USER}@127.0.0.1" \
      "bash -c \"echo ${ADMIN_PASS} | sudo -S shutdown -h now\"" 2>/dev/null || true
  fi
  for _ in $(seq 1 60); do
    if [[ -f "$PIDFILE" ]]; then
      qpid="$(cat "$PIDFILE" 2>/dev/null || true)"
      if [[ -n "$qpid" && "$qpid" =~ ^[0-9]+$ ]] && /bin/kill -0 "$qpid" 2>/dev/null; then
        sleep 5
        continue
      fi
    fi
    break
  done
else
  echo "warning: SSH did not come up; stopping guest after grace period"
  sleep 30
fi

if [[ -f "$PIDFILE" ]]; then
  stop_pid "$(cat "$PIDFILE" 2>/dev/null || true)"
  rm -f "$PIDFILE"
fi
trap - EXIT
stop_pid "${HTTPD_PID:-}"

echo
echo "Install finished."
echo "  disk:   $DISK"
echo "  serial: $LOG"
echo "  ks:     $KS"
echo "Verify with:"
echo "  ./scripts/verify-release-features.sh --installed-qcow $DISK"
ls -lh "$DISK"
