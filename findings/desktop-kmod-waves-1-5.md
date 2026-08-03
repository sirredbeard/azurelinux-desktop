# Desktop kmod waves 1–5 (sound, BT, UVC, thinkpad, typec)

**Status:** implemented; Pages publish path live

## Goal

Close the host-vs-AZL hardware gap on Intel-class x86_64 (probed on a
Intel-class laptop) without forking the Azure Linux kernel. Stock
`kernel`/`kernel-devel` stay upstream. Supplemental modules ship as
sibling RPMs from the matching CBL-Mariner source tarball, locked by
`azurelinux-desktop-policy`.

Companion docs:

* [`intel-laptop-host-vs-azl-drivers.md`](intel-laptop-host-vs-azl-drivers.md)
* [`plan-close-desktop-driver-gaps.md`](plan-close-desktop-driver-gaps.md)
* [`out-of-tree-usb-kmods-pages.md`](out-of-tree-usb-kmods-pages.md)

## Packages (generic names, not Intel laptop-specific)

| RPM | Why generic |
| --- | --- |
| `azurelinux-desktop-sound-kmod` | Intel HDA + common codecs + USB audio |
| `azurelinux-desktop-bluetooth-kmod` | BT core + USB controllers (Intel/RTL/BCM/MTK) |
| `azurelinux-desktop-uvc-kmod` | USB Video Class cameras |
| `azurelinux-desktop-thinkpad-kmod` | Lenovo platform ACPI (ThinkPad family) |
| `azurelinux-desktop-typec-kmod` | Type-C class + UCSI ACPI (docks) |

Plus existing usbhid, usb-storage, iwlwifi, and policy.

## Userspace / firmware (Azure first)

Pulled into live kickstart, disk kickstart, and installer KIWI:

* `intel-audio-firmware` — SST/AVS blobs for Intel HDA paths
* `alsa-ucm` — UCM profiles once ALSA loads
* `NetworkManager-bluetooth` — NM BT plugin / tethering hooks
* `bluez` — already present
* `iwlwifi-*-firmware` — already present

FEDORA_EXCLUDES prefer the AZL builds of `alsa-ucm`,
`NetworkManager-bluetooth`, and `intel-audio-firmware` over Fedora
twins.

## Builder notes (`scripts/build-desktop-kmods.sh`)

* Sound: copy `sound/`, force CONFIG via `force-snd.h`, narrow top
  Makefile to `core/ hda/ usb/` (no full ASoC/SOF first pass).
* **Sound pitfall 1:** with `CONFIG_SND_DYNAMIC_MINORS`,
  `include/sound/core.h` sets `SNDRV_CARDS` to `CONFIG_SND_MAX_CARDS`.
  That symbol is an **int** Kconfig (default 32), not a boolean. First
  full build failed in `core/init.o` with `CONFIG_SND_MAX_CARDS`
  undeclared / static_assert not integer. Fix: `#define
  CONFIG_SND_MAX_CARDS 32` (and `CONFIG_SND_MAJOR 116`) in the force
  header and pass the same on the make command line. Also set
  `CONFIG_SND_HDA_PREALLOC_SIZE` / `CONFIG_SND_HDA_POWER_SAVE_DEFAULT`
  as integers.
* **Sound pitfall 2 (modpost):** HDMI needs `CONFIG_SND_PCM_ELD` so
  `core/pcm_drm_eld.o` exports `snd_parse_eld` / `snd_show_eld`. Realtek
  needs `CONFIG_SND_HDA_GENERIC_LEDS` (mute LED helpers in `generic.c`)
  and `CONFIG_SND_HDA_SCODEC_COMPONENT=m` (`side-codecs/hda_component.c`)
  because alc269 calls the component manager. Keep upstream
  `hda/codecs/Makefile` (do not strip `side-codecs/`). Leave CS35/TAS
  amp side-codecs CONFIG off.
* Bluetooth: build `net/bluetooth`, then `drivers/bluetooth` with
  `KBUILD_EXTRA_SYMBOLS` from the net build.
* **Bluetooth pitfall:** make `CONFIG_BT_RFCOMM_TTY=y` alone is not
  enough. `rfcomm.h` also needs `-DCONFIG_BT_RFCOMM_TTY=1`, and it must
  be `subdir-ccflags-y` (not plain `ccflags-y`) so `rfcomm/tty.c` under
  the `rfcomm/` subdir sees it. Plain `ccflags-y` only covers the top
  `net/bluetooth` objects; without the subdir flag the header injects
  static inline stubs and tty.c redefines `rfcomm_init_ttys` /
  `rfcomm_cleanup_ttys`.
