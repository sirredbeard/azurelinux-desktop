# Out-of-tree desktop kmods on GitHub Pages (x86_64)

**Status:** active; USB/Wi-Fi kmod publish path

## Why this exists

Azure Linux 4.0 on **x86_64** builds the stock kernel with several
desktop-relevant drivers off:

* `CONFIG_USB_HID` is not set
* `CONFIG_USB_STORAGE` is not set (so UAS is off too)
* `CONFIG_WLAN` is not set (so `CONFIG_IWLWIFI` and friends never appear)
* `CONFIG_SOUND` is not set (no ALSA / HDA / USB audio)
* `CONFIG_BT` is not set (no Bluetooth core or `btusb`)
* `CONFIG_MEDIA_USB_SUPPORT` is not set (no `uvcvideo`)
* `CONFIG_TYPEC` is not set (no Type-C class / UCSI)
* `CONFIG_THINKPAD_ACPI` is not set (Lenovo platform keys / LEDs / fan)

`cfg80211` and `mac80211` stay `=m`. Parts of media/videobuf2 are
present. The vendor pieces above are not. Same cloud/VM bias as USB.
Wrong for a desktop ISO you expect to boot from a stick, use a USB
keyboard, join Wi-Fi, play audio, pair BT, use a webcam, or dock over
Type-C.

On **aarch64**, the same Azure 4.0 series already ships more of this
in-tree (`=m`). This project is **x86_64 only** for now, so the gap is
ours to close here.

Related deep dives:

* [`azure-kernel-usbhid-kmod.md`](azure-kernel-usbhid-kmod.md) - HID path,
  Pages repo layout, Secure Boot limits
* [`usb-storage-missing-initrd.md`](usb-storage-missing-initrd.md) - stick
  boot / `usb-storage` + `uas`, issue #5
* [`wifi-missing-on-bare-metal.md`](wifi-missing-on-bare-metal.md) - Intel
  Wi-Fi / `CONFIG_WLAN`, firmware vs driver gap
* [`intel-laptop-host-vs-azl-drivers.md`](intel-laptop-host-vs-azl-drivers.md)
  - host Fedora vs nested Azure Linux scorecard
* [`plan-close-desktop-driver-gaps.md`](plan-close-desktop-driver-gaps.md) -
  waves 1–5 execution plan

## What we ship

Nine RPMs per exact Azure `kernel-core` release:

| Package | Contents |
| --- | --- |
| `azurelinux-desktop-usbhid-kmod` | `usbhid.ko` |
| `azurelinux-desktop-usb-storage-kmod` | `usb-storage.ko`, `uas.ko` |
| `azurelinux-desktop-iwlwifi-kmod` | `iwlwifi.ko`, `iwlmvm.ko`, `iwldvm.ko`, `iwlmld.ko` |
| `azurelinux-desktop-sound-kmod` | ALSA core, Intel HDA, common codecs, USB audio |
| `azurelinux-desktop-bluetooth-kmod` | Bluetooth core + `btusb` / `btintel` / helpers |
| `azurelinux-desktop-uvc-kmod` | `uvcvideo.ko` |
| `azurelinux-desktop-thinkpad-kmod` | `thinkpad_acpi.ko` |
| `azurelinux-desktop-typec-kmod` | `typec.ko`, `typec_ucsi.ko`, `ucsi_acpi.ko` |
| `azurelinux-desktop-policy` | empty coupling package |

They install under
`/usr/lib/modules/<uname -r>/extra/azurelinux-desktop/`.
Dracut `add_drivers` on live and installer media pulls **USB** modules
into the initrd (stick boot and early input). iwlwifi, sound, BT, UVC,
thinkpad, and typec are runtime-only (modules-load.d seeds sound and
btusb). Wi-Fi is not required to mount root.

Public DNF repo (GitHub Pages):

`https://sirredbeard.github.io/azurelinux-desktop/repo/`

