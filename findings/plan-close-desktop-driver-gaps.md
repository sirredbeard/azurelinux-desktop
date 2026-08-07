# Plan: close desktop driver gaps on Azure Linux Desktop

**Status:** mostly landed via kmod waves; remaining items live in open issue files

Companion to `intel-laptop-host-vs-azl-drivers.md`. Goal: match day-to-day Fedora desktop hardware behavior on Intel-class chassis without forking the Azure Linux kernel package.

## Fixed policy

* Stock AZL `kernel` / `kernel-devel` RPMs only.
* Supplemental OOT modules from the matching CBL-Mariner kernel source tarball (same pattern as usbhid / storage / intel).
* Publish via `publish-desktop-kmods.yml` -> GitHub Pages DNF repo (`https://sirredbeard.github.io/azurelinux-desktop/repo/`).
* Pull into live kickstart, disk kickstart, installer KIWI path, and canary together.
* `azurelinux-desktop-policy` keeps the set version-locked to one kernel EVR.
* Firmware from AZL (`linux-firmware` splits) first; Fedora only if AZL lacks a required blob.
* Userspace from AZL first, Fedora next, only when the module layer is ready.
* Prove each wave on filesystem, then nested QEMU where useful, then bare metal before calling it done.
* Record each wave in `findings/`; keep the lesson, prune blow-by-blow later.

## Non-goals

* Full custom kernel rebuild or a long-lived kernel fork.
* Perfect parity with every Fedora package on the host (VPN plugins, full CUPS/sane).
* Shipping GNOME/desktop bits into the canary container.
* Solving WWAN before audio/BT/camera unless prioritized.

## Waves

### Wave 0 - baseline and harness

Keep `scripts/build-desktop-kmods.sh` as the single builder. Add families as new stages + RPMs. Detect/publish "complete for this kernel" means **all** current sibling RPMs exist. Host-side scorecard after metal boots: modprobe, nmcli, bluetoothctl/busctl, pactl, `/dev/video*`. Nested QEMU only proves modules load; Wi-Fi/BT/dock need bare metal.

### Wave 1 - Sound (highest user impact)

OOT classic HDA first (`snd_hda_intel` bind path on Skylake-class hosts).

* core: snd, snd-timer, snd-pcm, snd-hwdep, …
* HDA: snd-hda-core, snd-hda-codec, snd-hda-intel
* codecs: generic, realtek/alc269 stack, hdmi
* intel helpers: snd-intel-dspcfg, snd-intel-sdw-acpi as required
* USB: snd-usb-audio (+ snd-usbmidi-lib)

Package: `azurelinux-desktop-sound-kmod`. AZL has `# CONFIG_SOUND is not set`. Force Kconfig, build only shipped objects, install under `extra/azurelinux-desktop/`. Do not force-load at boot (`systemd-modules-load-snd-hda.md`). Firmware: `intel-audio-firmware`; add SOF firmware only if dmesg asks and SOF modules ship later. Userspace: alsa-ucm, PipeWire already on image.

### Wave 2 - Bluetooth

OOT: bluetooth, btusb, btintel, and small helper modules the build requires. Match `CONFIG_BT_LEDS` across net and drivers stages (`bluetooth-hci-timeout-thinkpad.md`). Firmware `ibt-*` from AZL. BlueZ + gnome-bluetooth already installed. Add `NetworkManager-bluetooth` for tethering hooks. Do not force-load btusb.

### Wave 3 - Cameras (UVC)

OOT: uvcvideo plus helpers not already in the AZL tree. videodev and several videobuf2_* are often already present. Userspace: libcamera + pipewire-plugin-libcamera already present.

### Wave 4 - ThinkPad platform

OOT: thinkpad_acpi (and battery/privacy/hid-lenovo helpers when useful). Verify Fn hotkeys, rfkill nodes, battery naming under upower, lid events in GNOME.

### Wave 5 - Dock / USB-C polish

