# USB stick boot fails: CONFIG_USB_STORAGE off on AZL 4.0 x86_64

Tracked as GitHub issue #5.

**Status:** sibling kmod package published on Pages; live + installer ISOs
from release `2026.08.02` (post-kmod rebuild) carry
`usbhid`/`usb-storage`/`uas` in the installer initrd. Nested reinstall on
the host container partition completed with that installer. Overview:
[`out-of-tree-usb-kmods-pages.md`](out-of-tree-usb-kmods-pages.md).

## Claim check (issue comment 5085990451)

Comment said Microsoft's own `AzureLinux-4.0-x86_64.iso` has the same initrd
gap (only `xhci-plat-hcd.ko`, no `usb-storage`/`uas`).

**Verified true.**

| Artifact | Kernel in boot media | `usb-storage` | `uas` | `usbhid` | USB host modules in initrd |
| --- | --- | --- | --- | --- | --- |
| Official `https://aka.ms/azurelinux-4.0-x86_64.iso` (downloaded 2026-08-02, KIWI volume, kernel strings `6.18.31-1.3.azl4`) | 6.18.31-1.3.azl4 | **absent** | **absent** | **absent** | only `xhci-plat-hcd.ko.xz` |
| Project installer ISO (`azurelinux-desktop-install.iso`, 2026-08-02 release tree) | 6.18.31-1.9.azl4 | **absent** | **absent** | **absent** | only `xhci-plat-hcd.ko.xz` |
| Project live ISO (`azurelinux-desktop-live.iso`) | 6.18.31-1.9.azl4 | **absent** | **absent** | **present** (`extra/azurelinux-desktop/usbhid.ko`) | `xhci-plat-hcd` + project usbhid |

Method: `7z` extract `boot/x86_64/loader/initrd` (or live `images/pxeboot/initrd.img`),
`zstd`/`xz` decompress, `cpio -t`, grep module paths. Official and project
installer USB trees match the earlier report exactly.

Local copies under `~/azl-work/upstream-iso-research/` (not in git).

## Kernel config (not a dracut omission)

From `microsoft/azurelinux` `4.0`  
`base/comps/kernel/6.18-x86_64-azl.config`:

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

There is no `CONFIG_USB_UAS=m` on this arch when storage is off (UAS depends
on USB storage support in Kconfig).

Contrast:

| Config | `CONFIG_USB_STORAGE` | `CONFIG_USB_UAS` | `CONFIG_USB_HID` |
| --- | --- | --- | --- |
| AZL **4.0 x86_64** | not set | (absent / off) | not set |
| AZL **4.0 aarch64** | `=m` | `=m` | `=m` |
| AZL **3.0 x86_64** | `=m` | `=m` | `=m` |

Azure Linux 4.0 base `x86_64` package metadata has **zero** provides for
`usb-storage.ko` / `uas.ko` / `usbhid.ko`. Nothing to `dnf install`.

So:

- Stick enumerates on xHCI (controller is built-in / platform module exists).
- Nothing turns it into a SCSI disk (`usb-storage` / `uas`).
- Dracut waits forever for `/dev/disk/by-label/...` and `/dev/root`.
- This is not Rufus, not KIWI labeling, not "forgot add_drivers" alone.
  The module is not in the kernel package at all.

Built-in block pieces that **do** work without USB storage:

- NVMe / virtio / SATA-style paths used in QEMU and internal disks
  (`CONFIG_BLK_DEV_SD=y`, NVMe modules appear in initrds).
- Optical: `CONFIG_BLK_DEV_SR=y`, `isofs` is a module and is present in
  official and project initrds. Real DVD / BMC virtual CD should still work.

Also off on 4.0 x86_64 (present on aarch64 and/or 3.0): `CONFIG_USB_EHCI_HCD`,
`CONFIG_USB_OHCI_HCD`, `CONFIG_USB_UHCI_HCD`. Controllers that only speak
those host protocols (no xHCI) will not get a working USB stack even after
we add storage modules. Modern ThinkPad-class machines use xHCI, so the
primary stick-boot failure mode is still missing `usb-storage`/`uas`.

`CONFIG_HID=m` and `CONFIG_HID_GENERIC=m` stay on; only the USB HID
*transport* (`usbhid`) is compiled out. That is why the existing out-of-tree
usbhid kmod is enough for mice/keyboards once root is mounted.

Related upstream noise (not a fix, context only):

- WSL side discussion of USB_STORAGE disabled:
  https://github.com/microsoft/WSL/issues/12869
- Older AZL bare-metal install thread (3.0 era):
  https://github.com/microsoft/azurelinux/issues/10972
- Official 4.0 ISO is built as a VM installer image
  (`base/images/vm-iso-installer`); USB stick boot was never that product's
  job.

## Why live has usbhid but still cannot boot from USB stick

The project already carries out-of-tree **usbhid** via
`publish-desktop-kmods.yml` + `scripts/build-desktop-kmods.sh` and
`azurelinux-desktop-policy` (see `findings/azure-kernel-usbhid-kmod.md`).
Live lorax installs that package; dracut `add_drivers+=" usbhid "` puts it
in the live initrd. That fixes USB **input** after (or during) a boot that
already found the root filesystem.

