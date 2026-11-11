#!/usr/bin/env bash
# build-flash-image-arm.sh - assemble the Ventuno Q flashable image set
#
# Purpose:
#   Turn the ARM64 live build products (the live ISO and its LiveOS
#   squashfs) into the flashable set for the Arduino Ventuno Q: a
#   system-boot FAT image, a writable ext4 image, and a rawprogram XML
#   that programs exactly those two partitions and nothing else. The
#   board's eMMC layout belongs to the Qualcomm boot chain (p1-p68 are
#   the XBL/ABL/firmware set, p70 is persist), so there is no installer
#   ISO for this board and no whole-disk image: flashing writes the two
#   OS partitions in place. See issue #43 and
#   findings/ventunoq-arm-hardware-enablement.md.
#
# Usage:
#   build-flash-image-arm.sh <live-iso> <squashfs-img> <output-dir>
#
# Outputs (in <output-dir>):
#   azurelinux-desktop-flash-system-boot-arm.img  512 MiB FAT32, the
#     EFI/ubuntu layout ABL loads shim and grub from. The firmware
#     hands the kernel its device tree, so grub.cfg carries no
#     devicetree directive (it is the live image's own grub.cfg).
#   azurelinux-desktop-flash-writable-arm.img     the live image's
#     rootfs (LiveOS/rootfs.img out of the squashfs), byte for byte.
#   azurelinux-desktop-flash-rawprogram-arm.xml   two <program>
#     entries in the stock package's format: label "efi" at sector
#     6031360 (p69) and label "system" at sector 7141376 (p71).
#     Geometry read off the shipping board's GPT on 2026-11-11.
#
# Requirements:
#   bash, coreutils, xorriso, squashfs-tools (unsquashfs), dosfstools
#   (mkfs.vfat), mtools (mmd, mcopy). No loop mounts, no root.
#
# CI:
#   Yes - .github/workflows/build-flash-image-arm.yml. Also run by hand
#   on ventunoq for the first assembly (2026-11-11), which this script
#   codifies.
set -euo pipefail

iso="${1:-}"
squashfs="${2:-}"
outdir="${3:-}"

if [[ -z "$iso" || ! -f "$iso" ]]; then
  echo "build-flash-image-arm: missing live ISO: ${iso:-<none>}" >&2
  exit 1
fi
if [[ -z "$squashfs" || ! -f "$squashfs" ]]; then
  echo "build-flash-image-arm: missing squashfs image: ${squashfs:-<none>}" >&2
  exit 1
fi
if [[ -z "$outdir" ]]; then
  echo "build-flash-image-arm: missing output dir" >&2
  exit 1
fi
mkdir -p "$outdir"
outdir=$(cd "$outdir" && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Stock GPT geometry for the two OS partitions (sector size 512).
# p69 "efi":    start 6031360, 1048576 sectors (512 MiB)
# p71 "system": start 7141376, 117180383 sectors (55.9 GiB)
efi_start=6031360
efi_sectors=1048576
sys_start=7141376

# --- writable: the rootfs out of the squashfs, unchanged ---
unsquashfs -q -f -d "$work/sqfs" "$squashfs" >/dev/null
rootimg=$(find "$work/sqfs" -name 'rootfs.img' | head -1)
if [[ -z "$rootimg" ]]; then
  echo "build-flash-image-arm: no LiveOS/rootfs.img inside $squashfs" >&2
  exit 1
fi
cp --sparse=always "$rootimg" "$outdir/azurelinux-desktop-flash-writable-arm.img"
writable_bytes=$(stat -c %s "$outdir/azurelinux-desktop-flash-writable-arm.img")
writable_sectors=$(( writable_bytes / 512 ))
writable_kb=$(awk -v b="$writable_bytes" 'BEGIN { printf "%.1f", b / 1024 }')

# --- system-boot: 512 MiB FAT32 in the installed EFI/ubuntu layout ---
xorriso -osirrox on -indev "$iso" -extract /EFI "$work/efi" 2>/dev/null
# osirrox puts the contents of /EFI in the target dir (BOOT, not
# EFI/BOOT); find the boot files instead of assuming the layout.
efi_src=$(dirname "$(find "$work/efi" -name 'grubaa64.efi' | head -1)")
for f in BOOTAA64.EFI grubaa64.efi grub.cfg; do
  if [[ ! -f "$efi_src/$f" ]]; then
    echo "build-flash-image-arm: $f missing from the ISO EFI tree" >&2
    exit 1
  fi
done
esp="$outdir/azurelinux-desktop-flash-system-boot-arm.img"
dd if=/dev/zero of="$esp" bs=1M count=512 status=none
mkfs.vfat -F 32 -n 'system-boot' "$esp" >/dev/null
export MTOOLS_SKIP_CHECK=1
mmd -i "$esp" ::EFI ::EFI/BOOT ::EFI/ubuntu
mcopy -i "$esp" "$efi_src/BOOTAA64.EFI" ::EFI/BOOT/BOOTAA64.EFI
mcopy -i "$esp" "$efi_src/grub.cfg" ::EFI/BOOT/grub.cfg
# ABL's boot entry points at EFI/ubuntu, the layout the stock system
# ships: the removable-media shim becomes shimaa64.efi there.
mcopy -i "$esp" "$efi_src/BOOTAA64.EFI" ::EFI/ubuntu/shimaa64.efi
mcopy -i "$esp" "$efi_src/grubaa64.efi" ::EFI/ubuntu/grubaa64.efi
if [[ -f "$efi_src/mmaa64.efi" ]]; then
  mcopy -i "$esp" "$efi_src/mmaa64.efi" ::EFI/ubuntu/mmaa64.efi
fi
mcopy -i "$esp" "$efi_src/grub.cfg" ::EFI/ubuntu/grub.cfg

# --- rawprogram: two entries, stock attribute shape, nothing else ---
efi_byte_hex=$(printf '0x%x' $(( efi_start * 512 )))
sys_byte_hex=$(printf '0x%x' $(( sys_start * 512 )))
cat > "$outdir/azurelinux-desktop-flash-rawprogram-arm.xml" <<EOF
<?xml version="1.0" ?>
<data>
  <!-- Ventuno Q OS partitions only. Geometry from the shipping board's
       GPT (2026-11-11). The firehose programmer and the CDT come from
       Arduino's stock image package; this file programs system-boot
       (p69, GPT name "efi") and writable (p71, GPT name "system") and
       nothing else: no GPT, no firmware partitions, no persist. -->
  <program start_sector="$efi_start" size_in_KB="524288.0" physical_partition_number="0" partofsingleimage="false" file_sector_offset="0" num_partition_sectors="$efi_sectors" readbackverify="false" filename="azurelinux-desktop-flash-system-boot-arm.img" sparse="false" start_byte_hex="$efi_byte_hex" SECTOR_SIZE_IN_BYTES="512" label="efi"/>
  <program start_sector="$sys_start" size_in_KB="$writable_kb" physical_partition_number="0" partofsingleimage="false" file_sector_offset="0" num_partition_sectors="$writable_sectors" readbackverify="false" filename="azurelinux-desktop-flash-writable-arm.img" sparse="false" start_byte_hex="$sys_byte_hex" SECTOR_SIZE_IN_BYTES="512" label="system"/>
</data>
EOF

sha256sum "$outdir"/azurelinux-desktop-flash-*
echo "build-flash-image-arm: done"
