#!/usr/bin/env bash
# inspect-azl-nested-install.sh
#
# Purpose: Mount or unmount the nested dual-boot Azure Linux root and dump
#   journals without a full QEMU boot.
# Usage:   ./scripts/inspect-azl-nested-install.sh [--mount-only|--umount|--copy-logs DIR]
# Needs:   root or sudo; host partition env vars (see findings/dual-boot-*).
# CI:      No. Host dual-boot maintenance.

set -euo pipefail

PART="${AZL_NESTED_PART:-/dev/nvme0n1p4}"
MNT="${AZL_NESTED_MNT:-/mnt/azl-dual}"
ACTION="${1:-inspect}"
DEST="${2:-$HOME/azl-work/azl-boot-logs}"

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "re-exec with pkexec..." >&2
        exec pkexec env PATH="$PATH" bash "$0" "$@"
    fi
}

umount_all() {
    if mountpoint -q "$MNT" 2>/dev/null; then
        for d in dev/pts dev proc sys run home boot/efi boot; do
            umount -R "$MNT/$d" 2>/dev/null || umount "$MNT/$d" 2>/dev/null || true
        done
        umount -R "$MNT" 2>/dev/null || umount "$MNT" 2>/dev/null || true
    fi
    kpartx -d "$PART" 2>/dev/null || true
}

mount_all() {
    mkdir -p "$MNT"
    kpartx -d "$PART" 2>/dev/null || true
    kpartx -av "$PART"
    sleep 1
    mount /dev/mapper/nvme0n1p4p3 "$MNT"
    mount /dev/mapper/nvme0n1p4p2 "$MNT/boot"
    mount /dev/mapper/nvme0n1p4p1 "$MNT/boot/efi"
    mount /dev/mapper/nvme0n1p4p4 "$MNT/home"
}

case "$ACTION" in
    --umount|umount)
        need_root "$@"
        umount_all
        echo "unmounted $PART"
        ;;
    --mount-only|mount)
        need_root "$@"
        umount_all
        mount_all
        echo "mounted nested install at $MNT"
        lsblk "$PART"
        ;;
    --copy-logs)
        need_root "$@"
        umount_all
        mount_all
        mkdir -p "$DEST"
        if command -v journalctl >/dev/null 2>&1; then
            journalctl -D "$MNT/var/log/journal" -b --no-pager >"$DEST/journal-last-boot.txt" 2>"$DEST/journal-last-boot.err" || true
            journalctl -D "$MNT/var/log/journal" --list-boots >"$DEST/journal-boots.txt" 2>/dev/null || true
            journalctl -D "$MNT/var/log/journal" -b -p err..alert --no-pager >"$DEST/journal-errors.txt" 2>/dev/null || true
        fi
        mkdir -p "$DEST/var-log"
        cp -a "$MNT/var/log/." "$DEST/var-log/" 2>/dev/null || true
        cp -a "$MNT/boot/loader/entries/." "$DEST/loader-entries/" 2>/dev/null || true
        cp -a "$MNT/boot/grub2/grub.cfg" "$DEST/grub.cfg" 2>/dev/null || true
        echo "copied logs to $DEST"
        umount_all
        ;;
    inspect|*)
        need_root "$@"
        umount_all
        mount_all
        echo "=== nested lsblk ==="
        lsblk "$PART"
        echo "=== fstab ==="
        cat "$MNT/etc/fstab"
        echo "=== os-release ==="
        cat "$MNT/etc/os-release"
        echo "=== journal boots ==="
        journalctl -D "$MNT/var/log/journal" --list-boots 2>/dev/null || echo "(no journals yet)"
        echo "=== last boot journal (tail) ==="
        journalctl -D "$MNT/var/log/journal" -b --no-pager 2>/dev/null | tail -n 200 || true
        echo "=== errors ==="
        journalctl -D "$MNT/var/log/journal" -b -p err..alert --no-pager 2>/dev/null | tail -n 100 || true
        echo
        echo "Still mounted at $MNT. Run: $0 --umount"
        ;;
esac
