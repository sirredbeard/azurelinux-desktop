# Out-of-tree desktop kmods on GitHub Pages (x86_64)

**Status:** active publish path for desktop driver gaps

## Why this exists

Azure Linux 4.0 on x86_64 builds the stock kernel with several desktop drivers off:

* `CONFIG_USB_HID` not set
* `CONFIG_USB_STORAGE` not set (UAS off too)
* `CONFIG_WLAN` not set (no iwlwifi opmodes)
* `CONFIG_SOUND` not set
* `CONFIG_BT` not set
* `CONFIG_MEDIA_USB_SUPPORT` not set
* `CONFIG_TYPEC` not set
* `CONFIG_THINKPAD_ACPI` not set
* `CONFIG_INPUT_MOUSE` / full psmouse protocols incomplete for laptops
* Surface platform and related HID options not set

`cfg80211` and `mac80211` stay `=m`. Parts of media and videobuf2 exist. The vendor pieces above do not. Same cloud bias as the rest of the AZL x86_64 cut. Wrong for a desktop ISO that should boot from a stick, take USB input, join Wi-Fi, play audio, pair Bluetooth, use a webcam, or dock over Type-C.

On aarch64 the same series already ships more of this in-tree (`=m`). This project is x86_64 only for now.

Related:

* `azure-kernel-usbhid-kmod.md` - HID path and Pages basics
* `usb-storage-missing-initrd.md` - stick boot and storage modules
* `wifi-missing-on-bare-metal.md` - Intel Wi-Fi gap
* `desktop-kmod-waves-1-5.md` - sound, BT, UVC, thinkpad, typec
* `kmod-family-expansion-stock-vs-oot.md` - stock vs OOT map
* `intel-surface-kmod-families.md` - intel rename and surface
* `plan-close-desktop-driver-gaps.md` - wave plan
* `bluetooth-hci-timeout-thinkpad.md` - BT layout and load order

## What we ship

Sibling RPMs per exact Azure `kernel-core` release. Install under
`/usr/lib/modules/<uname -r>/extra/azurelinux-desktop/`.

* `azurelinux-desktop-usbhid-kmod` - `usbhid.ko`
* `azurelinux-desktop-psmouse-kmod` - psmouse and common PS/2 protocols
* `azurelinux-desktop-storage-kmod` - `usb-storage.ko`, `uas.ko` (Provides/Obsoletes old `usb-storage-kmod` name)
* `azurelinux-desktop-intel-kmod` - `iwlwifi.ko`, `iwlmvm.ko`, `iwldvm.ko`, `iwlmld.ko` (Provides/Obsoletes old `iwlwifi-kmod` name)
* `azurelinux-desktop-sound-kmod` - ALSA core, Intel HDA, common codecs, USB audio
* `azurelinux-desktop-bluetooth-kmod` - Bluetooth core plus `btusb` / `btintel` and helpers
* `azurelinux-desktop-uvc-kmod` - UVC camera stack
* `azurelinux-desktop-thinkpad-kmod` - `thinkpad_acpi` and related ThinkPad bits
* `azurelinux-desktop-typec-kmod` - `typec`, `typec_ucsi`, `ucsi_acpi`
* `azurelinux-desktop-surface-kmod` - serdev, SSAM, Surface platform, Microsoft/multitouch HID
* `azurelinux-desktop-sensors-kmod` - conf-only modules-load for stock hwmon/i2c
* `azurelinux-desktop-performance-kmod` - conf-only modules-load + sysctl + zram-generator conf (see `desktop-performance-policy.md`)
* `azurelinux-desktop-policy` - empty meta package that Requires the exact kernel and every sibling present in that build

Dracut `add_drivers` on live and installer media pulls USB HID, psmouse, and storage modules into the initrd (stick boot and early input). Wi-Fi, sound, Bluetooth, UVC, thinkpad, typec, and surface stay runtime-only. Do not force-load `snd-hda-intel` or `btusb` at boot; see `systemd-modules-load-snd-hda.md` and `bluetooth-hci-timeout-thinkpad.md`.

