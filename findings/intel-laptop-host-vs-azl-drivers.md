# Intel laptop: Fedora host vs nested Azure Linux Desktop

**Status:** host comparison baseline; many gaps closed by desktop kmod waves. Keep for hardware scorecard. Runtime results live in topic files (wifi, bluetooth, sound modules-load, etc.).

Hardware under test: Intel-class laptop, dual-boot Fedora host and nested Azure Linux Desktop install from the project installer ISO (AZL 4.0 kernel plus project out-of-tree kmods).

Compared by mounting the nested root and reading module trees, kernel config, firmware trees, and RPM sets. Filesystem evidence is not a full bare-metal AZL boot log. QEMU cannot exercise the Intel 8260 or the dock the way bare metal can.

## Host devices that matter

* Wi-Fi - Intel Wireless 8260 `[8086:24f3]` - Fedora: iwlwifi + iwlmvm
* Ethernet - Intel I219-LM - Fedora: e1000e
* Display - HD Graphics 520 (Skylake GT2) - Fedora: i915
* Audio internal - Sunrise Point-LP HD Audio `[8086:9d70]` - Fedora: snd_hda_intel
* Audio USB - Blue microphones / headsets - Fedora: snd-usb-audio
* Bluetooth - Intel BT USB `8087:0a2b` - Fedora: btusb + btintel + bluetooth
* Camera internal - UVC vendor device - Fedora: uvcvideo
* Camera USB - Logitech BRIO class - Fedora: uvcvideo
* WWAN - Sierra EM7455 class - Fedora: qcserial + cdc_mbim
* Dock - ThinkPad Ultra Dock hubs - Fedora: xhci_hcd + hub; TB controller thunderbolt
* USB-C / UCSI - ucsi power supply path - Fedora: typec / ucsi_acpi
* Input - USB keyboard/mouse - Fedora: usbhid
* Storage - NVMe - Fedora/AZL: nvme (builtin on AZL)
* Platform - ThinkPad ACPI, batteries - Fedora: thinkpad_acpi
* ME / thermal - mei_me, intel_pch_thermal

Fedora userspace that backs the above: PipeWire + WirePlumber, BlueZ, NetworkManager-wifi (+ wwan/bluetooth plugins), ModemManager, bolt, tuned + tuned-ppd (or older power-profiles-daemon), thermald, fwupd, libcamera, libva-intel-media-driver, mesa, alsa-sof-firmware, full linux-firmware splits.

## Nested AZL: already in good shape

* **Wi-Fi modules + firmware (project work):** `azurelinux-desktop-intel-kmod` installs iwlwifi / iwlmvm / iwldvm / iwlmld under `extra/azurelinux-desktop/`. Firmware packages iwlwifi-mvm/dvm/mld (+ iwlegacy) plus linux-firmware. NetworkManager-wifi + wpa_supplicant installed. Metal bind confirmed in `wifi-missing-on-bare-metal.md`.
* **Display:** i915 present; intel-gpu-firmware has Skylake dmc/guc/huc. mesa + libva-intel-media-driver installed.
* **Ethernet:** e1000e present (I219-LM).
* **NVMe / xHCI:** nvme + xhci built-in (`=y`).
* **USB HID (project):** OOT usbhid; hid, hid-generic, i2c-hid in tree.
* **USB storage (project):** OOT storage-kmod (usb-storage + uas). Upstream AZL has `# CONFIG_USB_STORAGE is not set`.
* **Thunderbolt:** thunderbolt.ko present; bolt userspace installed.
* **Power / thermal userspace:** tuned/tuned-ppd (or ppd), thermald, fwupd; intel_pch_thermal, RAPL, coretemp, processor_thermal_* modules present.
* **MEI / SMBus:** mei + mei-me; i2c-i801.
* **Bluetooth firmware files:** intel ibt-* on disk. BlueZ + gnome-bluetooth packages installed. OOT bluetooth-kmod closes the stack (`bluetooth-hci-timeout-thinkpad.md`).
* **PipeWire stack packages:** pipewire, wireplumber, pipewire-alsa, pipewire-pulseaudio, pipewire-plugin-libcamera.

## Nested AZL: hard gaps (kernel config)

Azure Linux's desktop-bound kernel is still a cloud/server cut. From installed `/boot/config-*-azl4`:

