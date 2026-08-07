# Plymouth boot animation

**Status:** Working on live ISO, qcow2, installer ISO, and installed
system paths after the serial-console and initramfs fixes. Theme is
`azurelinux` (script plugin).

## What it is

Plymouth provides the graphical boot splash (Azure Linux penguin logo +
animated glowing-dot ring) across live ISO, qcow2 disk image, and
installer ISO. Each path builds initramfs differently.

## Serial console suppresses graphical splash

**Status:** Resolved

Azure Linux inherits `console=ttyS0,...` from its cloud origin.
Plymouth reads `/sys/class/tty/console/active`. Any non-local console
(for example `ttyS0`) forces the details/text path and returns early
without DRM setup. The graphical theme never loads, even with
`rhgb quiet`.

Installer ISO cmdline should be:

```
console=tty0 rhgb quiet ...
```

Installed system: `kiwi/post-bootloader.sh` must not write
`console=ttyS0` into the normal BLS entry.

`inst.text` alone does not suppress Plymouth. It only selects Anaconda
TUI. `plymouth.ignore-serial-consoles` is not a kernel parameter; prefer
removing serial from the desktop cmdline.

## Initramfs theme bundling

- Installer (KIWI, often generic dracut): stage theme files in
  `kiwi/config.sh` **before** `plymouth-set-default-theme azurelinux`,
  then regenerate initramfs. Runtime squashfs conf is not visible during
  initramfs Plymouth.
- qcow2: after theme selection, run `dracut --force --kver <kver>` for
  every directory under `/usr/lib/modules`. Bare `dracut -f` uses the
  build container's `uname -r`, not the Azure kernel. Skipping this
  leaves `script.so` and theme assets out of the boot initramfs.
- Live ISO: Lorax builds initramfs post-`%post`; theme selection in
  chrooted `%post` is enough.

Installer boot initramfs path is `/boot/x86_64/loader/initrd`, not
Lorax's `/images/pxeboot/initrd.img`.

## early-kms.conf

All three kickstarts and `config.sh` must write:

```bash
add_drivers+=" virtio_gpu hyperv_drm bochs_drm "
```

AZL `plymouthd.defaults` already sets `UseSimpledrmNoLuks=1` for EFI
simpledrm fallback.

## Logo scale

**Status:** Resolved

`assets/plymouth/azurelinux/azurelinux.script` scales the logo to fit
(cap at 30% of screen, never upscale) and re-centers every frame.

## First-boot SELinux relabel vs missing Plymouth

An installed first boot may run fixfiles relabel. If Plymouth is
suppressed (serial console), the user sees raw text and may need a
reboot. Fix Plymouth activation first. Stock `selinux-autorelabel` also
calls `plymouth --quit` even when the splash is healthy. Covered by
`assets/bin/azl-first-boot-prepare` and a systemd drop-in. See
`first-boot-plymouth-relabel.md`.

## Systemd unit names under the logo

**Status:** Fix staged in theme

Observed: logo correct, but the line under the logo cycled through unit
names. Looks like details mode; it is not.

Root cause: theme registered `Plymouth.SetUpdateStatusFunction` and
forwarded every status string into the message text path. systemd feeds
starting unit names through update-status.

Fix: keep `SetMessageFunction` for growroot's
`plymouth display-message`. Remove `SetUpdateStatusFunction` so boots
stay animation-only.

Not caused by missing `rhgb quiet`, serial console, or wrong theme name.

## Other notes

- Pre-Plymouth firmware/GRUB text: see
  `uefi-bdsdxe-text-before-plymouth.md`
- dracut livenet hook ordering: cosmetic
  `get_url_handler: command not found`; patched by
  `scripts/patch-dracut-livenet-hook.sh` before Lorax
- virtio-gpu KMS handoff can briefly flicker to console before GDM
- Short animated phase in fast QEMU is usually boot already done. Open
  tracking: `plymouth-animation-duration.md`
- Screendump after Wayland takeover is black; use VNC capture. See
  `qemu-gnome-interactive-testing.md`

## Verification

```bash
lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'plymouth|azurelinux'
cat /etc/plymouth/plymouthd.conf
journalctl -b | grep -i plymouth
```

## What did not work

- `plymouth-set-default-theme azurelinux --rebuild-initrd` alone against
  the build container kernel
- Leaving `console=ttyS0` on a desktop BLS entry for "debug"
- Relying on `inst.text` removal alone
- Option A for installer (`rd.plymouth=0`): rejected; product wants
  live-style splash on installer boot

## Current state by deliverable

- Live ISO: Lorax initramfs; theme selection in `%post`; verified
- qcow2: `dracut --force --kver` per kernel; no ttyS0 in BLS; verified
- Installer ISO runtime: KIWI initrd path; console=tty0 only; verified
- Installed system: post-bootloader has no ttyS0; gfxterm; verified

## Related

- `uefi-bdsdxe-text-before-plymouth.md`
- `plymouth-animation-duration.md`
- `first-boot-plymouth-relabel.md`
- `deliverable-polish-validation.md`
