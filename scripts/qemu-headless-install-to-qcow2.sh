#!/usr/bin/env bash
# qemu-headless-install-to-qcow2.sh
#
# Purpose: Unattended installer ISO -> fresh test qcow2 (not host
#   partitions). Temporary clearpart/autopart kickstart for the test
#   only. Product installer stays interactive TUI.
# Usage:
#   ./scripts/qemu-headless-install-to-qcow2.sh INSTALL.iso [name] [ram_mb] [disk_gb]
# Needs: qemu-kvm, OVMF, 7z, openssl, python3.
# CI: No. Local dogfood under ~/azl-work.

set -euo pipefail

ISO="${1:?usage: $0 /path/to/azurelinux-desktop-install.iso [name] [ram_mb] [disk_gb]}"
NAME="${2:-azl-installed-test}"
RAM_MB="${3:-8192}"
DISK_GB="${4:-40}"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
DISK="$WORKDIR/${NAME}.qcow2"
STAGE="$WORKDIR/${NAME}-headless"
LOG="$WORKDIR/${NAME}-install-qemu.log"
SSH_PORT="${AZL_SSH_PORT:-2222}"
ADMIN_USER="${AZL_TEST_USER:-fedora}"
ADMIN_PASS="${AZL_TEST_PASS:-fedora}"
KS_PORT="${AZL_KS_PORT:-8765}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/qemu-uefi-common.sh
source "$SCRIPT_DIR/qemu-uefi-common.sh"

[[ -f "$ISO" ]] || { echo "error: ISO not found: $ISO" >&2; exit 1; }
command -v 7z >/dev/null 2>&1 || { echo "error: 7z required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "error: openssl required" >&2; exit 1; }

mkdir -p "$WORKDIR"
rm -rf "$STAGE"
mkdir -p "$STAGE"
azl_find_ovmf
OVMF_VARS="$(azl_prepare_ovmf_vars "$WORKDIR" "${NAME}-install")"

# Extract installer kernel/initrd (+ product kickstart when present).
7z e -y -o"$STAGE" "$ISO" \
  boot/x86_64/loader/linux \
  boot/x86_64/loader/initrd \
  root/azl-install.ks \
  >/dev/null 2>&1 || true
if [[ ! -s "$STAGE/linux" ]]; then
  7z e -y -o"$STAGE" "$ISO" '*linux' '*initrd' 'azl-install.ks' >/dev/null 2>&1 || true
fi
KERNEL="$(find "$STAGE" -type f \( -name linux -o -name 'vmlinuz*' \) | head -1)"
INITRD="$(find "$STAGE" -type f -name 'initrd*' | head -1)"
[[ -n "$KERNEL" && -s "$KERNEL" && -n "$INITRD" && -s "$INITRD" ]] \
  || { echo "error: kernel/initrd extract failed under $STAGE" >&2; ls -laR "$STAGE" >&2; exit 1; }

PASS_HASH="$(printf '%s\n' "$ADMIN_PASS" | openssl passwd -6 -stdin)"
KS="$STAGE/test-install.ks"
{
  printf '%s\n' \
    '# Local headless QEMU test kickstart only. Not on the product ISO.' \
    'lang en_US.UTF-8' \
    'keyboard us' \
    'timezone UTC' \
    'network --bootproto=dhcp --hostname=azl-test' \
    "rootpw --iscrypted ${PASS_HASH}" \
    "user --name=${ADMIN_USER} --groups=wheel --password=${PASS_HASH} --iscrypted --shell=/usr/bin/pwsh" \
    'bootloader' \
    'zerombr' \
    'clearpart --all --initlabel' \
    'autopart' \
    'reboot' \
    ''
  if [[ -f "$STAGE/azl-install.ks" ]]; then
    awk '
      /^%packages/ { keep=1 }
      /^%post/ { keep=1 }
      keep { print }
    ' "$STAGE/azl-install.ks"
  else
    echo "warning: product azl-install.ks missing from ISO extract" >&2
    printf '%s\n' '%packages --nocore' '@core' '%end'
  fi
} >"$KS"

python3 - "$STAGE" "$KS_PORT" <<'PY' &
import http.server, socketserver, sys, os
root, port = sys.argv[1], int(sys.argv[2])
os.chdir(root)
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass
with socketserver.TCPServer(("127.0.0.1", port), H) as httpd:
    httpd.serve_forever()
PY
HTTPD_PID=$!
cleanup() { kill "$HTTPD_PID" 2>/dev/null || true; }
trap cleanup EXIT

rm -f "$DISK"
qemu-img create -f qcow2 "$DISK" "${DISK_GB}G"

CMDLINE="inst.stage2=hd:LABEL=CDROM root=live:CDLABEL=CDROM rd.live.image"
CMDLINE+=" inst.repo=hd:LABEL=CDROM"
CMDLINE+=" inst.ks=http://10.0.2.2:${KS_PORT}/test-install.ks"
CMDLINE+=" inst.text inst.cmdline console=ttyS0,115200n8"
CMDLINE+=" enforcing=0 audit=0 inst.lang=en_US.UTF-8 inst.nosave=all_ks"
CMDLINE+=" azl.autoinstall"

echo "Installing $ISO -> $DISK (${DISK_GB}G, ${RAM_MB}MB RAM)"
echo "Kickstart HTTP port ${KS_PORT}; SSH forward ${SSH_PORT}"
echo "Log: $LOG"

set +e
qemu-system-x86_64 \
  -name "${NAME}-install" \
  -m "$RAM_MB" -smp 4 \
  -enable-kvm -cpu host \
  -drive if=pflash,format=raw,readonly=on,file="$AZL_OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -cdrom "$ISO" \
  -drive file="$DISK",format=qcow2,if=virtio \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -append "$CMDLINE" \
  -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
  -device virtio-net-pci,netdev=net0 \
  -display none \
  -serial "file:${LOG}" \
  -monitor none \
  -no-reboot
rc=$?
set -e

echo "Install qemu exited rc=$rc"
ls -lh "$DISK"
echo "Next: boot $DISK, then scripts/verify-release-features.sh --installed-qcow $DISK"
exit "$rc"
