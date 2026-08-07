# Installer: /boot/efi must be on a separate partition

**Status:** Fix staged 2026-08-07 (`reqpart` in `kiwi/azl-install.ks.in`).
Needs installer ISO rebuild + Boxes Standard Partition retest.

## Symptom

Interactive install of the installer ISO (UEFI). In Installation Destination,
choose the disk, use all free space / automatic layout, **Standard Partition**.
Anaconda reports that `/boot/efi` must be on a separate partition (or LV) and
will not let the layout complete. User reports this as a regression.

**Not seen** on clean-room QEMU install of the same `2026.08.07` ISO when
using **LVM** (ESP on `vda1`, `/boot` on `vda2`, LVM root). Failure is
Standard Partition path in GNOME Boxes.

## Product kickstart (before fix)

`kiwi/azl-install.ks.in` had **no** `clearpart` / `autopart` / `part` /
`reqpart` so the TUI owned disk pick and layout. Only bare:

```
bootloader
```

Upstream Microsoft `azl-install.ks` always creates ESP explicitly:

```
clearpart --all --initlabel
part /boot/efi --fstype=efi --size=600
part /boot ...
```

(or `autopart --type=lvm` in the encrypted variant).

Live kickstart already had `reqpart` next to its `clearpart`/`part` lines.

## Cause (Anaconda)

Checker `verify_mountpoints_not_on_root()` errors when `/boot/efi` is missing
from the proposed mountpoints on UEFI (`STORAGE_MUST_NOT_BE_ON_ROOT`). The ESP
is required by the EFI platform `PartSpec` but is only scheduled reliably when
autopart/`reqpart`/explicit `part /boot/efi` runs. Pure interactive **Standard
Partition** + "use all free space" can leave no ESP in `storage.mountpoints`.

LVM automatic layout usually creates the ESP without `reqpart`.

## Fix

Add bare `reqpart` under `bootloader` in `kiwi/azl-install.ks.in`. Schedules
platform-required partitions (ESP on UEFI) without `clearpart`/`autopart`.
Disk selection stays interactive.

```
bootloader
reqpart
```

Do **not** re-add bare-metal-unsafe `clearpart --all` to the product ks.

## Workaround on current release ISO (`2026.08.07`)

Use **LVM** automatic partitioning, or Custom and create an EFI System
Partition + `/` yourself.

## Verification (next installer ISO)

- Boxes / QEMU UEFI: Standard Partition + use all free space completes.
- Installed system has vfat ESP at `/boot/efi` and `EFI/azurelinux`
  bootloader files from `post-bootloader.sh`.
- LVM path still works (no regression).

## Related

- `findings/anaconda-kickstart-patterns.md` (storage interactive policy)
- `findings/efi-vendor-path-azurelinux.md`
- `findings/installer-iso-2026.08.07-verify.md`
- Upstream: `reference/azl-installer/azl-install.ks`