USB **stick as the live/install medium** needs **block** drivers in the
initrd **before** root. usbhid does not provide that. Live initrd still has
no `usb-storage`/`uas`.

Installer ISO KIWI image package list (`kiwi/azl-desktop-installer.kiwi`)
does **not** even install `azurelinux-desktop-policy` into the bootable
installer environment. Installer initrd therefore matches upstream: no
usbhid either. The policy package is wired for the **installed target**
offline repo (`kiwi/config.sh`), not for the installer's own initrd.

## Workarounds that already work (no new kmod)

These respect "prefer AZL packages/tooling" and avoid a second module:

1. **Install without USB mass-storage media**
   - QEMU/KVM with the ISO as virtual CD and a disk/partition target
     (used for nested host-partition dual-boot; see
     `findings/dual-boot-nested-host-partition.md`).
   - Hardware/BMC virtual CD.
   - Real optical disc (SR + isofs available).
2. **Boot the installed system from NVMe/SATA** after such an install.
   Bare-metal dual-boot of the nested install already reached GNOME.

These do **not** make "write ISO to USB stick, boot stick" work.

## Solution options (no microsoft/azurelinux kernel PR from us)

### A. Upstream config change (best long-term, not under our merge control)

Ask Azure Linux to set on **4.0 x86_64** (matching aarch64 and 3.0 x86_64):

- `CONFIG_USB_STORAGE=m`
- `CONFIG_USB_UAS=m`
- preferably also `CONFIG_USB_HID=m` (drops need for usbhid kmod)

Cost on cloud VMs is small (modules, not built-in). Asymmetry with aarch64
strongly suggests desktop/installer USB was not a deliberate x86_64 product
requirement. **Do not open a kernel PR from this project unless that policy
changes;** an upstream **issue** with the ISO evidence below is enough.

If upstream ships modules in `kernel-modules*`, we delete the out-of-tree
storage (and eventually HID) kmods and go back to stock packages.

### B. Sibling USB storage kmod on the existing Pages pipeline (**implemented**)

**Status:** in tree. Separate package, same channel as usbhid.

Same protections as usbhid (`publish-desktop-kmods.yml`, policy RPM, exact
`kernel-core-uname-r` Requires, vermagic check, Secure Boot caveat):

1. Build out-of-tree **`usb-storage.ko`** and **`uas.ko`** from the matching
   CBL-Mariner/Azure kernel source against `kernel-devel` + `Module.symvers`
   (USB core and SCSI are built-in on this config).
2. Ship them in **`azurelinux-desktop-usb-storage-kmod`** (not inside the
   usbhid RPM) under
   `/usr/lib/modules/$KVERREL/extra/azurelinux-desktop/`.
3. Policy Requires **both** `azurelinux-desktop-usbhid-kmod` and
   `azurelinux-desktop-usb-storage-kmod` at the same EVR as the policy.
4. Dracut drop-in on the storage package:
   `add_drivers+=" usb-storage uas "` (usbhid keeps its own drop-in).
5. Image builders install `azurelinux-desktop-policy` **before** initrd
   generation:
   - Live kickstart: already had policy.
   - Disk kickstart: kmods repo + policy + `.repo` file (parity with live).
   - Installer KIWI image: Pages repo + policy so the **installer initrd**
     gains the modules, not only the installed-target offline repo.
6. Canary resolves policy and checks all three `.ko` paths.
7. Publisher still runs on the 4-hour detector; kernel bumps still need a
   matched rebuild (module versioning). `republish=true` forces a full
   rebuild when adding a new sibling package for an already-published
   kernel.

No second Pages repo. No full custom kernel.

### C. Rejected / last resort under project goals

| Idea | Why not (unless A and B both fail hard) |
| --- | --- |
| Fedora `kernel` on the ISO | Breaks "Azure Linux packages first"; dual ABI/firmware mess |
| Full custom Azure kernel rebuild in CI | Far heavier than two modules; Secure Boot/signing worse |
| Dracut `hostonly=no` / more `add_drivers` alone | Cannot add modules that do not exist in `/lib/modules` |
| Ventoy/dd "mode" tricks | Still need `usb-storage`/`uas` once the stick is a USB disk |

## Recommended path

1. **B is implemented** in the build/publish path; verify on rebuilt
   live/installer media that initrds contain `usb-storage.ko` and `uas.ko`
   and that a USB stick boot reaches the live/installer root.
2. Keep non-USB install media documented as a fallback (optical, BMC/virt
   CD, QEMU-to-disk then bare metal).
3. **File/track upstream issue** (not a PR) with the official ISO initrd
   listing and the aarch64/3.0 asymmetry. Drop B when A ships.

## Evidence commands (repro)

```bash
# official
aria2c -x 15 -o AzureLinux-4.0-x86_64.iso https://aka.ms/azurelinux-4.0-x86_64.iso
7z x -o/tmp/azl-off AzureLinux-4.0-x86_64.iso boot/x86_64/loader/initrd
zstd -dc /tmp/azl-off/boot/x86_64/loader/initrd | cpio -t | grep -iE 'usb-storage|uas\.ko|usbhid|xhci'
```

Expect only `xhci-plat-hcd` on official and current project installer initrds.
