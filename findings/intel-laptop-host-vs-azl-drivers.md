# Intel laptop: Fedora host vs nested Azure Linux Desktop

**Status:** superseded in part by desktop-kmod-waves and bluetooth findings; keep as host comparison

Hardware under test: Intel-class laptop, dual-boot host Fedora and nested Azure Linux Desktop install from the project installer ISO (AZL 4.0 kernel plus project out-of-tree kmods).

Compared by mounting the nested root and reading module trees, kernel
config, firmware trees, and RPM sets. This is filesystem evidence, not
a bare-metal AZL boot log. QEMU cannot exercise the Intel 8260 or the
dock the way bare metal can.

## Host devices that matter

| Class | Hardware | Fedora driver in use |
| --- | --- | --- |
| Wi-Fi | Intel Wireless 8260 `[8086:24f3]` | `iwlwifi` + `iwlmvm` |
| Ethernet | Intel I219-LM `[8086:156f]` | `e1000e` |
| Display | HD Graphics 520 (Skylake GT2) `[8086:1916]` | `i915` |
| Audio (internal) | Sunrise Point-LP HD Audio `[8086:9d70]` | `snd_hda_intel` (+ SOF/AVS stack available) |
| Audio (USB) | Logitech Blue Microphones | `snd-usb-audio` |
| Bluetooth | Intel BT USB `8087:0a2b` (on 8260) | `btusb` + `btintel` + `bluetooth` |
| Camera (internal) | Bison `5986:111c` | `uvcvideo` |
| Camera (USB) | Logitech BRIO | `uvcvideo` |
| WWAN | Sierra EM7455 `1199:9079` | `qcserial` + `cdc_mbim` |
| Dock | ThinkPad Ultra Dock hubs `17ef:1010` / `100f` | `xhci_hcd` + hub; TB controller `thunderbolt` |
| USB-C / UCSI | `ucsi-source-psy-…` power supply | `typec` / `ucsi_acpi` path |
| Input | USB keyboard/mouse, PS/2 class | `usbhid`, hid stack |
| Storage | Samsung NVMe | `nvme` (builtin on AZL) |
| Platform | ThinkPad ACPI, batteries BAT0/BAT1 | `thinkpad_acpi`, power_supply |
| ME / mgmt | CSME HECI | `mei_me` |
| Thermal | PCH thermal | `intel_pch_thermal` |

Fedora userspace that backs the above: PipeWire + WirePlumber, BlueZ,
NetworkManager-wifi (+ wwan/bluetooth plugins), ModemManager, bolt,
power-profiles-daemon / tuned-ppd, thermald, fwupd, libcamera,
libva-intel-media-driver, mesa, alsa-sof-firmware, full
`linux-firmware` split (iwlwifi, intel BT `ibt-12-16`, i915 skl_*,
SOF, qcom-wwan, …), fprintd optional.

## Nested AZL: what is already in good shape

These match the laptop well enough at the package/module layer:

* **Wi-Fi modules + firmware (project work):**
  `azurelinux-desktop-iwlwifi-kmod` installs
  `iwlwifi` / `iwlmvm` / `iwldvm` / `iwlmld` under
  `extra/azurelinux-desktop/`. Firmware packages
  `iwlwifi-mvm-firmware`, `iwlwifi-dvm-firmware`, `iwlwifi-mld-firmware`
  plus `linux-firmware` provide `iwlwifi-8000C-34/36.ucode` for the 8260.
  NetworkManager-wifi + wpa_supplicant are installed. Bare metal is
  still the real bind test.
* **Display:** `i915` module present; `intel-gpu-firmware` has Skylake
  `skl_dmc_*` / `skl_guc_*` / `skl_huc_*`. mesa +
  `libva-intel-media-driver` installed.
