# USB stick boot fails: CONFIG_USB_STORAGE off on Azure Linux 4.0 x86_64

Tracked as GitHub issue #5.

**Status:** sibling storage kmod on Pages; live and installer media pull storage modules into initrd via policy. Overview: `out-of-tree-usb-kmods-pages.md`.

## Claim check

Comment said Microsoft's own `AzureLinux-4.0-x86_64.iso` has the same initrd gap (only `xhci-plat-hcd.ko`, no `usb-storage` / `uas`).

**Verified true** on a fresh official 4.0 x86_64 ISO (KIWI volume). Method: extract initrd, decompress, `cpio -t`, grep module paths. Official initrd had xHCI platform module only. Early project installer media matched that gap before policy landed in the installer image environment.

## Kernel config (not a dracut omission)

From `microsoft/azurelinux` `base/comps/kernel/6.18-x86_64-azl.config`:

```
CONFIG_USB_SUPPORT=y
CONFIG_USB=y
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_XHCI_PCI=y
CONFIG_USB_XHCI_PLATFORM=m
# CONFIG_USB_STORAGE is not set
# CONFIG_USB_HID is not set
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y
CONFIG_BLK_DEV_SR=y
CONFIG_ISO9660_FS=m
```

There is no `CONFIG_USB_UAS=m` on this arch when storage is off.

Contrast:

* AZL 4.0 x86_64: USB_STORAGE / UAS / USB_HID not set
* AZL 4.0 aarch64: all three `=m`
* AZL 3.0 x86_64: all three `=m`

Azure Linux 4.0 base x86_64 metadata has zero provides for `usb-storage.ko` / `uas.ko` / `usbhid.ko`. Nothing to `dnf install`.

So:

* Stick enumerates on xHCI (controller is built-in or platform module exists).
* Nothing turns it into a SCSI disk (`usb-storage` / `uas`).
* Dracut waits forever for `/dev/disk/by-label/...` and `/dev/root`.
* This is not Rufus, not KIWI labeling, and not "forgot add_drivers" alone. The module is not in the kernel package at all.

Built-in block pieces that do work without USB storage:

* NVMe / virtio / SATA-style paths used in QEMU and internal disks
* Optical: `CONFIG_BLK_DEV_SR=y`, isofs module present in official and project initrds

Also off on 4.0 x86_64 (present on aarch64 and/or 3.0): EHCI / OHCI / UHCI host controllers. Machines that only speak those protocols still need more than storage modules. Modern ThinkPad-class machines use xHCI, so the primary stick-boot failure is missing `usb-storage` / `uas`.

`CONFIG_HID=m` and `CONFIG_HID_GENERIC=m` stay on. Only the USB HID transport (`usbhid`) is compiled out. That is why the usbhid kmod is enough for mice/keyboards once root is mounted.

Context only (not a fix):

* WSL discussion of USB_STORAGE disabled: https://github.com/microsoft/WSL/issues/12869
* Older AZL bare-metal install thread (3.0 era): https://github.com/microsoft/azurelinux/issues/10972
* Official 4.0 ISO is a VM installer image (`base/images/vm-iso-installer`); USB stick boot was never that product's job

## Why live had usbhid but still could not boot from a stick

Out-of-tree usbhid via `publish-desktop-kmods.yml` + `scripts/build-desktop-kmods.sh` and policy fixed USB **input** after a boot that already found root.

USB **stick as the live/install medium** needs **block** drivers in the initrd **before** root. usbhid does not provide that.

Early installer KIWI image lists did not install policy into the bootable installer environment. Installer initrd then matched upstream. Policy must land in the installer image itself, not only the installed-target offline repo (`kiwi/config.sh`).

## Workarounds without a storage kmod

These still work and stay useful as fallbacks:

1. Install without USB mass-storage media
   * QEMU/KVM with the ISO as virtual CD and a disk/partition target (see `dual-boot-nested-host-partition.md`)
   * Hardware/BMC virtual CD
   * Real optical disc (SR + isofs)
2. Boot the installed system from NVMe/SATA after such an install

These do not make "write ISO to USB stick, boot stick" work.

## Solution options

### A. Upstream config change (best long-term, not under our merge control)

Ask Azure Linux to set on 4.0 x86_64 (matching aarch64 and 3.0 x86_64):

* `CONFIG_USB_STORAGE=m`
* `CONFIG_USB_UAS=m`
* preferably `CONFIG_USB_HID=m`

Cost on cloud VMs is small (modules, not built-in). Prefer an upstream **issue** with ISO evidence over a kernel PR from this project. If upstream ships modules in `kernel-modules*`, delete the out-of-tree storage (and eventually HID) kmods.

### B. Sibling storage kmod on the existing Pages pipeline (implemented)

Separate package, same channel as usbhid and the rest of the desktop families.

1. Build out-of-tree `usb-storage.ko` and `uas.ko` from matching CBL-Mariner/Azure kernel source against `kernel-devel` + `Module.symvers`.
2. Ship in **`azurelinux-desktop-storage-kmod`** under `/usr/lib/modules/$KVERREL/extra/azurelinux-desktop/`. Provides/Obsoletes the old `azurelinux-desktop-usb-storage-kmod` name.
3. Policy Requires storage-kmod (and every other sibling) at the same EVR.
4. Dracut drop-in: `add_drivers+=" usb-storage uas "` (usbhid keeps its own drop-in; dual drop-in names cover the rename).
5. Image builders install `azurelinux-desktop-policy` **before** initrd generation:
   * Live kickstart
   * Disk kickstart
   * Installer KIWI image (so the **installer initrd** gains the modules)
6. Canary resolves policy and checks the `.ko` paths.
7. Publisher detect covers storage under the current name. `republish=true` forces a full rebuild when adding siblings for an already-published kernel. `prune_old=true` drops other-kernel RPMs on publish.

No second Pages repo. No full custom kernel.

### C. Rejected under project goals

* Fedora `kernel` on the ISO - breaks "Azure Linux packages first"
* Full custom Azure kernel rebuild in CI - far heavier than two modules
* Dracut `hostonly=no` / more `add_drivers` alone - cannot add modules that do not exist in `/lib/modules`
* Ventoy/dd mode tricks - still need `usb-storage` / `uas` once the stick is a USB disk

## Recommended path

1. B is implemented. Verify rebuilt live/installer media initrds contain `usb-storage.ko` and `uas.ko`, and that a USB stick boot reaches root.
2. Keep non-USB install media documented as fallback.
3. Track upstream issue (not a PR) with the official ISO initrd listing and the aarch64/3.0 asymmetry. Drop B when A ships.

## Evidence commands (repro)

```bash
aria2c -x 15 -o AzureLinux-4.0-x86_64.iso https://aka.ms/azurelinux-4.0-x86_64.iso
# extract boot/.../initrd from the ISO, decompress, then:
cpio -t < initrd | grep -iE 'usb-storage|uas\.ko|usbhid|xhci'
```

Expect only `xhci-plat-hcd` on stock official initrds. Project media with policy should list the extra modules under `extra/azurelinux-desktop/`.
