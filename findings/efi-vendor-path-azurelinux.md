# EFI vendor path: azurelinux vs fedora

**Status:** Resolved

## Observed failure

After install, the firmware NVRAM entry points at
`EFI/azurelinux/shimx64.efi`, but Fedora's Secure Boot-signed shim/grub RPMs
install their binaries under `EFI/fedora/`. The installed system can fail to
boot from the expected vendor path when `EFI/azurelinux/` is empty.

## Root cause

This project excludes Azure Linux's unsigned `shim-x64` and `grub2-efi-x64` and uses
Fedora's signed stack instead. Anaconda still creates an Azure Linux vendor
NVRAM path. Without a copy step, the path and the files disagree.

## Resolution

`kiwi/post-bootloader.sh` copies `shimx64.efi`, `shim.efi`, `grubx64.efi`,
and `mmx64.efi` from `EFI/fedora/` to `EFI/azurelinux/` when the azurelinux
binaries are absent.

Do not reintroduce Azure Linux's unsigned shim/grub only to avoid this copy.

Also rewrite **every** EFI stub `grub.cfg` (`EFI/azurelinux`, `EFI/BOOT`,
and `EFI/fedora` when present) to the final `/boot` filesystem UUID.
Fedora's package/shim fallback often loads `EFI/fedora/grub.cfg`. Anaconda
can leave a package-time UUID there that does not match the installed
`/boot`, which drops GRUB to a bare `grub>` prompt
(`search.c: no such device: <stale-uuid>`). Confirmed on nested host-partition
QA 2026-08-03.
## Evidence

- Applied in installer interactive testing batch (2026-07-23), build
  `29984033898`.
- Static qcow2 mount later confirmed `EFI/azurelinux/shimx64.efi` present
  (AQ 2026-07-24).

## References

- `kiwi/post-bootloader.sh`
- Related: `anaconda-kickstart-patterns.md`, `uefi-bdsdxe-text-before-plymouth.md`