* **Ethernet:** `e1000e` module present (I219-LM).
* **NVMe / xHCI:** `nvme` + `xhci-hcd`/`xhci-pci` are builtin (`=y`).
* **USB HID path (project work):** OOT `usbhid` kmod; `hid`,
  `hid-generic`, `i2c-hid` present in tree.
* **USB storage path (project work):** OOT `usb-storage` + `uas`
  (upstream AZL has `# CONFIG_USB_STORAGE is not set`).
* **Thunderbolt controller module:** `thunderbolt.ko` is present;
  `bolt` userspace package is installed.
* **Power / thermal userspace:** `power-profiles-daemon`, `thermald`,
  `fwupd` enabled; `intel_pch_thermal`, RAPL, `coretemp`,
  `processor_thermal_*` modules present.
* **MEI:** `mei` + `mei-me` modules present.
* **SMBus:** `i2c-i801` present (Sunrise Point SMBus).
* **Bluetooth firmware files:** `intel/ibt-12-16.{sfi,ddc}` is on disk
  (correct family for 8260 BT). BlueZ + gnome-bluetooth packages are
  installed.
* **PipeWire stack packages:** pipewire, wireplumber, pipewire-alsa,
  pipewire-pulseaudio, pipewire-plugin-libcamera are installed.

## Nested AZL: hard gaps (kernel config, not missing RPMs)

Azure Linux’s desktop-bound kernel is still a cloud/server cut. From
`/boot/config-6.18.31-1.9.azl4` on the install:

| Kconfig | AZL | Fedora host | Effect on this laptop |
| --- | --- | --- | --- |
| `CONFIG_SOUND` | **not set** | `m` | No ALSA. No `snd_hda_intel`, no SOF, no USB audio. Internal speakers/mic and Blue Yeti stay dead even with PipeWire installed. |
| `CONFIG_BT` | **not set** | `m` | No Bluetooth stack. `btusb`/`btintel` absent. BlueZ and `ibt-12-16` firmware cannot attach the 8260 BT interface. |
| `CONFIG_MEDIA_USB_SUPPORT` | **not set** | `y` | No UVC. Internal Bison camera and Logitech BRIO will not get `/dev/video*`. V4L2 core exists; USB video class does not. |
| `CONFIG_TYPEC` | **not set** | `m` | No USB-C / UCSI stack. Dock and USB-C power-role behavior will be weaker than Fedora even if xHCI enumerates hubs. |
| `CONFIG_USB_STORAGE` | **not set** | `m` | Already mitigated with OOT `usb-storage`/`uas` kmods. |
| `CONFIG_IWLWIFI` / `IWLMVM` | **not set** | `m` | Already mitigated with OOT iwlwifi kmod. |
| `CONFIG_THINKPAD_ACPI` | **not set** (only `THINKPAD_LMI=m`) | `m` | No classic ThinkPad hotkeys, rfkill switches via tpacpi, fan/LED/battery quirks path Fedora uses. |

There is **no** `kernel/sound/` tree and **no**
`kernel/drivers/bluetooth/` tree in the installed module set. This is
not a packaging miss of `kernel-modules-extra`; the options are off in
the upstream Azure Linux kernel build.

`# CONFIG_USB_STORAGE is not set` is the same class of problem we
already solved for stick boots and Wi-Fi: ship OOT modules built
against the Azure Linux kernel, do not fork the whole kernel package.

## Nested AZL: softer / userspace gaps

Useful on Fedora for this machine, missing or thinner on Azure Linux install:

* `NetworkManager-bluetooth`, `NetworkManager-wwan`
* full `ModemManager` service package (only `ModemManager-glib` +
  libqmi/libmbim libs showed up; no `qcserial`/`cdc_mbim` modules
  either, so EM7455 WWAN is a kernel+userspace gap)
* `alsa-sof-firmware`, `alsa-ucm`, `alsa-utils` (mostly moot until
  `CONFIG_SOUND=m`)
