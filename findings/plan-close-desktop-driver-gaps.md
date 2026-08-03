# Plan: close desktop driver gaps on Azure Linux Desktop

**Status:** mostly landed via kmod waves; remaining items tracked in open issue files

Companion to `intel-laptop-host-vs-azl-drivers.md`. Goal: match
Fedora Rawhide on this chassis for the classes that matter day to day,
without forking the Azure Linux kernel package.

Policy stays fixed:

* Stock AZL `kernel` / `kernel-devel` RPMs only.
* Supplemental OOT modules built from the matching CBL-Mariner kernel
  source tarball (same pattern as usbhid / usb-storage / iwlwifi).
* Publish via `publish-desktop-kmods.yml` → GitHub Pages DNF repo.
* Pull into live kickstart, disk kickstart, installer KIWI path, and
  canary container canary together.
* `azurelinux-desktop-policy` keeps the set version-locked to one
  kernel EVR so partial upgrades cannot mix module ABIs.
* Firmware from AZL (`linux-firmware` splits) first; Fedora only if AZL
  is missing a required blob.
* Userspace from AZL first, Fedora next, only when the module layer is
  ready to use it.
* Prove each wave on filesystem, then nested QEMU where possible, then
  bare metal on this Intel laptop before calling it done.
* Record each wave in `findings/`; prune blow-by-blow later, keep the
  lesson.

## Non-goals

* Full custom kernel rebuild or carrying a long-lived kernel fork.
* Perfect parity with every Fedora package on the host (VPN plugins,
  full CUPS/sane stack, tuned vs power-profiles-daemon).
* Shipping GNOME/desktop bits into the canary container canary.
* Solving WWAN before audio/BT/camera unless the user prioritizes it.

## Waves

### Wave 0 — baseline and harness (short)

Already largely done; only tighten what the next builds need.

1. Keep `scripts/build-desktop-kmods.sh` as the single builder; add
   families as new stages + RPMs, not new one-off scripts.
2. Extend detect/publish logic so “repo complete for this kernel”
   means **all** current sibling RPMs exist (not only policy +
   iwlwifi).
3. Add a small host-side checklist script under `scripts/` that mounts
   or SSHes into AZL and prints the scorecard from the Intel laptop findings
   (modprobe, nmcli, bluetoothctl, pactl, `/dev/video*`). Run it after
   every wave on bare metal.
4. Optional: nested QEMU smoke only proves modules load and do not
   taint-panic; Wi-Fi/BT/dock need bare metal.

### Wave 1 — Sound (highest user impact)

**Kernel (OOT):** classic HDA path first, because Fedora on this
machine binds `snd_hda_intel` for `[8086:9d70]`.

Minimum module set to research and package (names indicative):

* core: `snd`, `snd-timer`, `snd-pcm`, `snd-hwdep`, …
* HDA: `snd-hda-core`, `snd-hda-codec`, `snd-hda-intel`
* codecs seen on host: `snd-hda-codec-generic`,
  `snd-hda-codec-realtek` / `alc269` stack, `snd-hda-codec-hdmi`
* intel helpers: `snd-intel-dspcfg`, `snd-intel-sdw-acpi` as required
  by the HDA bind path

Second package or same RPM second stage if deps stay small:

* `snd-usb-audio` (+ `snd-usbmidi-lib`) for Blue Yeti and USB headsets

**Build notes:**

* AZL has `# CONFIG_SOUND is not set`. Same approach as USB storage:
  force the Kconfig symbols the upstream sources expect for `=m`,
  build only the objects we ship, install under
  `extra/azurelinux-desktop/`, `depmod` in `%post`.
* Sound is a deep dependency tree. Spike in CI or a throwaway
  container first: list `modprobe --show-depends snd_hda_intel` on
  Fedora, map each dep to AZL source paths, build the cut set, then
  freeze the list in the builder script.