OOT: typec, typec_ucsi, ucsi_acpi. Already present: xHCI builtin, thunderbolt module, bolt, OOT usbhid/storage. Verify dock hubs, UCSI power supply, display/Ethernet through dock if used.

### Wave 6 - WWAN (optional)

Only if modem hardware matters. Modules: qcserial, usb_wwan, cdc_mbim / cdc_ncm, qmi_wwan. Packages: ModemManager, NetworkManager-wwan. Firmware: qcom-wwan-firmware when AZL ships it. Some USB net helpers may already ride on thinkpad-kmod when sources exist.

## Packaging shape (current names)

* `azurelinux-desktop-policy` - meta; Requires exact EVR of every sibling
* `azurelinux-desktop-usbhid-kmod`
* `azurelinux-desktop-psmouse-kmod`
* `azurelinux-desktop-storage-kmod` (was usb-storage-kmod)
* `azurelinux-desktop-intel-kmod` (was iwlwifi-kmod)
* `azurelinux-desktop-sound-kmod`
* `azurelinux-desktop-bluetooth-kmod`
* `azurelinux-desktop-uvc-kmod`
* `azurelinux-desktop-thinkpad-kmod`
* `azurelinux-desktop-typec-kmod`
* `azurelinux-desktop-surface-kmod`
* `azurelinux-desktop-sensors-kmod` - conf-only
* `azurelinux-desktop-performance-kmod` - conf-only

Rules:

* One kernel EVR per publish; rebuild siblings when kernel moves.
* `extra/azurelinux-desktop/` for every `.ko`.
* depmod in `%post`; never overwrite in-tree paths.
* Pages index lists every RPM (`scripts/generate-kmod-repo-index.sh`).
* Kickstarts + KIWI + canary gain new names in the same change set.
* `republish` / `prune_old` inputs on `publish-desktop-kmods.yml` for force rebuild and optional drop of other-kernel RPMs.

## Image / canary parity per wave

1. Builder script + workflow detect list.
2. Publish kmods; confirm Pages repo.
3. Kickstart live + disk: policy from project repo.
4. Installer KIWI: same.
5. Canary: install policy (modules need not load; RPM presence and repo priority are the check).
6. Rebuild release live + installer when ready to dogfood; download via `Get-AzureLinuxDesktop.ps1`.
7. Nested reinstall or `dnf upgrade`; restage nested boot if initrd must carry a module (USB already does; sound/BT usually post-root).
8. Bare metal checklist; append results to findings.

## Initrd policy

* Keep USB HID, psmouse, and storage (and nested-partx on dual-boot hosts) in initrd.
* Do not stuff sound/BT/UVC into initrd unless a real boot-time need appears.
* Wi-Fi stays rootfs-first for desktop.

## Risk order and stop conditions

* Sound spike is the hard one. If the HDA cut exceeds what we can maintain as OOT copies, stop and write the finding before expanding scope. Prefer OOT until upstream flips `CONFIG_SOUND=m`.
* Bluetooth and UVC are closer to the iwlwifi/usb experience when CONFIG flags match across stages.
* Always build against the exact `kernel-devel` EVR that images pin.
* Secure Boot: OOT modules are not Microsoft-signed. Document mok/enrollment or SB off; do not paper over it.

## Success criteria (Intel-class laptop)

On bare-metal AZL Desktop, without copying modules from Fedora:

* Wi-Fi associates.
* Internal speakers/headphones and at least one USB audio device work under PipeWire.
* Bluetooth radio up; pair audio device.
* Internal camera and common UVC devices produce video nodes usable from GNOME.
* Fn/rfkill/battery path via thinkpad_acpi is sane.
* Dock USB devices keep working; UCSI if Wave 5 shipped.
* All of the above survive a kernel EVR bump via the publish workflow.

Implementation detail: `desktop-kmod-waves-1-5.md`, `out-of-tree-usb-kmods-pages.md`, `kmod-family-expansion-stock-vs-oot.md`.
