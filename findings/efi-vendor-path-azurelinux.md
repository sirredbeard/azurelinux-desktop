# EFI vendor path: azurelinux vs fedora

**Status:** resolved.

## Problem

After install, firmware NVRAM points at `EFI/azurelinux/shimx64.efi`, but
Fedora's Secure Boot-signed shim/grub RPMs install under `EFI/fedora/`.
If `EFI/azurelinux/` is empty, the system does not boot from the path
Anaconda registered.

## Cause

We exclude Azure Linux's unsigned `shim-x64` and `grub2-efi-x64` and use
Fedora's signed stack. Anaconda still creates an Azure Linux vendor NVRAM
entry. Path and files disagree until something copies the binaries.

## Fix

`kiwi/post-bootloader.sh` copies `shimx64.efi`, `shim.efi`, `grubx64.efi`,
and `mmx64.efi` from `EFI/fedora/` to `EFI/azurelinux/` when the
azurelinux copies are missing.

Do not reintroduce Azure's unsigned shim/grub just to skip this copy.

Also rewrite every EFI stub `grub.cfg` (`EFI/azurelinux`, `EFI/BOOT`, and
`EFI/fedora` when present) to the final `/boot` filesystem UUID. Fedora's
shim fallback often loads `EFI/fedora/grub.cfg`. A stale package-time UUID
there drops GRUB to a bare `grub>` prompt
(`search.c: no such device: <stale-uuid>`). Confirmed on nested
host-partition QA.

## References

* `kiwi/post-bootloader.sh`
* `anaconda-kickstart-patterns.md`
* `uefi-bdsdxe-text-before-plymouth.md`