Public DNF repo:

`https://sirredbeard.github.io/azurelinux-desktop/repo/`

GitHub Pages has no automatic directory listing. The publish job writes `index.html` at the site root and under `repo/`. Generator: `scripts/generate-kmod-repo-index.sh`.

## How they are built

Script: `scripts/build-desktop-kmods.sh`

Workflow: `.github/workflows/publish-desktop-kmods.yml`

Rough flow for each new Azure kernel:

1. Resolve the newest `kernel` / `kernel-devel` NEVRA from Azure Linux metadata.
2. If Pages already has policy plus every required sibling for that kernel EVR in `manifest.txt`, stop. Missing any family forces a rebuild.
3. Else boot an Azure Linux container and install that exact `kernel-devel`.
4. Fetch matching Azure kernel sources and check the published checksum.
5. Force the needed Kconfig symbols as modules with matching `CONFIG_*_MODULE` ccflags so `IS_ENABLED` paths match `=m`.
6. Build each family out-of-tree against that release's `.config` and `Module.symvers`. Storage rewrites the awkward `#include "../../scsi/sd.h"` to a local copy. Intel Wi-Fi copies the full iwlwifi tree and leaves DEBUGFS / device tracing off. Sound uses a narrowed `sound/` Makefile (`core/ hda/ usb/` first). Bluetooth builds `net/bluetooth` then drivers with matching `CONFIG_BT_*` (including `CONFIG_BT_LEDS`) and `KBUILD_EXTRA_SYMBOLS`. Container build needs `gawk` (kbuild MODPOST calls awk).
7. Package separate RPMs with exact `Requires: kernel-core-uname-r = <this release>`.
8. Build `azurelinux-desktop-policy` that Requires that kernel and every sibling packaged for the run.
9. Stage into the Pages tree. Default publish merges older kernel sets so stale installs still resolve. Optional `prune_old=true` drops other-kernel RPMs and keeps only the current set. Sign RPMs, run `createrepo_c`, validate with a fresh DNF resolve.
10. Deploy with `actions/deploy-pages`. `curl --fail` the public `repomd.xml` afterward.

## Detect gate

The workflow is hybrid on purpose: own schedule (`17 4 * * *` UTC) and dispatch, plus `workflow_call` from `release.yml` when the release `kmods` flag is on. No push trigger — main only spends Actions budget on schedule and manual/release calls. Kernel drift can refresh Pages without a full ISO night.

**detect always runs.** Later jobs only run when `build_required=true`. When false, prepare / build-family / package / publish show skipped. That is intentional.

Detect does a short job:

1. Query Azure base for the latest `kernel` NEVRA.
2. Download Pages `manifest.txt`.
3. Require every listed RPM name for that kernel release (policy + all families above). Legacy-only `iwlwifi-kmod` or `usb-storage-kmod` without the new names counts as incomplete.
4. Set `build_required` and the family matrix. No full compile in detect.

When `build_required` becomes true:

* `republish=true` always rebuilds
* `prune_old=true` always rebuilds (needs a publish pass)
* any required RPM missing for the current kernel rebuilds
* schedule or release call with both flags false and a full set already on Pages does not rebuild

`release.yml` calls with default `republish=false`. A full ISO release often shows kmods detect success and the rest skipped when Pages already matches. That means the DNF repo is complete, not forgotten.

Force a rebuild with `republish=true`, `prune_old=true`, or wait for a newer Azure kernel.

## CI shape

1. **detect** - latest kernel; rebuild rules above.
2. **prepare** - fetch and verify the kernel source tarball once; upload as artifact.
3. **build-family** - matrix over families (`usbhid`, `psmouse`, `storage`, `intel`, `sound`, `bluetooth`, `uvc`, `thinkpad`, `typec`, `surface`, `sensors`, `performance`). Legacy aliases: `iwlwifi`->`intel`, `usb-storage`->`storage`. Per-family `.ko` (or conf-only) artifacts.
4. **package** - merge family artifacts; build policy + kmod RPMs in one rpmbuild so Requires stay exact-EVR coupled. Policy Requires only siblings present after merge when some families failed.
5. **publish** - concurrency group `azurelinux-desktop-kmod-repository` (`cancel-in-progress: false`). Merge prior Pages RPMs (or prune), sign, `createrepo_c`, validate, deploy Pages, verify live URL.

