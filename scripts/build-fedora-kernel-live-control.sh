#!/usr/bin/env bash
# Build a disposable Azure live-root control that boots a Fedora kernel.
set -euo pipefail

INPUT_ISO="${1:?usage: $0 /path/to/azure-live.iso /path/to/output.iso}"
OUTPUT_ISO="${2:?usage: $0 /path/to/azure-live.iso /path/to/output.iso}"
WORKDIR="${AZL_FEDORA_KERNEL_CONTROL_WORKDIR:-$HOME/azl-work/fedora-kernel-live-control}"

for command in aria2c dnf5 xorriso unsquashfs rpm2cpio cpio; do
    command -v "$command" >/dev/null || {
        echo "error: $command is required" >&2
        exit 1
    }
done

[ -f "$INPUT_ISO" ] || {
    echo "error: input ISO not found: $INPUT_ISO" >&2
    exit 1
}
[ ! -e "$OUTPUT_ISO" ] || {
    echo "error: output ISO already exists: $OUTPUT_ISO" >&2
    exit 1
}

mkdir -p "$WORKDIR"
SQUASHFS="$WORKDIR/azure-live-root.squashfs"
ROOTFS="$WORKDIR/rootfs"
RPMS="$WORKDIR/rpms"

if [ -e "$ROOTFS" ]; then
    echo "error: control root already exists: $ROOTFS" >&2
    exit 1
fi

mkdir -p "$RPMS"
xorriso -osirrox on -indev "$INPUT_ISO" \
    -extract /LiveOS/squashfs.img "$SQUASHFS"
unsquashfs -d "$ROOTFS" "$SQUASHFS"

KERNEL_EVR="$(
    dnf5 repoquery --refresh --releasever=43 --repo=fedora \
        --available --latest-limit=1 --qf '%{evr}' kernel | head -1
)"
test -n "$KERNEL_EVR"
KERNEL_VERSION="$KERNEL_EVR.x86_64"

FEDORA_RELEASE_BASE="https://download.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/Packages/k"
RPM_URLS=(
    "$FEDORA_RELEASE_BASE/kernel-$KERNEL_EVR.x86_64.rpm"
    "$FEDORA_RELEASE_BASE/kernel-core-$KERNEL_EVR.x86_64.rpm"
    "$FEDORA_RELEASE_BASE/kernel-modules-core-$KERNEL_EVR.x86_64.rpm"
    "$FEDORA_RELEASE_BASE/kernel-modules-$KERNEL_EVR.x86_64.rpm"
    "$FEDORA_RELEASE_BASE/kernel-modules-extra-$KERNEL_EVR.x86_64.rpm"
)
for rpm_url in "${RPM_URLS[@]}"; do
    aria2c --dir "$RPMS" --file-allocation=none --auto-file-renaming=false "$rpm_url"
done

for rpm in "$RPMS"/*.rpm; do
    rpm -Kv "$rpm" | grep -Fq 'Payload SHA256 digest: OK'
    rpm2cpio "$rpm" | sudo cpio -idm --quiet -D "$ROOTFS"
done

FEDORA_KERNEL_DIR="$ROOTFS/usr/lib/modules/$KERNEL_VERSION"
[ -d "$FEDORA_KERNEL_DIR" ] || {
    echo "error: Fedora kernel modules were not staged for $KERNEL_VERSION" >&2
    exit 1
}

sudo chroot "$ROOTFS" depmod "$KERNEL_VERSION"
sudo mount --bind /dev "$ROOTFS/dev"
sudo mount -t proc proc "$ROOTFS/proc"
sudo mount --rbind /sys "$ROOTFS/sys"
sudo mount --make-rslave "$ROOTFS/sys"

cleanup_chroot_mounts() {
    sudo umount -R "$ROOTFS/sys" || true
    sudo umount "$ROOTFS/proc" || true
    sudo umount "$ROOTFS/dev" || true
}
trap cleanup_chroot_mounts EXIT

sudo chroot "$ROOTFS" dracut --force \
    --kver "$KERNEL_VERSION" \
    --add dmsquash-live \
    --add-drivers "virtio_pci virtio_blk xhci_pci usbhid psmouse" \
    "/boot/initramfs-$KERNEL_VERSION.img"

VMLINUX="$FEDORA_KERNEL_DIR/vmlinuz"
INITRD="$ROOTFS/boot/initramfs-$KERNEL_VERSION.img"
[ -s "$VMLINUX" ] && [ -s "$INITRD" ] || {
    echo "error: Fedora kernel or initramfs was not generated" >&2
    exit 1
}
sudo chmod a+r "$INITRD"

xorriso -indev "$INPUT_ISO" -outdev "$OUTPUT_ISO" \
    -boot_image any replay \
    -map "$VMLINUX" /images/pxeboot/vmlinuz \
    -map "$INITRD" /images/pxeboot/initrd.img \
    -commit

echo "Built Azure-root/Fedora-kernel control: $OUTPUT_ISO"
