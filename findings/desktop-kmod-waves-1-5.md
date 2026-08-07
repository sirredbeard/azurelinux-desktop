# Desktop kmod waves 1-5 (sound, BT, UVC, thinkpad, typec)

**Status:** implemented; Pages publish path live

## Goal

Close the host-vs-AZL hardware gap on Intel-class x86_64 without forking the Azure Linux kernel. Stock `kernel` / `kernel-devel` stay upstream. Supplemental modules ship as sibling RPMs from the matching CBL-Mariner source tarball, locked by `azurelinux-desktop-policy`.

Companion docs:

* `intel-laptop-host-vs-azl-drivers.md`
* `plan-close-desktop-driver-gaps.md`
* `out-of-tree-usb-kmods-pages.md`
* `bluetooth-hci-timeout-thinkpad.md`
* `systemd-modules-load-snd-hda.md`

## Packages (generic names)

* `azurelinux-desktop-sound-kmod` - Intel HDA, common codecs, USB audio
* `azurelinux-desktop-bluetooth-kmod` - BT core and USB controllers (Intel and common helpers)
* `azurelinux-desktop-uvc-kmod` - USB Video Class cameras
* `azurelinux-desktop-thinkpad-kmod` - Lenovo platform ACPI and related bits
* `azurelinux-desktop-typec-kmod` - Type-C class and UCSI ACPI

Plus existing usbhid, psmouse, storage (was usb-storage), intel (was iwlwifi), surface, sensors, performance, and policy. See `intel-surface-kmod-families.md` and `kmod-family-expansion-stock-vs-oot.md`.

## Userspace and firmware (Azure first)

Pulled into live kickstart, disk kickstart, and installer KIWI:

* `intel-audio-firmware` - SST/AVS blobs for Intel HDA paths
* `alsa-ucm` - UCM profiles once ALSA loads
* `NetworkManager-bluetooth` - NM BT plugin
* `bluez` - already present
* `iwlwifi-*-firmware` - already present

FEDORA_EXCLUDES prefer the AZL builds of `alsa-ucm`, `NetworkManager-bluetooth`, and `intel-audio-firmware` over Fedora twins.

## Builder notes (`scripts/build-desktop-kmods.sh`)

Sound:

* Copy `sound/`, force CONFIG via force header, narrow top Makefile to `core/ hda/ usb/` (no full ASoC/SOF first pass).
* With `CONFIG_SND_DYNAMIC_MINORS`, `include/sound/core.h` needs integer `CONFIG_SND_MAX_CARDS` (default 32) and `CONFIG_SND_MAJOR` (116). Define them in the force header and on the make line. Set HDA prealloc and power-save defaults as integers too.
* HDMI needs `CONFIG_SND_PCM_ELD` so `pcm_drm_eld.o` exports ELD helpers. Realtek needs `CONFIG_SND_HDA_GENERIC_LEDS` and `CONFIG_SND_HDA_SCODEC_COMPONENT=m`. Keep upstream `hda/codecs/Makefile` (do not strip `side-codecs/`). Leave CS35/TAS amp side-codecs off.
* Do not force-load `snd-hda-intel` via modules-load. udev binds HDA. Ship modprobe override so Fedora `dist-alsa.conf` does not require missing `snd-seq`. See `systemd-modules-load-snd-hda.md`.

Bluetooth:

* Build `net/bluetooth`, then `drivers/bluetooth` with `KBUILD_EXTRA_SYMBOLS`.
* Pass the same `CONFIG_BT_*` set into both stages, including **`CONFIG_BT_LEDS`**. Mismatch shifts `struct hci_dev` and Oopses in `sk_skb_reason_drop`. See `bluetooth-hci-timeout-thinkpad.md`.
* `CONFIG_BT_RFCOMM_TTY` needs `-DCONFIG_BT_RFCOMM_TTY=1` on `subdir-ccflags-y` so `rfcomm/tty.c` sees it.
* Helper headers use `IS_ENABLED(CONFIG_BT_BCM)` style flags. Define `CONFIG_BT_BCM_MODULE` and Intel/RTL/MTK siblings, not only HCIBTUSB knobs.
* Do not force-load `btusb`. modprobe.d: `softdep btusb pre: thinkpad_acpi`, `options btusb reset=1`, `enable_autosuspend=0`. Recover units ship in the bluetooth RPM.

UVC:

* `drivers/media/usb/uvc` with `CONFIG_USB_VIDEO_CLASS=m`.
* Ship `uvc.ko` from common UVC when the tree has it, next to `uvcvideo.ko`.

thinkpad_acpi:

* Platform file plus flattened helpers. May ship battery/privacy-screen helpers and `hid-lenovo` when sources exist.
* Prefer not linking ALSA console mixer when parallel sound is not required at link time.
* modules-load conf is comment-only or careful; do not race BT.

typec:

* class + `typec_ucsi` (DP altmode object) + `ucsi_acpi`.
* Link UCSI debugfs/trace objects when the stock kernel has those configs.

Policy Requires exact EVR of every sibling present. Local rebuilds may set `KERNEL_SRC_TARBALL` to a cached archive.

## Publish and image wiring

* `publish-desktop-kmods.yml` detect requires the full current family set in `manifest.txt`.
* `generate-kmod-repo-index.sh` lists the full set.
* Live + disk kickstarts and KIWI install policy (pulls siblings) and the userspace hooks above.
* Canary resolves and checks module paths / package names.

## Status

Waves 1-5 are in the builder and image inputs. Bare-metal scorecard on an Intel-class laptop is the lasting proof (filesystem plus runtime). WWAN as a dedicated family stayed optional; some USB net helpers may ride on thinkpad when sources exist.

## CI notes

See `out-of-tree-usb-kmods-pages.md` for detect, prepare, family matrix, package, publish, `republish`, and `prune_old`. Matrix `fail-fast` is false so one family failure does not erase useful siblings. Policy is rebuilt against whatever siblings exist after merge with prior Pages RPMs for that kernel.