* Prefer one RPM `azurelinux-desktop-sound-kmod` (or `snd-hda-kmod` +
  `snd-usb-kmod`) versioned to the kernel EVR. Policy Requires: all.

**Firmware / userspace:**

* Confirm `intel-audio-firmware` (AVS/SST blobs) is enough for this
  Skylake HDA path; add `alsa-sof-firmware` only if dmesg asks for SOF
  and we later ship SOF modules.
* Add `alsa-ucm` + `alsa-utils` if missing once modules load.
* PipeWire / WirePlumber already on image; verify user session sees
  sinks/sources after modprobe.

**Verify:**

* `lspci -nnk` shows `snd_hda_intel` in use.
* `cat /proc/asound/cards`, `pactl list short sinks`, speaker-test or
  GNOME Settings.
* USB mic enumerates when `snd-usb-audio` ships.

### Wave 2 — Bluetooth

**Kernel (OOT):**

* `bluetooth`, `btusb`, `btintel` (and small deps Fedora pulls:
  `btrtl`/`btbcm`/`btmtk` only if the build requires symbols; 8260 is
  Intel).
* RFCOMM/BNEP/HIDP if BlueZ needs them as modules rather than
  built-in.

**Firmware / userspace:**

* `ibt-12-16` already on AZL image.
* BlueZ + gnome-bluetooth already installed; enable/start
  `bluetooth.service` (already enabled on nested install).
* Add `NetworkManager-bluetooth` so NM can expose BT tethering if we
  care; not required for headsets.

**Verify:**

* `lsusb` `8087:0a2b` → driver `btusb`.
* `bluetoothctl show` powered; pair a known headset (host already uses
  one as default sink).

### Wave 3 — Cameras (UVC)

**Kernel (OOT):**

* `uvcvideo` plus any videobuf2 helpers not already in the AZL tree
  (`videodev` and several videobuf2_* are already present).

**Userspace:**

* `libcamera` + `pipewire-plugin-libcamera` already present.
* Optional `v4l-utils` for debugging only.

**Verify:**

* `/dev/video*` for Bison `5986:111c` and BRIO `046d:085e`.
* Snapshot via GNOME Camera / `pw-record` / `libcamera-hello` if
  packaged.

### Wave 4 — ThinkPad platform

**Kernel (OOT):**

* `thinkpad_acpi` (and `thinkpad_hwmon` if separate and useful).

**Verify:**

* Fn hotkeys, rfkill nodes (`tpacpi_*`), battery naming stable under
  upower, lid/events sane in GNOME.

### Wave 5 — Dock / USB-C polish

**Kernel (OOT):**

* `typec`, `typec_ucsi`, `ucsi_acpi` (and thin deps).

**Already present:** xHCI builtin, thunderbolt module, bolt, OOT
usbhid/storage.

**Verify:**

* Ultra Dock hubs still enumerate; UCSI power supply appears; display
  / Ethernet through dock if used; no regressions on undock.

### Wave 6 — WWAN (optional, last)

Only if EM7455 matters on this machine.

* Modules: `qcserial`, `usb_wwan`, `cdc_mbim` / `cdc_ncm`, maybe
  `qmi_wwan`.
* Packages: full `ModemManager`, `NetworkManager-wwan`.
* Firmware: `qcom-wwan-firmware` already in AZL firmware set.

## Packaging and repo shape

Keep the existing four-way pattern; grow it deliberately:

| RPM | Role |
| --- | --- |
| `azurelinux-desktop-policy` | meta; `Requires` exact EVR of every sibling |
| `…-usbhid-kmod` | existing |
| `…-usb-storage-kmod` | existing |
| `…-iwlwifi-kmod` | existing |
| `…-sound-kmod` | Wave 1 |
| `…-bluetooth-kmod` | Wave 2 |
| `…-uvc-kmod` | Wave 3 |
| `…-thinkpad-kmod` | Wave 4 |
| `…-typec-kmod` | Wave 5 |
| `…-wwan-kmod` | Wave 6 optional |