Browse in a browser (GitHub Pages has no automatic directory listing, so
the publish workflow writes `index.html` at the site root and under
`repo/`): [repo index](https://sirredbeard.github.io/azurelinux-desktop/repo/).
Site root: [https://sirredbeard.github.io/azurelinux-desktop/](https://sirredbeard.github.io/azurelinux-desktop/).
Generator: [`scripts/generate-kmod-repo-index.sh`](../scripts/generate-kmod-repo-index.sh).

## How they are built

Script: [`scripts/build-desktop-kmods.sh`](../scripts/build-desktop-kmods.sh)

Workflow: [`.github/workflows/publish-desktop-kmods.yml`](../.github/workflows/publish-desktop-kmods.yml)

Rough flow for each new Azure kernel:

1. Resolve the newest `kernel` / `kernel-devel` NEVRA from Azure Linux
   package metadata.
2. If Pages already has **policy plus every sibling kmod** for that
   kernel EVR in `manifest.txt`, stop. No rebuild tax. Missing any
   new family (sound, BT, …) forces a rebuild even if policy is old.
3. Else boot an Azure Linux container, install that exact `kernel-devel`.
4. Fetch matching Azure kernel sources; check the published checksum.
5. Force the needed Kconfig as modules (`CONFIG_USB_HID=m`,
   `CONFIG_USB_STORAGE=m`, `CONFIG_USB_UAS=m`, Wi-Fi `CONFIG_IWLWIFI=m`
   family, SOUND/HDA/USB-audio, BT + `btusb`, `CONFIG_USB_VIDEO_CLASS=m`,
   TYPEC/UCSI, THINKPAD_ACPI) with matching `CONFIG_*_MODULE` ccflags
   / force headers so IS_ENABLED paths match `=m`.
6. Build out-of-tree against that release's `.config` and
   `Module.symvers`. For `usb-storage`, rewrite the awkward
   `#include "../../scsi/sd.h"` to a local copy so the external build
   can see SCSI internals. For iwlwifi, copy the full upstream tree and
   leave `DEBUGFS` / device tracing off so header `#ifdef` stays in
   lockstep with which `.c` files get compiled. Sound uses a narrowed
   `sound/` Makefile (`core/ hda/ usb/` only, no full ASoC/SOF first
   pass). Bluetooth builds `net/bluetooth` then drivers with
   `KBUILD_EXTRA_SYMBOLS`. thinkpad_acpi links against sound
   Module.symvers when ALSA support is on. Container build needs
   `gawk` (kbuild `MODPOST` calls `awk`).
7. Package separate RPMs with **exact**
   `Requires: kernel-core-uname-r = <this release>`.
8. Build `azurelinux-desktop-policy` that `Requires` that same kernel
   **and every** sibling kmod RPM.
9. Stage into the Pages tree, keep older matching sets so stale
   installs still resolve, run `createrepo`, validate with a fresh DNF
   transaction (modules present, vermagic matches; no `awk` in the
   tiny validate root - shell `case` on `modinfo` only).
10. Deploy with `actions/deploy-pages`. `curl --fail` the public
    `repomd.xml` afterward.

The workflow runs on a short timer and on demand. Azure kernel publishes
are irregular; polling beats pretending there is a calendar.

## Detect gate: why prepare/build/package/publish often skip

Workflow: [`.github/workflows/publish-desktop-kmods.yml`](../.github/workflows/publish-desktop-kmods.yml).
Hybrid on purpose: own schedule/path-push/dispatch **and**
`workflow_call` from [`release.yml`](../.github/workflows/release.yml)
when the release `kmods` flag is on.

**detect always runs** (when the workflow is invoked). Later jobs are
gated:

```yaml
# prepare (and everything after it)
if: ${{ needs.detect.outputs.build_required == 'true' }}
```

So when `build_required=false`, GitHub marks **prepare**, **build-family**,
**package**, and **publish** as **skipped**. The reusable workflow still
reports success; release continues. That is intentional, not a stuck
job.

### What detect does (short job, sparse log)

1. Query Azure Linux base for the latest `kernel` NEVRA (`dnf5 repoquery`
   inside `mcr.microsoft.com/azurelinux-beta/base/core:4.0`).
2. Download Pages `manifest.txt`
   (`https://sirredbeard.github.io/azurelinux-desktop/repo/manifest.txt`).
3. For that kernel release string, check that every required RPM name is
   listed: policy + usbhid + usb-storage + iwlwifi + sound + bluetooth +
   uvc + thinkpad + typec (`${base}-${krel}.rpm` exact lines).
4. Set `build_required` and the family matrix outputs. No full checkout,
   no compile. A few seconds and a thin log is normal.

### When `build_required` becomes true

| Trigger | Rebuild? |
| --- | --- |
| `push` to kmod scripts or this workflow file | **Always** |
| `republish=true` (workflow_dispatch or `workflow_call` input) | **Always** |
| Any required RPM missing from Pages for the current kernel | **Yes** |
| Schedule or release call, `republish=false`, full set already on Pages | **No** (`build_required=false`) |

`release.yml` calls the reusable workflow with default **`republish=false`**.
So a full ISO release often shows **kmods / detect** success and the
rest skipped when Pages already matches upstream kernel. That does not
mean kmods were forgotten; it means the DNF repo is already complete.

### How to force a rebuild

* Dispatch **Desktop kmod repo** (or pass through release) with
  **`republish=true`**, or
* Change a path under `scripts/build-desktop-kmods.sh`,
  `scripts/generate-kmod-repo-index.sh`, or
  `publish-desktop-kmods.yml` so a `push` rebuild fires, or
* Wait until Azure ships a newer kernel and the manifest check fails.

### Example

Release run `30906725177` (2026-08-04): detect saw
`EVENT_NAME=workflow_dispatch`, `REPUBLISH=false`, Pages already had the
full `6.18.31-1.9.azl4` set → `build_required=false` → prepare and below
skipped. Live/installer/disk jobs still proceeded after kmods finished.

## Policy package (no orphans)

Azure enables module versioning. An old `usbhid.ko` or `iwlwifi.ko`
will not load on a newer `kernel-core`. If DNF could update the kernel
alone, the next boot would lose USB input, stick root, and Wi-Fi.

`azurelinux-desktop-policy` is the lock:

* It requires one exact `kernel-core-uname-r`.
* It requires every sibling kmod RPM from the **same** build.

With the policy installed, a kernel-only update is not a complete
transaction. When Pages gains the next set (kernel already in Azure
repos, plus policy + all sibling kmod RPMs here), DNF can move all of
them together. Live ISO, disk images, installer media, and the canary
canary all install the policy from Pages so that rule is the same
everywhere.

Families stay **sibling** packages, not one fat blob. Policy is what
keeps them and the kernel honest. Firmware and userspace stay separate
Azure packages (`iwlwifi-*-firmware`, `intel-audio-firmware`,
`alsa-ucm`, `bluez`, `NetworkManager-bluetooth`), already listed in
the image inputs.

## What checks upstream first

Before adding another out-of-tree module, check:

1. Azure `base/comps/kernel/*-x86_64-azl.config` for the Kconfig symbol.
2. aarch64 / older AZL series - sometimes the module is already `=m`
   elsewhere.
3. Official Azure Linux ISO initrd (`lsinitrd` / cpio list) - if upstream
   already ships it, do not build a twin.
4. Whether a simple package from Azure or Fedora provides the `.ko`
   (for USB storage/HID on Azure Linux 4.0 x86_64: nothing does).

Issue #5's "Microsoft ISO has the same gap" claim was re-checked against
a fresh official 4.0 x86_64 ISO. Still only `xhci-plat-hcd` in that
initrd. See [`usb-storage-missing-initrd.md`](usb-storage-missing-initrd.md).

## Where images consume the repo

* Live kickstart and disk kickstart: Pages `.repo` +
  `azurelinux-desktop-policy`
* Installer KIWI image: same repo + policy in the live environment;
  offline payload carries the RPMs for the installed system
* Canary container: resolve-only canary (not a desktop)

## Secure Boot

Project-built modules are **not** signed by the Azure kernel key. Fine
for the project's test path without module enforcement. Not a Secure
Boot story.

## Verification checklist

* Pages: `repomd.xml` fetches; `dnf` can install policy + both kmods for
  the target `uname -r`
* `modinfo` vermagic equals that kernel release
* Live and installer **initrd** list:
  `extra/azurelinux-desktop/{usbhid,usb-storage,uas}.ko`
* Nested or bare-metal boot: USB keyboard or stick root as applicable

## Status notes

* 2026-08-02: sibling `usb-storage` package added; Pages publish fixed to
  avoid `awk` in the validate root; installer initrd verified to contain
  all three modules; nested reinstall on host container partition used
  that installer ISO.