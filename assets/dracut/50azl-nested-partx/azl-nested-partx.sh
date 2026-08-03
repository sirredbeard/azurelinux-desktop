#!/bin/sh
# pre-mount: expose partitions nested inside a host container partition.
# Prefer the known dual-boot container node, then fall back to scanning.

type kpartx >/dev/null 2>&1 || exit 0

try_map() {
    _dev="$1"
    [ -b "$_dev" ] || return 1
    case "$_dev" in
        /dev/mapper/*) return 1 ;;
    esac
    kpartx -av "$_dev" >/dev/null 2>&1 || return 1
    return 0
}

# Fast path used by this project's dual-boot layout.
for _d in /dev/nvme0n1p4 /dev/nvme0n1p5 /dev/sda4 /dev/vda4; do
    if try_map "$_d"; then
        exit 0
    fi
done

# Broader scan: large partitions that may hold a nested desktop GPT.
if command -v lsblk >/dev/null 2>&1; then
    lsblk -rno NAME,TYPE,SIZE 2>/dev/null | while read -r name type size; do
        [ "$type" = "part" ] || continue
        case "$size" in
            *G*|*T*) ;;
            *) continue ;;
        esac
        try_map "/dev/$name" && exit 0
    done
fi

exit 0
