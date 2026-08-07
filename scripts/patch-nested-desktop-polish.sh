#!/usr/bin/env bash
# patch-nested-desktop-polish.sh
#
# Purpose: Apply current-tree GRUB skip-menu, Plymouth theme, and first-boot
#   SELinux drop-in to the nested host-partition install without a full
#   reinstall. Regenerates nested initramfs so early splash matches rootfs.
# Usage:   ./scripts/patch-nested-desktop-polish.sh [/dev/nvme0n1p4]
# Needs:   sudo (password), guest QEMU stopped, kpartx.
# CI:      No.

set -euo pipefail
PART="${1:-${AZL_NESTED_PART:-/dev/nvme0n1p4}}"
MNT="${AZL_NESTED_MNT:-/mnt/azl-dual}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo env PATH="$PATH" bash "$0" "$@"
fi

if fuser "$PART" >/dev/null 2>&1; then
  echo "error: $PART is in use (stop QEMU first)" >&2
  exit 1
fi

cleanup() {
  for d in boot/efi boot home; do umount "$MNT/$d" 2>/dev/null || true; done
  umount "$MNT" 2>/dev/null || true
  kpartx -d "$PART" 2>/dev/null || true
}
trap cleanup EXIT

kpartx -d "$PART" 2>/dev/null || true
kpartx -av "$PART"
sleep 1
mkdir -p "$MNT"
mount /dev/mapper/nvme0n1p4p3 "$MNT"
mount /dev/mapper/nvme0n1p4p2 "$MNT/boot"
mount /dev/mapper/nvme0n1p4p1 "$MNT/boot/efi" 2>/dev/null || true

install -m 0644 "$REPO/assets/plymouth/azurelinux/azurelinux.script" \
  "$MNT/usr/share/plymouth/themes/azurelinux/azurelinux.script"
install -m 0755 "$REPO/assets/bin/azl-first-boot-prepare" \
  "$MNT/usr/libexec/azurelinux-desktop/azl-first-boot-prepare"
install -d -m 0755 "$MNT/usr/lib/systemd/system/selinux-autorelabel.service.d"
install -m 0644 "$REPO/assets/systemd/selinux-autorelabel.service.d/10-azurelinux-desktop.conf" \
  "$MNT/usr/lib/systemd/system/selinux-autorelabel.service.d/10-azurelinux-desktop.conf"

# GRUB: skip menu; never let recordfail force a text list
if [[ -f "$MNT/boot/grub2/grub.cfg" ]]; then
  sed -i 's/^set timeout=.*/set timeout=0/' "$MNT/boot/grub2/grub.cfg"
  if grep -q '^set timeout_style=' "$MNT/boot/grub2/grub.cfg"; then
    sed -i 's/^set timeout_style=.*/set timeout_style=hidden/' "$MNT/boot/grub2/grub.cfg"
  else
    sed -i '/^set timeout=0/a set timeout_style=hidden' "$MNT/boot/grub2/grub.cfg"
  fi
  if ! grep -q '^unset recordfail' "$MNT/boot/grub2/grub.cfg"; then
    sed -i '/^set timeout_style=hidden/a load_env\nunset recordfail\nsave_env recordfail' \
      "$MNT/boot/grub2/grub.cfg"
  fi
fi
if [[ -f "$MNT/etc/default/grub" ]]; then
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' "$MNT/etc/default/grub"
  if grep -q '^GRUB_TIMEOUT_STYLE=' "$MNT/etc/default/grub"; then
    sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' "$MNT/etc/default/grub"
  else
    echo 'GRUB_TIMEOUT_STYLE=hidden' >> "$MNT/etc/default/grub"
  fi
  if grep -q '^GRUB_RECORDFAIL_TIMEOUT=' "$MNT/etc/default/grub"; then
    sed -i 's/^GRUB_RECORDFAIL_TIMEOUT=.*/GRUB_RECORDFAIL_TIMEOUT=0/' "$MNT/etc/default/grub"
  else
    echo 'GRUB_RECORDFAIL_TIMEOUT=0' >> "$MNT/etc/default/grub"
  fi
  if grep -q '^GRUB_DISABLE_OS_PROBER=' "$MNT/etc/default/grub"; then
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' "$MNT/etc/default/grub"
  else
    echo 'GRUB_DISABLE_OS_PROBER=true' >> "$MNT/etc/default/grub"
  fi
fi

# Rebuild initramfs so Plymouth early theme matches (unit-name spam fix).
KVER="$(ls -1 "$MNT/usr/lib/modules" 2>/dev/null | sort -V | tail -1 || true)"
if [[ -n "$KVER" ]] && [[ -x "$MNT/usr/bin/dracut" || -x "$MNT/usr/sbin/dracut" ]]; then
  mount --bind /dev "$MNT/dev"
  mount --bind /proc "$MNT/proc"
  mount --bind /sys "$MNT/sys"
  chroot "$MNT" dracut -f --kver "$KVER" || chroot "$MNT" dracut -f "/boot/initramfs-${KVER}.img" "$KVER" || true
  umount "$MNT/dev" "$MNT/proc" "$MNT/sys" 2>/dev/null || true
  echo "dracut refreshed for $KVER"
fi

echo "nested polish patched on $PART"
