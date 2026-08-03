# systemd-modules-load fails on snd-hda-intel

**Status:** Fix staged and reboot-proven on nested install (2026-08-03).
Needs installer/live release rebuild for image parity.

## Observed failure

First installed boot (and the post-resize reboot) showed console text:

```
[FAILED] Failed to start systemd-modules-load.service - Load Kernel Modules.
```

Plymouth dropped to a text console long enough for SELinux autorelabel
messages to paint over the splash path. Screendumps:
`~/azl-work/boot-watch/t002.png`, `t007.png`.

## Root cause

`azurelinux-desktop-sound-kmod` wrote:

```
/etc/modules-load.d/azurelinux-desktop-sound.conf
snd-hda-intel
```

Journal (nested install, boots -1 and 0):

```
Error running install command '/sbin/modprobe --ignore-install snd-pcm && /sbin/modprobe snd-seq' for module snd_pcm: retcode 1
Failed to insert module 'snd_hda_intel': Invalid argument
modprobe: FATAL: Module snd-seq not found in directory /lib/modules/6.18.31-1.9.azl4.x86_64
```

Two stacked problems:

1. **Force-load at boot.** `snd-hda-intel` is not always safe to insert
   early. On QEMU's ich9 HDA without a usable codec it returns
   `Invalid argument` / "Cannot probe codecs, giving up". That alone is
   enough for `systemd-modules-load.service` to fail.
2. **Fedora `dist-alsa.conf` install hook.** Fedora ships
   `/usr/lib/modprobe.d/dist-alsa.conf` with
   `install snd-pcm ... && modprobe snd-seq`. The Azure Linux kernel
   tree used here does **not** ship `snd-seq`. Loading any path that
   pulls `snd-pcm` through that install rule fails the hook.

This is the same class of bug as force-loading `btusb` /
`thinkpad_acpi` via modules-load (see
`bluetooth-hci-timeout-thinkpad.md` and the thinkpad modules-load
comment in `build-desktop-kmods.sh`).

SELinux autorelabel text on first boot is expected and separate; it is
louder when modules-load has already forced a console failure banner.

## Fix

In `scripts/build-desktop-kmods.sh` for `azurelinux-desktop-sound-kmod`:

- modules-load conf becomes a comment only (udev binds HDA when
  hardware appears).
- Add `/etc/modprobe.d/azurelinux-desktop-alsa.conf` that overrides the
  Fedora install rule:

  ```
  install snd-pcm /sbin/modprobe --ignore-install snd-pcm $CMDLINE_OPTS
  ```

Also:

- `scripts/test-canary-container.sh` asserts no force-loaded
  `snd-hda-intel` and the alsa override file.
- `scripts/restage-azl-nested-boot.sh` neutralizes a stale sound
  modules-load file on nested restage (same as thinkpad).

## Verification

- Nested FS before fix: `snd-hda-intel` alone in sound modules-load;
  journal failure on every boot. Initrd also embedded the 14-byte
  force-load conf.
- First in-place conf-only patch was not enough: **initrd** still loaded
  `snd-hda-intel`. After dual-mounting the live guest root from the host
  (paused QEMU), ext4 corruption also trashed
  `azurelinux-desktop-sound.conf` into ELF garbage and left emergency
  mode on the next reboot.
- Repair: `fsck -fy` root, rewrite confs, **`dracut -f`**, then reboot.
- Reboot `e0deb9c2…` (12:46): modules-load **Finished** (only `i2c_dev` +
  `msr`); Plymouth started; GDM at ~12:46:55. No FAILED banner.
- Real ThinkPad: HDA should still bind via udev; check
  `lsmod | grep snd_hda_intel` after login.

## Ops lesson

Never kpartx/mount the nested root while the guest still has it open,
even if QEMU is paused. Pause is not a filesystem freeze. Prefer SSH
into the guest, or full poweroff, before host-side mounts.

## References

- Journal excerpts: `~/azl-work/boot-investigate/`
- Boot screendumps: `~/azl-work/boot-watch/`
- Related: `bluetooth-hci-timeout-thinkpad.md`, `plymouth-boot-animation.md`
