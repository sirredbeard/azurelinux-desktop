# Desktop kmod packages

**Status:** current. Source of truth is `scripts/build-desktop-kmods.sh` and the
family matrix in `publish-desktop-kmods.yml`.

Images install `azurelinux-desktop-policy`. That meta package requires the
exact `kernel-core` EVR and every sibling kmod at the same version, so a
kernel-only update cannot leave desktop hardware half-working.

Modules are built from the matching Azure Linux / CBL-Mariner kernel tarball
against stock `kernel-devel`. Nothing from the linux-surface fork. They land
under `/usr/lib/modules/$KVER/extra/azurelinux-desktop/`.

## Legacy names

* `azurelinux-desktop-usb-storage-kmod` → `azurelinux-desktop-storage-kmod`
* `azurelinux-desktop-iwlwifi-kmod` → `azurelinux-desktop-intel-kmod`

New packages Provide/Obsolete the old names so upgrades work.

## azurelinux-desktop-policy

No modules. Couples kernel + every sibling kmod for one EVR.

## azurelinux-desktop-usbhid-kmod

Stock Azure Linux x86_64 leaves USB HID off.

* Modules: `usbhid.ko`
* Drop-ins: dracut `add_drivers+= usbhid`, modules-load for early input

## azurelinux-desktop-psmouse-kmod

`CONFIG_INPUT_MOUSE` is off. GNOME Boxes and libvirt PS/2 mice need this.

* Modules: `psmouse.ko` (base, Synaptics, FocalTech, TrackPoint, ALPS, SMBus,
  Logitech PS/2++ pieces when the tree has them)
* Drop-ins: dracut + modules-load for `psmouse`
* Stock companions: `i8042`, `libps2`, `atkbd`

## azurelinux-desktop-storage-kmod

`CONFIG_USB_STORAGE` is off. Live and installer USB root fail without it.

* Modules: `usb-storage.ko`, `uas.ko`
* Drop-ins: dracut `add_drivers+= usb-storage uas` (current and legacy conf names)
* Provides/Obsoletes the old usb-storage package name
* Not rebuilt here: NVMe, ext4, XFS, Btrfs, device-mapper (stock)

## azurelinux-desktop-intel-kmod

WLAN / iwlwifi opmodes are off.

* Modules: `iwlwifi.ko`, `iwlmvm.ko`, `iwldvm.ko`, `iwlmld.ko`
* Provides/Obsoletes the old iwlwifi package name
* Firmware: Azure `iwlwifi-*-firmware` packages, not this RPM
* GPU (`i915`/`xe`), MEI, e1000e, and friends stay stock; HDA is sound-kmod;
  `btintel` is bluetooth-kmod

## azurelinux-desktop-sound-kmod

`CONFIG_SOUND` is off.

* Modules: ALSA core, Intel DSP glue, HDA (`snd-hda-intel` and codecs),
  USB audio. Exact `.ko` list follows the kernel EVR.
* Drop-ins: modules-load (does not force `snd-hda-intel`; udev binds),
  modprobe override so Fedora `snd-seq` hooks do not fight us
* No SOF / ASoC graph in this package
* Userspace: `intel-audio-firmware`, alsa-ucm, PipeWire

## azurelinux-desktop-bluetooth-kmod

`CONFIG_BT` is off.

* net/bluetooth: `bluetooth.ko`, `rfcomm.ko`, `bnep.ko`, `hidp.ko`
* drivers/bluetooth: `btusb.ko`, `btintel.ko`, `btrtl.ko`, `btbcm.ko`, `btmtk.ko`
* Drop-ins: modules-load (no force `btusb`), modprobe softdep
  `btusb pre: thinkpad_acpi` so platform rfkill unblocks first
* Userspace: BlueZ, Intel BT firmware

## azurelinux-desktop-uvc-kmod

USB video class is off.

* Modules: `uvc.ko`, `uvcvideo.ko`

## azurelinux-desktop-thinkpad-kmod

ThinkPad ACPI and related bits are off. Also ships USB WWAN/tether helpers
when the tree has them.

* Platform: `thinkpad_acpi.ko`, `battery.ko`, `drm_privacy_screen.ko`
* HID: `hid-lenovo.ko` when present
* USB net when present: `usbnet`, `cdc_ether`, `cdc_ncm`, `cdc_mbim`,
  `qmi_wwan`, `cdc-wdm`
* modules-load does not force `thinkpad_acpi` on non-ThinkPad hardware
  (it would `-ENODEV`)
* TrackPoint PS/2 protocol is psmouse-kmod, not this package

## azurelinux-desktop-typec-kmod

`CONFIG_TYPEC` is off.

* Modules: `typec.ko`, `typec_ucsi.ko`, `ucsi_acpi.ko`
* USB4 / thunderbolt stays stock (`CONFIG_USB4=m`)

## azurelinux-desktop-surface-kmod

Surface platform, serdev, Microsoft HID, multitouch. Upstream kernel tree
only, not the linux-surface fork.

* Transport: `serdev.ko`
* SSAM core: `surface_aggregator.ko`
* Platform clients when present: aggregator hub/registry/tabletsw, dtx, gpe,
  hotplug, platform_profile, acpi_notify, surfacepro3_button, surface3_power,
  surface3-wmi
* HID: `hid-microsoft`, `hid-multitouch`; optional surface-hid bits when the
  tree has `drivers/hid/surface-hid/`
* Build stages a few headers from the kernel tarball that stock kernel-devel
  does not ship. See `surface-hid-oot-build.md`.
* Pair with intel / sound / bluetooth kmods on Intel Surfaces

## azurelinux-desktop-sensors-kmod

Conf only. No out-of-tree modules.

* `modules-load.d` seeds: `coretemp`, `i2c-i801`, `i2c-smbus`,
  `x86_pkg_temp_thermal`
* Those are already stock `=m` / built-in; missing names are ignored

## azurelinux-desktop-performance-kmod

Conf-only. See `desktop-performance-policy.md`.

* modules-load: `zram`, `tcp_bbr`, `sch_fq`
* sysctl: fq + bbr, swappiness=20, vfs_cache_pressure=75, mild TCP caps
* `/etc/systemd/zram-generator.conf` (needs `zram-generator` package on image)
* Stock already has MGLRU, PSI, zram, BBR modules, THP madvise. Cannot OOT
  preempt or THP policy.

## CI families

```
usbhid, psmouse, storage, intel, sound, bluetooth, uvc,
thinkpad, typec, surface, sensors, performance
```

Aliases: `usb-storage` → `storage`, `iwlwifi` → `intel`.

## Related

* `out-of-tree-usb-kmods-pages.md` - Pages repo, signing, policy
* `kmod-family-expansion-stock-vs-oot.md` - stock vs OOT gaps
* `intel-surface-kmod-families.md` - intel rename and surface design
* `surface-hid-oot-build.md` - HID headers / BTF
* `desktop-kmod-waves-1-5.md` - earlier wave history
