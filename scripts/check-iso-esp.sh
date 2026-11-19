#!/usr/bin/env bash
# check-iso-esp.sh
#
# Purpose: Fail if an ISO's EFI system partition cannot boot. The
#   shim loads its second stage (grubx64.efi) from its own vendor
#   directory on the ESP (\EFI\<vendor>\grubx64.efi). The installer
#   ISO shipped in release 2026.11.11 staged Fedora's grub under
#   EFI/fedora and Azure's shim under EFI/azurelinux, with no grub
#   next to the shim, and failed on hardware with "Failed to open
#   \EFI\azurelinux\grubx64.efi - Not Found". A file listing is not
#   enough; this checks the paths the boot chain actually opens in
#   the El Torito UEFI image's FAT filesystem: grubx64.efi in the
#   same vendor directory as shimx64.efi, plus the removable-media
#   fallback pair in EFI/BOOT.
# Usage:   ./scripts/check-iso-esp.sh <iso>
# Needs:   bash, xorriso, dd, mtools (mdir)
# CI:      Runs in build-installer-iso.yml after the kiwi build and
#          before the ISO is uploaded or published.

set -euo pipefail

iso="${1:?usage: check-iso-esp.sh <iso>}"
if [ ! -f "$iso" ]; then
    echo "check-iso-esp: no such file: $iso" >&2
    exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# The UEFI El Torito entry names the ESP image by LBA (2048-byte
# sectors) and load size (512-byte sectors). Some writers record a
# load size of 0; fall back to the report's block count for that
# image, then to extracting the image file by its path.
report="$(xorriso -indev "$iso" -report_el_torito plain 2>/dev/null)"
uefi_line="$(awk '/boot img/ && $7 == "UEFI" { print $6, $NF, $(NF-1) }' <<< "$report")"
if [ -z "$uefi_line" ]; then
    echo "check-iso-esp: no UEFI El Torito image in $iso" >&2
    exit 1
fi
read -r imgnum lba load_sectors <<< "$uefi_line"
blocks=$(( load_sectors / 4 ))
if [ "$blocks" -eq 0 ]; then
    blocks="$(awk -v n="$imgnum" '/img blks/ && $6 == n { print $7 }' <<< "$report")"
fi
if [ -n "${blocks:-}" ] && [ "$blocks" -gt 0 ]; then
    dd if="$iso" of="$workdir/esp.img" bs=2048 skip="$lba" \
        count="$blocks" status=none
else
    imgpath="$(awk -v n="$imgnum" '/img path/ && $6 == n { print $7 }' <<< "$report")"
    if [ -z "$imgpath" ]; then
        echo "check-iso-esp: cannot locate the ESP image in $iso" >&2
        exit 1
    fi
    xorriso -osirrox on -indev "$iso" \
        -extract "$imgpath" "$workdir/esp.img" 2>/dev/null
fi

# mdir -s -b prints one "::/EFI/<path>" line per entry, directories
# with a trailing slash. Match the listing in lowercase.
listing="$(mdir -s -b -i "$workdir/esp.img" :: | tr '[:upper:]' '[:lower:]')"

fail=0
need() {
    if ! grep -qxF "::/efi/$(tr '[:upper:]' '[:lower:]' <<< "$1")" <<< "$listing"; then
        echo "check-iso-esp: ESP is missing /EFI/$1" >&2
        fail=1
    fi
}

# Removable-media fallback path.
need "BOOT/bootx64.efi"
need "BOOT/grubx64.efi"

# The shim's second stage must sit in the shim's own vendor
# directory, for every vendor directory that carries a shim.
shimfound=0
while IFS= read -r shimpath; do
    [ -n "$shimpath" ] || continue
    shimfound=1
    shimdir="${shimpath%/shimx64.efi}"
    if ! grep -qxF "$shimdir/grubx64.efi" <<< "$listing"; then
        echo "check-iso-esp: ESP is missing /EFI/$(basename "$shimdir")/grubx64.efi (the shim's second stage)" >&2
        fail=1
    fi
done <<< "$(grep -E '::/efi/[^/]+/shimx64\.efi' <<< "$listing" || true)"
if [ "$shimfound" -eq 0 ]; then
    echo "check-iso-esp: no shimx64.efi under any /EFI/<vendor> on the ESP" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "check-iso-esp: ESP boot chain OK in $iso"
