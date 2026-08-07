# Kmod family expansion: stock AZL vs OOT packages

Host probe: ThinkPad T470s, Azure Linux 4.0, kernel `6.18.31-1.12.azl4`
(`/boot/config-$(uname -r)`). Builder only packages true gaps; options
already `=y`/`=m` in stock are documented and **not** rebuilt.

## Package renames

| Old | New | Notes |
|-----|-----|-------|
| `azurelinux-desktop-iwlwifi-kmod` | `azurelinux-desktop-intel-kmod` | Provides/Obsoletes legacy |
| `azurelinux-desktop-usb-storage-kmod` | `azurelinux-desktop-storage-kmod` | Same modules; dual dracut drop-ins |

## New / expanded families

| Package | Role |
|---------|------|
| `azurelinux-desktop-surface-kmod` | serdev + SSAM + platform clients + hid-microsoft/multitouch (+ surface-hid when present) |
| `azurelinux-desktop-sensors-kmod` | **conf-only** modules-load for stock hwmon/i2c |
| `azurelinux-desktop-performance-kmod` | **conf-only** modules-load (zram, tcp_bbr) + sysctl |

ThinkPad package now also ships `hid-lenovo` and USB WWAN (`usbnet`,
`cdc_*`, `qmi_wwan`, `cdc-wdm` when sources exist). psmouse gains ALPS /
SMBus / logips2pp protocols where present in the tarball.

## Stock already present (do not OOT-rebuild)

| Area | Host config |
|------|-------------|
| NVMe | `CONFIG_BLK_DEV_NVME=y`, `CONFIG_NVME_CORE=y` |
| Filesystems | `EXT4_FS=y`, `XFS_FS=m`, `BTRFS_FS=m` |
| Device-mapper | `BLK_DEV_DM=y`, `DM_CRYPT=m`, `DM_INTEGRITY=m` |
| Intel GPU | `DRM_I915=m`, `DRM_XE=m` |
| Intel platform | `X86_INTEL_PSTATE=y`, `INTEL_IDLE=y`, MEI, RAPL, PMC, `E1000E=m`, `CRYPTO_AES_NI_INTEL=m` |
| USB4 / TB | `CONFIG_USB4=m` (`thunderbolt.ko`) |
| Sensors core | `HWMON=y`, `THERMAL=y`, `I2C_I801=m`, `SENSORS_CORETEMP=m` |
| Perf knobs | `ZRAM=m`, `ZSWAP=y`, `TCP_CONG_BBR=m`, `TRANSPARENT_HUGEPAGE=y` |
| cfg80211 stack | `CFG80211=m`, `MAC80211=m` (WLAN opmodes still off) |

Built-in or `is not set` items that **cannot** be fixed as OOT modules alone:
`PREEMPT` policy, full `ZSWAP` already `=y`, THP already `=y`.

## True OOT gaps (this project builds)

| Gap | Package |
|-----|---------|
| `USB_STORAGE` / UAS | storage-kmod |
| `WLAN` / iwlwifi opmodes | intel-kmod |
| `SOUND` / HDA stack | sound-kmod |
| `BT` stack | bluetooth-kmod |
| UVC / media USB | uvc-kmod |
| `TYPEC` / UCSI ACPI | typec-kmod |
| `THINKPAD_ACPI` + battery/privacy + hid-lenovo + USB net | thinkpad-kmod |
| `INPUT_MOUSE` / psmouse protocols | psmouse-kmod |
| `usbhid` | usbhid-kmod |
| `SURFACE_*` + `SERIAL_DEV_BUS` + HID MS/multitouch | surface-kmod |

## CI matrix families

`usbhid`, `psmouse`, `storage`, `intel`, `sound`, `bluetooth`, `uvc`,
`thinkpad`, `typec`, `surface`, `sensors`, `performance`.

Legacy aliases accepted: `iwlwifi`→`intel`, `usb-storage`→`storage`.

## Product install path

Live, installer, and canary install **`azurelinux-desktop-policy` only**.
Policy Requires every sibling kmod at the exact kernel EVR.