* `fprintd` / `libfprint` (fingerprint, if the Intel laptop unit has one)
* `tuned` / `tuned-ppd` (host uses these; AZL has
  power-profiles-daemon instead, which is fine)
* optional: `v4l-utils`, full CUPS client stack, sane scanners

Firmware version skew only: host `linux-firmware` `20260622` vs Azure Linux
`20260221`. For 8260 Wi-Fi/BT the needed blobs are present on AZL;
newer host firmware is not the main story.

## Per-device scorecard (this Intel laptop)

| Need | Fedora | AZL nested install | Blocker type |
| --- | --- | --- | --- |
| Wi-Fi 8260 | works | modules+fw present (OOT); bare-metal proof still open | runtime verify |
| Ethernet I219 | works | `e1000e` present | OK on paper |
| Display HD 520 | works | `i915` + skl fw + mesa/va | OK on paper |
| Internal audio | works | **no kernel sound** | kconfig OOT or kernel policy |
| USB mic / headset | works | **no snd-usb-audio** | same |
| Bluetooth | works | **no CONFIG_BT**; fw+bluez only | kconfig OOT |
| Internal + BRIO cameras | works | **no MEDIA_USB / uvcvideo** | kconfig OOT |
| Ultra Dock USB | works | xHCI builtin + OOT usbhid/storage; no TYPEC/UCSI | partial |
| Thunderbolt path | present | `thunderbolt` + bolt | likely OK |
| WWAN EM7455 | present | no qcserial/cdc_mbim; thin MM | kconfig + pkg |
| Batteries / Fn keys | thinkpad_acpi | **no thinkpad_acpi** | kconfig OOT |
| Power profiles / thermal | tuned-ppd + thermald | ppd + thermald | OK |
| FW updates | fwupd | fwupd | OK |

## What this means for the project

1. **Firmware-only and userspace-only will not close desktop hardware.**
   We already learned that for iwlwifi. The same pattern is true for
   sound, Bluetooth, UVC, USB-C, and ThinkPad platform drivers: AZL
   turns the kconfig off.

2. **OOT kmod pipeline is the right shape** (build against Azure Linux kernel
   headers, publish to project Pages repo, pull from kickstarts, keep
   canary aligned). Next candidates for this machine, in rough
   priority:
   1. **Sound:** `snd-hda-intel` + codec helpers (and USB audio if we
      want the Yeti/BRIO path). Skylake can also want SOF/AVS pieces;
      start with classic HDA which Fedora is actually binding here.
   2. **Bluetooth:** `bluetooth` + `btusb` + `btintel` (and deps).
   3. **UVC:** `uvcvideo` + videobuf helpers if not already pulled.
   4. **ThinkPad platform:** `thinkpad_acpi`.
   5. **Type-C / UCSI:** `typec`, `typec_ucsi`, `ucsi_acpi` (dock
      polish).
   6. **WWAN (optional):** `qcserial`, `cdc_mbim`, plus ModemManager
      package if WWAN matters.

3. **Do not enable these by rebuilding the full Azure Linux kernel in-tree**
   unless upstream changes. Policy stays: stock Azure Linux kernel RPM + our
   supplemental modules + firmware packages.

4. **Userspace is ahead of the kernel in several places.** BlueZ,
   PipeWire, bolt, and libcamera are already on the image. Once modules
   land, wire service enables and NM plugins (`NetworkManager-bluetooth`,
   `NetworkManager-wwan`, ModemManager) as needed so GNOME sees the
   devices.

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
nmcli dev; bluetoothctl show; pactl info; ls /dev/video*
```

On the Fedora host, keep using the live device list above as the
golden "what this chassis needs" reference.

## Evidence paths (session)

Host captures under `/tmp/hw-compare/host/` (lspci, modules, packages).
Nested captures under `/tmp/hw-compare/azl/` (module presence, kconfig
snippets, rpm lists). Nested root was unmounted and `kpartx -d` cleared
after the pass.