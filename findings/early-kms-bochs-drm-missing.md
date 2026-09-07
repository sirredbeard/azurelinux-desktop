# dracut-install: Failed to find module 'bochs_drm' on every kmod install

Symptom: installing or reinstalling any `azurelinux-desktop-*-kmod`
package prints a `dracut[E]: FAILED` line from it's `%post` scriptlet.
Same thing on every kernel update, since the same `early-kms.conf`
drives every initramfs rebuild. Issue 36.

## Symptom

Force reinstalling all 28 kmods on 6.18.31-1.16.azl4.x86_64:

```
dracut-install: Failed to find module 'bochs_drm'
dracut[E]: FAILED:  /usr/lib/dracut/dracut-install -D /var/tmp/dracut.drgUZ1a/initramfs --kerneldir /usr/lib/modules/6.18.31-1.16.azl4.x86_64 -m psmouse usb_storage uas usbhid usb_storage uas virtio_gpu hyperv_drm bochs_drm
```

28 packages, 28 errors.

## Root cause

`assets/dracut.conf.d/early-kms.conf` asked for `bochs_drm`. Azure
Linux does not build it on x86_64:

```
$ grep -E 'DRM_BOCHS|DRM_VIRTIO_GPU|DRM_HYPERV|DRM_QXL|DRM_VMWGFX' /boot/config-6.18.31-1.16.azl4.x86_64
CONFIG_DRM_VMWGFX=m
CONFIG_DRM_QXL=m
CONFIG_DRM_VIRTIO_GPU=m
# CONFIG_DRM_BOCHS is not set
CONFIG_DRM_HYPERV=m
```

`microsoft/azurelinux` `specs/k/kernel/6.18-x86_64-azl.config` matches.
The aarch64 config has `CONFIG_DRM_BOCHS=m`, which is probably where the
line came from. We only ship x86_64.

The name was wrong separately. Upstream builds `bochs.ko`, not
`bochs_drm.ko`. `drivers/gpu/drm/tiny/Makefile` has
`obj-$(CONFIG_DRM_BOCHS) += bochs.o`. So `bochs_drm` would not resolve
even on a kernel that did build it. Neither name exists here:

```
$ modinfo bochs
modinfo: ERROR: Module bochs not found.
$ modinfo bochs_drm
modinfo: ERROR: Module bochs_drm not found.
```

## How bad it was

Not fatal. dracut prints the error, returns 0, and installs everything
else on the line. Checked rather than assumed, by normalizing the
compressed module names in the built image:

```
psmouse      1
usb-storage  1
uas          1
usbhid       1
virtio-gpu   1
hyperv-drm   1
bochs        0
```

Worth knowing for the next missing-module report: `add_drivers` is
best effort. A module that is missing is a loud error and a working
initramfs. `force_drivers` also does not hard fail the build, it adds
a `modprobe` at boot instead. Neither one aborts.

`scripts/restage-azl-nested-boot.sh` had a `sed -i 's/bochs_drm//g'`
workaround that patched one script's output. The asset was never fixed,
so the live ISO, installer, and disk images all still shipped it.

## Fix

Dropped `bochs_drm`. Added `qxl` and `vmwgfx`, both already `=m` in the
stock AZL kernel:

```
add_drivers+=" virtio_gpu hyperv_drm qxl vmwgfx "
```

`qxl` binds `1b36:0100`, QEMU `-vga qxl`, which is the non-virtio QEMU
case `bochs_drm` was aiming at. `vmwgfx` binds `15ad:0405` and
`15ad:0406`, VMware SVGA II, and VirtualBox VMSVGA emulates the same
device, so one module covers the VMDK and the VDI. Confirmed from the
module aliases:

```
$ modinfo -F alias qxl
pci:v00001B36d00000100sv*sd*bc03sc80i*
pci:v00001B36d00000100sv*sd*bc03sc00i*
$ modinfo -F alias vmwgfx
pci:v000015ADd00000406sv*sd*bc*sc*i*
pci:v000015ADd00000405sv*sd*bc*sc*i*
```

Before this, `virtio_gpu` covered qcow2 and `hyperv_drm` covered VHDX.
The other two published disk formats got nothing.

Changed in `assets/dracut.conf.d/early-kms.conf` and `kiwi/config.sh`,
which writes it's own copy for the installer environment. The live and
installer kickstarts both `install -m 0644` the asset, so they pick it
up for free. Validation scripts updated, and `validate-installer-iso.sh`
now fails if `bochs` comes back.

## Also verified in the same pass

Force reinstalled all 28 kmods at 1.16 from the Pages repo and checked
them:

- All signed, RSA/SHA512 key `8da5774c35da9bf9`, which matches the
  trusted `gpg-pubkey` for `Hayden Barnes (sirredbeard)`. Repo shows
  `Verify packages: true`.
- 119 modules, 0 vermagic mismatches, `depmod -e -E Module.symvers`
  clean with no unresolved symbols.
- 114 of 119 load. The 5 that do not are `asus-nb-wmi`, `dell-laptop`,
  `samsung-laptop`, `surface3-wmi`, `surface_gpe`, all returning
  `No such device` on a Lenovo 20JTS0D500. Correct behavior, not a bug.
- `performance` and `sensors` ship zero `.ko` files on purpose, they are
  config only (`modules-load.d`, `sysctl.d`, `zram-generator.conf`).
- Nothing in `/etc/modules-load.d` names a module that does not exist.
  `bochs_drm` in dracut was the only offender of that kind.

The two September 6 fixes both hold up on real hardware. `snd-hda-core.ko`
exports `snd_hdac_i915_init`, and the journal shows the change across the
kmod upgrade on the same boot day:

```
Sep 06 16:55:05 kernel: snd_hda_codec_intelhdmi hdaudioC0D2: No i915 binding for Intel HDMI/DP codec
Sep 06 16:55:05 kernel: hdaudio hdaudioC0D2: Unable to configure, disabling
```

After, `wpctl status` lists `Built-in Audio Digital Stereo (HDMI)` and
the codec configures without complaint. `xpad.ko` has `xpad_play_effect`
and `xpad_led_set`, `hid-sony.ko` has `sony_play_effect`,
`hid-playstation.ko` has `dualsense_play_effect`, `dualshock4_play_effect`,
and `ps_led_register`, so rumble and the LED ring are compiled in now.

Status: fixed, pending a live ISO and installer build to confirm the
asset lands.
