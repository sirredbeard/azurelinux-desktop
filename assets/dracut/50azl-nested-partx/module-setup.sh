#!/bin/bash
# dracut module: map nested GPT inside a host container partition so
# root=UUID=... resolves on bare-metal dual-boot.
#
# Host firmware only sees the container partition (e.g. nvme0n1p4).
# Nested ESP/boot/root live in a GPT inside that partition. Without
# kpartx before the root mount, the nested root UUID never appears.

check() {
    return 0
}

depends() {
    echo dm rootfs-block
}

install() {
    inst_multiple kpartx dmsetup blkid lsblk
    inst_hook pre-mount 10 "$moddir/azl-nested-partx.sh"
}