* `CONFIG_SOUND` not set - no ALSA, no snd_hda_intel, no USB audio until OOT sound-kmod
* `CONFIG_BT` not set - no btusb/btintel until OOT bluetooth-kmod
* `CONFIG_MEDIA_USB_SUPPORT` not set - no UVC until OOT uvc-kmod
* `CONFIG_TYPEC` not set - no USB-C / UCSI until OOT typec-kmod
* `CONFIG_USB_STORAGE` not set - mitigated with storage-kmod
* `CONFIG_IWLWIFI` / IWLMVM not set - mitigated with intel-kmod
* `CONFIG_THINKPAD_ACPI` not set (only THINKPAD_LMI=m in stock) - mitigated with thinkpad-kmod

There is no stock `kernel/sound/` or `kernel/drivers/bluetooth/` tree in the installed module set when those options are off. This is not a packaging miss of `kernel-modules-extra`.

Same class of fix as USB stick boot and Wi-Fi: ship OOT modules built against the Azure Linux kernel; do not fork the whole kernel package. Map: `kmod-family-expansion-stock-vs-oot.md`.

## Nested AZL: softer / userspace gaps

Useful on Fedora, thinner on AZL unless added:

* NetworkManager-bluetooth, NetworkManager-wwan (BT plugin is in image inputs with the waves)
* full ModemManager service (libs alone are not enough for WWAN)
* alsa-ucm / alsa-utils once sound modules load
* fprintd / libfprint if the unit has a fingerprint reader
* power-profiles-daemon alone (images use tuned + tuned-ppd like current Fedora)
* optional v4l-utils, full CUPS client, sane scanners

Firmware version skew host vs AZL is secondary when the needed 8260 Wi-Fi/BT blobs are present on AZL.

## Per-device scorecard (this chassis)

* Wi-Fi 8260 - Fedora works; AZL OOT intel-kmod + fw; metal confirmed
* Ethernet I219 - e1000e present; OK on paper
* Display HD 520 - i915 + skl fw + mesa/va; OK on paper
* Internal audio - OOT sound-kmod; do not force-load at boot; metal/runtime per sound findings
* USB mic / headset - same sound-kmod (snd-usb-audio)
* Bluetooth - OOT bluetooth-kmod; metal confirmed after LEDS layout fix
* Internal + BRIO cameras - OOT uvc-kmod; verify `/dev/video*` on metal
* Ultra Dock USB - xHCI builtin + OOT usbhid/storage; typec-kmod for UCSI polish
* Thunderbolt path - thunderbolt + bolt; likely OK
* WWAN EM7455 - optional; kernel modules + full ModemManager if needed
* Batteries / Fn keys - OOT thinkpad-kmod
* Power profiles / thermal - ppd + thermald; OK
* FW updates - fwupd; OK

## What this means for the project

1. **Firmware-only and userspace-only will not close desktop hardware.** Same lesson as iwlwifi for sound, Bluetooth, UVC, USB-C, and ThinkPad platform drivers when AZL turns the kconfig off.

2. **OOT kmod pipeline is the right shape** (build against Azure Linux headers, publish to Pages, pull from kickstarts, keep canary aligned). Current packages use the names in `out-of-tree-usb-kmods-pages.md` (intel not only iwlwifi; storage not only usb-storage; plus surface, sensors, performance, psmouse, policy).

3. **Do not enable these by rebuilding the full Azure Linux kernel in-tree** unless upstream changes. Policy stays: stock Azure Linux kernel RPM + supplemental modules + firmware packages.

4. **Userspace is often ahead of the kernel.** BlueZ, PipeWire, bolt, and libcamera may already be on the image. Once modules land, wire service enables and NM plugins so GNOME sees the devices.

## How to re-check after the next kmod drop

On bare metal AZL:

```bash
lspci -nnk
lsusb
lsmod | grep -iE 'iwl|btusb|snd_hda|uvc|thinkpad|typec|thunder'
for m in iwlwifi btusb snd_hda_intel uvcvideo thinkpad_acpi typec_ucsi; do
  modprobe $m && echo OK $m || echo FAIL $m
done
dmesg | grep -iE 'iwlwifi|Bluetooth|snd_hda|uvcvideo|firmware'
nmcli dev
busctl call org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties \
  Get ss org.bluez.Adapter1 Powered 2>/dev/null || true
pactl info
ls /dev/video* 2>/dev/null || true
```

On the Fedora host, keep the live device list above as the golden "what this chassis needs" reference.

Related: `plan-close-desktop-driver-gaps.md`, `desktop-kmod-waves-1-5.md`, `wifi-missing-on-bare-metal.md`, `bluetooth-hci-timeout-thinkpad.md`.
