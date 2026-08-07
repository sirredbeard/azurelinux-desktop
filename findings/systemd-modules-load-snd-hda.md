# systemd-modules-load fails on snd-hda-intel

**Status:** Fix in sound-kmod builder and canary checks. udev binds HDA; modules-load must not force snd-hda-intel.

## Observed failure

Installed boot showed:

```
[FAILED] Failed to start systemd-modules-load.service - Load Kernel Modules.
```

Plymouth dropped to a text console long enough for SELinux autorelabel messages to paint over the splash path.

## Root cause

`azurelinux-desktop-sound-kmod` used to write:

```
/etc/modules-load.d/azurelinux-desktop-sound.conf
snd-hda-intel
```

Journal pattern:

```
Error running install command '... modprobe snd-seq' for module snd_pcm: retcode 1
Failed to insert module 'snd_hda_intel': Invalid argument
modprobe: FATAL: Module snd-seq not found in directory /lib/modules/...
```

Two stacked problems:

1. **Force-load at boot.** `snd-hda-intel` is not always safe to insert early. On QEMU ich9 HDA without a usable codec it returns `Invalid argument` / "Cannot probe codecs, giving up". That alone fails `systemd-modules-load.service`.
2. **Fedora `dist-alsa.conf` install hook.** Fedora ships `/usr/lib/modprobe.d/dist-alsa.conf` with `install snd-pcm ... && modprobe snd-seq`. The Azure Linux kernel tree used here does not ship `snd-seq`. Loading any path that pulls `snd-pcm` through that install rule fails the hook.

Same class of bug as force-loading `btusb` via modules-load (see `bluetooth-hci-timeout-thinkpad.md` and thinkpad comments in `build-desktop-kmods.sh`).

SELinux autorelabel text on first boot is expected and separate. It is louder when modules-load has already forced a console failure banner.

## Fix

In `scripts/build-desktop-kmods.sh` for `azurelinux-desktop-sound-kmod`:

* modules-load conf is comment only (udev binds HDA when hardware appears).
* Add `/etc/modprobe.d/azurelinux-desktop-alsa.conf` that overrides the Fedora install rule:

```
install snd-pcm /sbin/modprobe --ignore-install snd-pcm $CMDLINE_OPTS
```

Also:

* `scripts/test-canary-container.sh` asserts no force-loaded `snd-hda-intel` and the alsa override file.
* Nested restage helpers neutralize a stale sound modules-load file when rewriting nested boots.

## Verification

* Bad: `snd-hda-intel` alone in sound modules-load; journal failure every boot. Initrd can embed the force-load conf if it was present at dracut time.
* After fix: modules-load finishes with only harmless stock entries (for example i2c_dev, msr); no FAILED banner; Plymouth/GDM path clean.
* Real ThinkPad: HDA still binds via udev after login (`lsmod | grep snd_hda_intel`).

If an old initrd still force-loads the module, rewrite confs on the rootfs and run `dracut -f`, then reboot.

## Ops lesson

Never kpartx/mount the nested root while the guest still has it open, even if QEMU is paused. Pause is not a filesystem freeze. Prefer SSH into the guest, or full poweroff, before host-side mounts.

## Related

* `bluetooth-hci-timeout-thinkpad.md` - force-load race class
* `desktop-kmod-waves-1-5.md` - sound builder notes
* `plymouth-boot-animation.md` - splash vs console failure noise
* `out-of-tree-usb-kmods-pages.md` - kmod pipeline