Rules:

* One kernel EVR per publish; rebuild all siblings when kernel moves.
* `extra/azurelinux-desktop/` install path for every `.ko`.
* weak-modules / `depmod` in `%post`; never overwrite in-tree paths.
* Pages index (`generate-kmod-repo-index.sh`) lists every RPM.
* Kickstarts + `kiwi/config.sh` + canary container parser all gain the
  new names in the same change set.
* SELinux: if OOT load fails on enforcing, fix file context in policy
  RPM or module `%post` (same discipline as current kmods).

## Image / kickstart / canary parity

For each wave’s merge:

1. Builder script + workflow detect list.
2. Publish kmods; confirm Pages repo + browsable index.
3. Kickstart live + disk: install new RPMs from project repo.
4. Installer KIWI `config.sh` / package list: same RPMs.
5. Canary container: install policy + new kmod RPMs (modules need not
   load in the canary; RPM presence and repo priority are the check).
6. `test-container.yml` / preflight: assert new NEVRAs resolve from
   the project repo.
7. Rebuild **release** live + installer ISOs (not build-only) when
   ready to dogfood; download via `Get-AzureLinuxDesktop.ps1`.
8. Nested reinstall or `dnf upgrade` on p4; restage nested boot if
   initrd must carry any module (USB already does; sound/BT usually
   post-root is enough).
9. Bare metal checklist on Intel laptop; append results to findings.

## Initrd policy

* Keep USB HID/storage (and nested-partx on dual-boot hosts) in
  initrd.
* Do **not** stuff sound/BT/UVC into initrd unless a real boot-time
  need appears. Rootfs + `modules-load.d` / udev is enough.
* Wi-Fi can stay rootfs-first for desktop; only add to initrd if we
  ever need network root or early iwd.

## Risk order and stop conditions

* **Sound spike is the hard one.** If the HDA dependency cut exceeds
  what we can maintain as OOT copies, stop and write the finding
  before expanding scope. Fallback options then: narrower codec set,
  or revisit whether AZL upstream will flip `CONFIG_SOUND=m` (prefer
  OOT until that exists).
* **Bluetooth and UVC** should be much closer to the iwlwifi/usb
  experience (small, bounded source sets).
* **Symbol / vermagic mismatches:** always build against the exact
  `kernel-devel` EVR that images pin.
* **Secure Boot:** OOT modules will not be Microsoft-signed. Document
  that desktop kmods need mok/enrollment or SB off for load, same as
  current usb/iwlwifi story if that is already the case; do not paper
  over it.

## Suggested execution order (checklist)

1. Spike Wave 1 module list from Fedora `modprobe --show-depends` +
   AZL sources; record in findings.
2. Implement sound stage in `build-desktop-kmods.sh` + policy Requires.
3. Publish; pull into kickstarts/KIWI/canary; release ISOs.
4. Bare-metal audio proof on Intel laptop.
5. Wave 2 Bluetooth (build → publish → images → bare metal BT pair).
6. Wave 3 UVC (same).
7. Wave 4 thinkpad_acpi (same).
8. Wave 5 typec/ucsi if dock still weak.
9. Wave 6 WWAN only on request.
10. README: expand “custom kernel drivers” bullet to name sound, BT,
    camera, ThinkPad helpers as they land; keep x86_64 / Intel scope
    note honest.

## Success criteria (this laptop)

On bare-metal AZL Desktop, without copying modules from Fedora:

* Wi-Fi associates (already the open proof for iwlwifi).
* Internal speakers/headphones and at least one USB audio device work
  under PipeWire.
* Bluetooth radio up; pair audio device.
* Internal camera and BRIO produce video nodes usable from GNOME.
* Fn/rfkill/battery path via thinkpad_acpi is sane.
* Ultra Dock USB devices keep working; UCSI if we shipped Wave 5.
* All of the above survive a kernel EVR bump via the existing
  publish-every-new-kernel workflow.