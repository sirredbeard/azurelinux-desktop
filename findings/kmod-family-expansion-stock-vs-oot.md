# Kmod family expansion: stock AZL vs OOT packages

**Status:** active map for what we build and what we leave alone

Host probe reference: ThinkPad-class Intel laptop on Azure Linux 4.0. Builder only packages true gaps. Options already `=y` or `=m` in stock are documented and not rebuilt.

## Package renames

* Old `azurelinux-desktop-iwlwifi-kmod` -> `azurelinux-desktop-intel-kmod` (Provides/Obsoletes legacy)
* Old `azurelinux-desktop-usb-storage-kmod` -> `azurelinux-desktop-storage-kmod` (same modules; dual dracut drop-ins for name transition)

## Families this project ships

* `azurelinux-desktop-usbhid-kmod` - USB HID transport
* `azurelinux-desktop-psmouse-kmod` - PS/2 mouse protocols (ALPS / SMBus / logips2pp where present)
* `azurelinux-desktop-storage-kmod` - usb-storage + uas
* `azurelinux-desktop-intel-kmod` - iwlwifi opmodes (WLAN still off in stock)
* `azurelinux-desktop-sound-kmod` - ALSA / HDA / USB audio
* `azurelinux-desktop-bluetooth-kmod` - BT core + USB controllers
* `azurelinux-desktop-uvc-kmod` - UVC / media USB
* `azurelinux-desktop-thinkpad-kmod` - thinkpad_acpi plus battery/privacy helpers, hid-lenovo, and USB WWAN helpers when sources exist
* `azurelinux-desktop-typec-kmod` - TYPEC / UCSI ACPI
* `azurelinux-desktop-surface-kmod` - serdev + SSAM + platform clients + hid-microsoft/multitouch (+ surface-hid when present)
* `azurelinux-desktop-sensors-kmod` - conf-only modules-load for stock hwmon/i2c
* `azurelinux-desktop-performance-kmod` - conf-only modules-load + sysctl + zram-generator conf (see `desktop-performance-policy.md`)
* `azurelinux-desktop-policy` - Requires exact kernel EVR and every sibling in the set

## Stock already present (do not OOT-rebuild)

* NVMe: `CONFIG_BLK_DEV_NVME=y`, `CONFIG_NVME_CORE=y`
* Filesystems: EXT4 built-in; XFS and Btrfs as stock modules
* Device-mapper: DM built-in; dm-crypt and dm-integrity as stock modules
* Intel GPU: `DRM_I915=m`, `DRM_XE=m`
* Intel platform: pstate, idle, MEI, RAPL, PMC, `E1000E=m`, AES-NI crypto module
* USB4 / Thunderbolt: `CONFIG_USB4=m` (`thunderbolt.ko`)
* Sensors core: HWMON, THERMAL, `I2C_I801=m`, `SENSORS_CORETEMP=m`
* Perf knobs already in tree: `ZRAM=m`, `ZSWAP=y`, `TCP_CONG_BBR=m`, transparent hugepages on
* cfg80211 stack: `CFG80211=m`, `MAC80211=m` (WLAN opmodes still off)

Built-in or "is not set" items that cannot be fixed as OOT modules alone: full PREEMPT policy, zswap already `=y`, THP already `=y`.

## True OOT gaps (this project builds)

* USB_STORAGE / UAS -> storage-kmod
* WLAN / iwlwifi opmodes -> intel-kmod
* SOUND / HDA stack -> sound-kmod
* BT stack -> bluetooth-kmod
* UVC / media USB -> uvc-kmod
* TYPEC / UCSI ACPI -> typec-kmod
* THINKPAD_ACPI + related -> thinkpad-kmod
* INPUT_MOUSE / psmouse protocols -> psmouse-kmod
* usbhid -> usbhid-kmod
* SURFACE_* + SERIAL_DEV_BUS + HID MS/multitouch -> surface-kmod

## CI matrix families

`usbhid`, `psmouse`, `storage`, `intel`, `sound`, `bluetooth`, `uvc`, `thinkpad`, `typec`, `surface`, `sensors`, `performance`.

Legacy aliases accepted: `iwlwifi`->`intel`, `usb-storage`->`storage`.

## Product install path

Live, installer, and canary install **`azurelinux-desktop-policy` only**. Policy Requires every sibling kmod at the exact kernel EVR.

Pipeline detail: `out-of-tree-usb-kmods-pages.md`.