* **Bluetooth drivers:** helper headers (`btbcm.h`, etc.) use
  `IS_ENABLED(CONFIG_BT_BCM)` — define `CONFIG_BT_BCM_MODULE` (and
  Intel/RTL/MTK siblings), not only `CONFIG_BT_HCIBTUSB_BCM`.
* UVC: `drivers/media/usb/uvc` with `CONFIG_USB_VIDEO_CLASS=m`.
* thinkpad_acpi: single file + flattened `dual_accel_detect.h`; ALSA
  support on, symbols from sound Module.symvers.
* typec: class + `typec_ucsi` (with DP altmode object) + `ucsi_acpi`.
* modules-load.d: `snd-hda-intel` only for sound. **Do not** force-load
  `btusb` (ThinkPad HCI reset timeout if it races `thinkpad_acpi` rfkill;
  see `bluetooth-hci-timeout-thinkpad.md`). `btusb` loads via udev; 
  modprobe.d sets `softdep btusb pre: thinkpad_acpi` and `options btusb reset=1`.
* Policy `Requires` exact EVR of every sibling.
* Local rebuilds may set `KERNEL_SRC_TARBALL` to a cached source
  archive so the script skips the multi-hundred-MB download.

## Publish / image wiring

* `publish-desktop-kmods.yml` detect requires all nine RPMs in
  `manifest.txt`; validate checks new `.ko` paths and package names.
* `generate-kmod-repo-index.sh` human index lists the full set.
* Live + disk kickstarts and KIWI install policy (pulls siblings) and
  the userspace hooks above.
* Canary resolves and checks the new module paths.

## Status

Local full build against the current AZL 4.0 kernel is the gate before
dispatching republish. Sound MODPOST is green; Bluetooth needs the
RFCOMM_TTY ccflag above. After Pages is green, rebuild live + installer
release workflows so images pick up the new policy set. Bare-metal
scorecard on an Intel-class laptop is the final proof (filesystem +
runtime).

WWAN (`qcserial` / MBIM) stays out of scope for this pass.

## CI: concurrent family builds + safe Pages publish

`publish-desktop-kmods.yml` pipeline:

1. **detect** — latest AZL kernel NEVRA; rebuild when the Pages set is
   incomplete, on `republish=true`, on push to the builder/workflow, or
   on the nightly schedule (`17 4 * * *` UTC, ahead of nightly-release).
   Schedule is once per day — policy couples siblings to one kernel EVR,
   so a four-hour poll is unnecessary.
2. **prepare** — one job fetches/verifies the kernel source tarball
   (3 attempts) and uploads it as an artifact.
3. **build-family** — matrix over families (`max-parallel: 4`,
   `fail-fast: false`). Each family gets 3 attempts. Artifacts are
   per-family `.ko` trees only.
4. **package** — runs only when the full sibling set built cleanly.
   Merges family artifacts and builds the policy + all kmod RPMs in one
   rpmbuild so Requires stay exact-EVR coupled.
5. **publish** — under concurrency group
   `azurelinux-desktop-kmod-repository` (`cancel-in-progress: false`):
   merge prior Pages RPMs, `createrepo_c`, validate DNF resolve, deploy
   Pages once, verify manifest on the live URL.

Partial `families=` input is for debug builds of a handful of modules;
package/publish stay gated on the full set so the DNF repo never gets a
policy RPM that cannot resolve every sibling.

## Build fixes (UVC / thinkpad / typec) and partial publish

* **UVC:** ship `uvc.ko` from `drivers/media/common/uvc.c` (`UVC_COMMON`) next to `uvcvideo.ko`.
* **typec:** link UCSI `debugfs.o` and `trace.o` when the AZL kernel has `CONFIG_DEBUG_FS` and `CONFIG_TRACING`.
* **thinkpad:** build `battery.ko` and an OOT `drm_privacy_screen.ko` (local class; stock kernel leaves both off). Build `thinkpad_acpi` without ALSA console mixer so parallel sound is not required at link time.
* **CI:** matrix `fail-fast: false`. Package and Pages publish run when **any** family artifact exists. Policy `Requires` only the sibling kmod RPMs present for that kernel after merge with prior Pages RPMs. Schedule still rebuilds until the full set is on Pages.