### Conf-only families and hidden files

`sensors` and `performance` ship modules-load/sysctl conf only, no `.ko`. The family stage used to mark them with a hidden `.conf-only` file. `actions/upload-artifact@v4` drops hidden files unless `include-hidden-files: true`, so the package job merged empty-looking trees and skipped those RPMs. Policy then never Required them. Canary still greps for both names and would fail a full resolve once those checks run against a thin set.

Fix:

* family upload sets `include-hidden-files: true`
* package stage treats the conf payload as enough (`azurelinux-desktop-sensors.conf` / `azurelinux-desktop-performance.conf`), not only the marker

After a republish with that fix, Pages must list both conf RPMs for the current kernel and policy must Require them.

Partial `families=` is for debug. Prefer full set for real publishes.

## Policy package

Azure enables module versioning. An old `.ko` will not load on a newer `kernel-core`. If DNF could update the kernel alone, the next boot would lose USB input, stick root, Wi-Fi, and the rest.

`azurelinux-desktop-policy` is the lock:

* Requires one exact `kernel-core-uname-r`
* Requires every sibling kmod RPM from the same publish set

With policy installed, a kernel-only update is not a complete transaction. When Pages gains the next full set, DNF can move them together. Live ISO, disk images, installer media, and the canary install policy from Pages so the rule is the same everywhere.

Families stay sibling packages, not one fat blob. Firmware and userspace stay separate Azure packages (`iwlwifi-*-firmware`, `intel-audio-firmware`, `alsa-ucm`, `bluez`, `NetworkManager-bluetooth`, and friends).

## Check upstream first

Before adding another out-of-tree module:

1. Azure `base/comps/kernel/*-x86_64-azl.config` for the Kconfig symbol.
2. aarch64 or older AZL series - sometimes already `=m` elsewhere.
3. Official Azure Linux ISO initrd - if upstream ships it, do not build a twin.
4. Whether Azure or Fedora already provides the `.ko` for this kernel.

Issue #5's claim that Microsoft's ISO has the same USB storage gap was re-checked. Still only `xhci-plat-hcd` in that initrd. See `usb-storage-missing-initrd.md`.

## Where images consume the repo

* Live and disk kickstarts: Pages `.repo` + `azurelinux-desktop-policy`
* Installer KIWI: same repo + policy in the live environment; offline payload carries RPMs for the installed system
* Canary container: resolve-only canary (not a desktop)

## Secure Boot

Project-built modules are not signed by the Azure kernel key. Fine for the project's test path without module enforcement. Not a Secure Boot story.

## RPM GPG signing

Desktop kmod RPMs on Pages use the same OpenPGP key as the Copilot Flatpak stream.

* Secrets: `GPG_PRIVATE_KEY`, `GPG_PUBLIC_KEY`, `GPG_KEY_ID`
* Scripts: `scripts/rpm-gpg-import.sh`, `scripts/sign-desktop-rpms.sh`
* Sign every RPM after merge/policy rebuild, then `createrepo_c`
* Public key: `assets/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop` and site root on Pages
* Client `.repo`: `gpgcheck=1` and `gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop`

UID: Hayden Barnes (sirredbeard) <gpg@sirredbeard.github.io>. Detail: `packaging/gpg/README.md`. After enabling signing, republish with `republish=true` so old unsigned RPMs are replaced.

## Verification checklist

* Pages: `repomd.xml` fetches; DNF can install policy + siblings for the target `uname -r`
* `modinfo` vermagic equals that kernel release
* Live and installer initrd list USB modules under `extra/azurelinux-desktop/`
* Nested or bare-metal boot: USB keyboard or stick root as applicable; Wi-Fi/BT/audio on metal for those families
