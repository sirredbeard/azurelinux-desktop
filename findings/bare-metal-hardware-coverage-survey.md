# Bare-metal hardware coverage survey (ThinkPad T470s)

Survey of this project's out-of-tree kmod coverage against real hardware
on a bare-metal ThinkPad T470s running the live desktop build, plus a
couple of related questions that came up while poking at it.

## Is the kernel aware it's docked?

No, and that's correct, not a bug. This machine sits in a Lenovo
ThinkPad Ultra Dock, which shows up purely as USB devices
(`17ef:1010` / `17ef:100f`, "Lenovo ThinkPad Dock" hub) on both the
USB 2.0 and 3.0 buses. There's no ACPI dock station object
(`PNP0C15`) anywhere in `/sys/bus/acpi/devices/`, and `dmesg`/
`thinkpad_acpi`'s legacy `/proc/acpi/ibm/dock` interface don't exist on
this hardware either. That's expected: only older ThinkPads with a
physical bottom-of-laptop dock connector (T430/T440-era UltraBase,
etc.) used the ACPI dock mechanism. Modern ThinkPad Ultra/Basic/
Hybrid docks are USB (or USB-C/Thunderbolt) hubs and are handled by
ordinary USB hotplug - no dock-specific kernel or udev handling is
needed or missing here.

## hid-multitouch: now its own package

`CONFIG_I2C_HID` is stock (`=m`) on Azure Linux 4.0's kernel, but
`CONFIG_HID_MULTITOUCH` is off. Several modern ThinkPad models (and
plenty of non-Lenovo laptops) report their trackpad or touchscreen
through the generic Windows Precision Touchpad / multitouch HID
protocol over i2c-hid, rather than the Synaptics RMI4 SMBus path that
`psmouse-kmod` already covers. This module previously only shipped
inside `azurelinux-desktop-surface-kmod`, which meant a ThinkPad user
had no reason to know they might need to install the Surface package
for their trackpad to work.

Fixed by giving it its own small package,
`azurelinux-desktop-hid-multitouch-kmod`, built directly from
`drivers/hid/hid-multitouch.c` (same recipe already proven in the
surface-kmod stage, just standalone). `azurelinux-desktop-thinkpad-kmod`
now carries a `Recommends:` on it so it installs by default alongside
the rest of the ThinkPad stack, without forcing every ThinkPad install
to also pull in the unrelated Surface SSAM/DTX/platform-profile stack.
`surface-kmod` keeps building its own copy for its own dependency
checks; not worth touching since it works today.

Verified: compiled cleanly against this box's real installed
`kernel-devel-6.18.31-1.16.azl4.x86_64` using the exact same
Makefile/ccflags the surface stage already uses in CI. (Local test used
a newer Azure Linux kernel source tag, since the exact 6.18.31.1 tag
had already rolled forward upstream by the time of testing; hit one
unrelated `hid_report_raw_event()` ABI mismatch from that version skew,
not from this change. The actual pipeline always pairs a kernel build
with its own matching source tag, so this does not apply in CI.)

## Wi-Fi vendor coverage: known gap, not fixed here

Checked `/boot/config-*` on this box: `CONFIG_WLAN_VENDOR_ATH` /
`_REALTEK` / `_MEDIATEK` / `_BROADCOM` are all absent from the kernel
build - only Intel `iwlwifi` (via `azurelinux-desktop-intel-kmod`) is
covered today. This matters most for MediaTek (`mt76`/`mt7921e`),
which several newer ThinkPad configurations (T14 Gen 3+, X1 Carbon Gen
10+, and others) ship as the default or budget Wi-Fi option instead of
Intel. `CONFIG_CFG80211`/`CONFIG_MAC80211` are already `=m` in-tree, so
a vendor kmod could reuse the exact same out-of-tree recipe pattern
`intel-kmod` already uses for `iwlwifi` - copy the vendor driver
directory, force the right `CONFIG_*` defines, build against stock
cfg80211/mac80211.

This wasn't built in this pass on purpose: unlike `hid-multitouch.c`
(one self-contained file), `mt76` is a shared core library plus several
per-chip modules (PCI/USB/SDIO variants, MCU firmware handling,
calibration/EEPROM paths) with more surface area to get wrong sight
unseen, and this hardware doesn't have a MediaTek card to runtime-test
against. Left as a follow-up for whenever there's real hardware (or
more time) to validate it against, rather than shipping something
compile-tested only. Realtek (`rtw88`/`rtw89`) and Qualcomm
(`ath10k`/`ath11k`) would follow the same pattern after that.

Audio and Bluetooth were checked too and don't need anything: Bluetooth
already covers Intel/Realtek/Broadcom/MediaTek helpers
(`azurelinux-desktop-bluetooth-kmod`), and this box's audio works fine
over both HDA and Bluetooth. Newer Intel platforms using SOF/SoundWire
instead of legacy HDA are a separate, larger gap
(`CONFIG_SND_SOC*`/`CONFIG_SOUNDWIRE*` are absent kernel-wide) that
doesn't affect Skylake-class hardware like this T470s; also deferred,
same reasoning as the Wi-Fi vendor gap.

## Broader consumer/workstation hardware pass

Went looking for more "simple, common, generic" gaps beyond ThinkPad-
specific hardware, using the real `ghcr.io/sirredbeard/azurelinux-
desktop/build-kmods` container plus a matching installed `kernel-devel`
to compile-test candidates before writing anything into the build
script. Also confirmed something that didn't need fixing:
`azurelinux-desktop-policy`'s `Requires:` list is already generated
from whichever families actually produced a `.ko` in a given build
(`append_requires` inside each family's `if pkg_enabled ...` block), so
adding a new package to the pipeline is enough on its own - policy
picks it up automatically, no separate wiring needed.

New packages added, all compile-verified against real matching
`kernel-devel-6.18.31-1.16.azl4.x86_64`:

* `azurelinux-desktop-touchpad-kmod` - `rmi_core.ko`/`rmi_i2c.ko`
  (Synaptics RMI4 over plain I2C, not the SMBus path `psmouse-kmod`
  covers) and `elan_i2c.ko` (native ELAN I2C touchpad). Common on
  Dell/HP/ASUS/Acer laptops and some ThinkPads.
* `azurelinux-desktop-logitech-kmod` - `hid-logitech-dj.ko` +
  `hid-logitech-hidpp.ko` for the Logitech Unifying receiver and
  HID++ wireless/Bluetooth mice and keyboards. Very common on both
  home and enterprise desks; without it these fall back to generic
  HID and lose battery reporting and extra buttons/DPI.
* `azurelinux-desktop-hid-quirks-kmod` - `hid-asus.ko` (extra keys,
  keyboard backlight, touchpad quirks on ASUS laptops) and
  `hid-elan.ko` (ELAN touchpads over USB/HID instead of native I2C).

Followed up with a second pass looking specifically for common
consumer peripherals plugged in over USB, since ethernet-as-fallback
came up as valuable separately from the Wi-Fi vendor gap above:

* `azurelinux-desktop-usbeth-kmod` - `r8152.ko` (Realtek RTL8152/8153,
  the chip in nearly every USB-C dock/hub sold today), `asix.ko`
  (older ASIX AX8817X, needs its `ax88172a.o` object bundled in too),
  and `ax88179_178a.ko` (newer, more common ASIX USB3 gigabit chipset,
  a separate module from `asix.ko`). `CONFIG_USB_USBNET` and
  `CONFIG_USB_NET_CDCETHER` were already stock; these three standalone
  chip drivers were the real gap.
* `azurelinux-desktop-gamepad-kmod` - `xpad.ko` (wired Xbox
  controllers), `hid-sony.ko` (PS3/PS4 DualShock), and
  `hid-playstation.ko` (PS5 DualSense) plus `led-class-multicolor.ko`,
  a small (~200 line) standalone LED class helper DualSense's
  lightbar/mic-mute LED needs - confirmed this one is a genuinely tiny
  self-contained file, not a hidden subsystem gap like MMC or IIO
  below. `CONFIG_HID_STEAM` was already stock; these three families
  cover the other common consumer controllers.

Two more candidates looked promising but turned out to need a whole
missing kernel subsystem, not just a driver, so they're deferred:

* USB SD/MS card readers (`rtsx_usb` + `rtsx_usb_sdmmc` +
  `rtsx_usb_ms`, common OEM laptop hardware): the host driver itself
  builds fine, but `CONFIG_MMC` and `CONFIG_MEMSTICK` are both
  completely absent kernel-wide - no core `mmc_core`/`mmc_block` at
  all, not just the USB host glue. Shipping just the host driver would
  be useless; this needs the whole MMC/Memstick core stack built OOT
  too, a much bigger lift than a single driver.
* HID sensor hub accel/ALS/gyro (`hid-sensor-*`, used on 2-in-1s and
  convertibles): same shape of problem - `CONFIG_IIO` (Industrial I/O
  framework) is entirely absent, so there's no buffer/trigger core for
  these drivers to plug into. Deferred for the same reason as MMC.

Everything else checked in this pass (Intel/AMD platform drivers,
generic ACPI, DRM/i915/amdgpu, USB xHCI/UAS/mass-storage, Type-C/UCSI)
was already covered, either in-tree (`=m`/`=y` in the stock config) or
by an existing OOT package (`typec-kmod`, `storage-kmod`). USB2-only
EHCI host controllers were skipped as legacy/niche.

One unrelated bug found along the way, filed separately (issue #31):
the kmod build script's `prepare_source()` looks up an exact kernel
source tarball entry by version, but upstream's `rolling-lts` git tags
move forward over time and can roll out from under whatever
`kernel-devel` azl-base currently serves. Currently dormant (recent
scheduled runs are no-op), but will break the next real rebuild if the
two drift apart before then.


## Round 3: sound/Intel re-check, IdeaPad/Dell/ASUS platforms, shared battery hook, AMD SMBus

Re-surveyed sound codecs and Intel platform drivers against the stock
kernel config looking for more low-effort gaps. Found nothing new worth
adding:

* Sound: `SND_HDA_CODEC_CIRRUS`/`CS8409`/`CS35L41` need firmware for the
  smart-amp path; the bigger `SND_SOC`/SOF ASoC stack is a whole missing
  framework, not a driver, same shape of problem as MMC/IIO above.
  Niche USB audio gear deferred as low value.
* Intel: everything worth having (`ISH_HID`, `PMC_CORE`, `RAPL`,
  `HID_EVENT`, `VBTN`) is already `=m` in stock. `IPU6`/`ivsc` (MIPI
  camera) and `ISHTP_ECLITE` need firmware blobs, out of scope.

Vendor platform drivers were a real gap though.
`IDEAPAD_LAPTOP`/`LENOVO_YMC` and `ASUS_WMI`/`ASUS_NB_WMI` and
`DELL_LAPTOP` are all **not set** in stock, and all confirmed blob-free
(checked every `request_firmware()` call site in each driver against
upstream v6.18 source - zero hits in any of the five files). Compiled
all five clean against the real matching AZL `kernel-devel`:
`ideapad-laptop.ko`, `ymc.ko`, `dell-laptop.ko`, `asus-wmi.ko`,
`asus-nb-wmi.ko`.

Package placement, per user direction: IdeaPad/Yoga folds into the
existing `azurelinux-desktop-thinkpad-kmod` (same Lenovo platform
family), Dell and ASUS get their own new packages.

All five share one non-obvious dependency: `CONFIG_ACPI_BATTERY`'s
`battery_hook_register()`/`devm_battery_hook_register()`. Stock AZL
has the whole ACPI battery subsystem off (confirmed on both the
container's kernel-devel config and the host's real
`/boot/config-*.azl4.x86_64` - `# CONFIG_ACPI_BATTERY is not set`).
This project's `thinkpad-kmod` already builds `battery.ko` OOT for
`thinkpad_acpi` itself, so the host's working battery status was never
a stock-kernel feature to begin with.

Since `.github/workflows/publish-desktop-kmods.yml`'s family matrix
runs each family in its own isolated CI job (no shared `WORKDIR` or
`Module.symvers` across jobs), a driver in one family can't link
against another family's build output at CI time. Rather than
special-casing job ordering/artifacts, extracted the shared hook into
its own foundational package, `azurelinux-desktop-acpi-battery-kmod`
(ships the one canonical `battery.ko`). `thinkpad`, `dell`, and `asus`
each privately rebuild their own throwaway, unshipped copy of the tiny
(~40KB) `battery.c` purely for link-time symbol resolution inside
their own isolated job, then `Requires: azurelinux-desktop-acpi-battery-kmod`
for the real runtime module.

`asus-wmi.c` needed one build fix: kernel-devel's stub header
(`include/linux/platform_data/x86/asus-wmi.h`) guards its real-vs-stub
declarations with `IS_REACHABLE(CONFIG_ASUS_WMI)`; without that macro
defined the stub branch's inline functions collide (redefinition
errors) with `asus-wmi.c`'s own real definitions. Fixed with
`-DCONFIG_ASUS_WMI_MODULE=1`.

Also checked whether a standalone `azurelinux-desktop-amd-kmod` is
warranted (parallel to `intel-kmod`'s iwlwifi). Stock AZL is already
comprehensive here: `AMD_PMC`, `AMD_PMF`, `AMD_HSMP`, `SENSORS_K10TEMP`,
`EDAC_AMD64`, the full `DRM_AMDGPU`/`DRM_AMD_DC`/`DRM_AMD_ACP` GPU
stack, `X86_AMD_PSTATE`, `AMD_MEM_ENCRYPT`, `CRYPTO_DEV_CCP`,
`AMD_IOMMU`, `GPIO_AMD_FCH`, and `I2C_AMD_MP2` are all already `=m`/`=y`
in-tree. No new AMD package needed. Two things worth noting but not
adding: `PINCTRL_AMD` is a `bool`-only Kconfig option upstream (not
`tristate`), so it cannot be built as a loadable OOT module at all -
would need a kernel rebuild, out of scope. `CONFIG_SENSORS_ZENPOWER` is
not an upstream symbol at all (zenpower is a community OOT project,
never merged) - stock leaving it unset is correct, not a gap.

One real, concrete AMD gap did turn up: `CONFIG_I2C_PIIX4` (the SMBus
host controller for AMD, and legacy Intel PIIX4/ATI/Broadcom/
Serverworks chipsets) is not set in stock. This matters because
`rmi_smbus` (already shipped in `psmouse-kmod`, see
`findings/thinkpad-two-finger-scroll-rmi-smbus.md`) only binds if an
SMBus adapter is already registered - stock AZL ships Intel's
`i2c-i801` in-tree, which is the only reason the ThinkPad SMBus
handoff already works. An AMD laptop with the same Synaptics
InterTouch pad would stay stuck in relative PS/2 mode with no adapter
to hand off to, the exact failure this whole family exists to fix.
Added `i2c-piix4.ko` + its `i2c-smbus.ko` dependency into `psmouse-kmod`
(built alongside `rmi_core`/`rmi_smbus` in the same family, only when
RMI4 sources are present) - both compile clean against the real
matching `kernel-devel`, PCI-only, no firmware.

Surveyed `azurelinux-desktop-surface-kmod` against the full upstream
`drivers/platform/surface/*.c` and `drivers/hid/surface-hid/*.c` file
lists (v6.18): already 100% covered, every upstream file in both
directories is already built. `ithc`/`ipts` (newer Surface touchscreen
controllers) have no mainline driver yet - still an out-of-tree
community project, correctly out of scope.

Checked fwupd separately (not a kmod gap): already installed and
working end-to-end on bare metal via the existing Fedora-sourced
package this project already ships. `fwupdmgr get-devices` lists real
hardware (System Firmware/ESRT, CPU, NVMe, dock hubs, Intel AMT);
`efivarfs`/ESRT are mounted and populated. The ~13 plugins showing
`Disabled` in `fwupdmgr get-plugins` are all expected (no matching
hardware present, server/BMC-only plugins like `redfish`/`amd_kria`,
manual-enable-only like `flashrom`, or test-only plugins) - no gap
found.

## Round 4: performance/scheduling/UEFI/MEI survey, four more vendor platform drivers

Surveyed thermal, vendor BIOS/platform, ACPI, performance/scheduling,
Intel MEI ("IMEI"), and UEFI config against the stock kernel looking
for more low-effort in-tree gaps.

Performance/scheduling, UEFI, and Intel MEI are already comprehensive
in stock: `X86_INTEL_PSTATE`/`X86_AMD_PSTATE`, every `CPU_FREQ_GOV_*`,
`SCHED_MC`/`SCHED_CLUSTER`/`SCHED_SMT`, `ENERGY_MODEL`,
`INTEL_TURBO_MAX_3`, `X86_SGX`, `NO_HZ_FULL`, `CPU_IDLE_GOV_TEO`,
`INTEL_IDLE` are all on. `EFI`, `EFIVAR_FS`, `EFI_ESRT`,
`EFI_CAPSULE_LOADER`, `UEFI_CPER` are all on (matches the separate
fwupd check above - this is why capsule/ESRT updates already work).
`INTEL_MEI`/`INTEL_MEI_ME`/`INTEL_MEI_GSC`/`INTEL_MEI_HDCP`/
`INTEL_MEI_PXP`/`INTEL_MEI_VSC` are all already `=m`. The only unset
items in these three areas (`PREEMPT_DYNAMIC`, `HZ_1000`, `MEI_WDT`)
are whole-kernel compile-time policy choices, not OOT-buildable
drivers - same class of blocker as `PINCTRL_AMD` above, out of scope.

Thermal is also already comprehensive: `INT340X_THERMAL`,
`INT3406_THERMAL`, `X86_PKG_TEMP_THERMAL`, `INTEL_SOC_DTS_THERMAL`,
`INTEL_HFI_THERMAL` are all on. (Earlier grep for a nonexistent
`CONFIG_ACPI_INT3403_THERMAL` symbol was a false lead - current
mainline handles INT3400-340B inside `int340x_thermal` itself, no
separate Kconfig knob.)

Vendor BIOS/platform drivers turned up four more real gaps, all
depending on the same `ACPI_BATTERY` hook this project already solved
for thinkpad/dell/asus (`azurelinux-desktop-acpi-battery-kmod`),
all confirmed blob-free (zero `request_firmware()` calls) and compiled
clean on the first try against the real matching `kernel-devel`, no
extra local headers needed unlike asus-wmi/dell-laptop:

* `azurelinux-desktop-huawei-kmod` - `huawei-wmi.ko` (Huawei MateBook
  hotkeys/fn-lock/mic-mute LED)
* `azurelinux-desktop-system76-kmod` - `system76_acpi.ko` (System76
  laptop Fn keys/keyboard backlight/airplane LED)
* `azurelinux-desktop-samsung-kmod` - `samsung-laptop.ko` (Samsung
  function keys/wireless LED/backlight)
* `azurelinux-desktop-fujitsu-kmod` - `fujitsu-laptop.ko` (Fujitsu
  Lifebook hotkeys/backlight)

Verified their other runtime dependencies (`LEDS_CLASS`, `NEW_LEDS`,
`LEDS_TRIGGERS`, `BACKLIGHT_CLASS_DEVICE`, `RFKILL`, `HWMON`,
`INPUT_SPARSEKMAP`, `ACPI_VIDEO`, `ACPI_EC`, `ACPI_WMI`) are all
already in-tree, so these load and function, not just link.

## Round 5 - Wacom/UC-Logic/Waltop tablets, transport and legacy checks

Checked I2C-HID transport (`I2C_HID`, `I2C_HID_ACPI`, `I2C_HID_OF`) -
already `=m` in stock, confirming the transport under the already-
shipped `hid-multitouch.ko` (protocol driver) works end to end without
any further OOT work.

Found a real gap in drawing-tablet support: `HID_WACOM`, `HID_UCLOGIC`,
`HID_WALTOP` are all NOT SET in stock. These cover Wacom Intuos/Bamboo/
Cintiq (USB and Bluetooth), Huion/UC-Logic, and Waltop tablets and pen
displays - common consumer/creative peripherals. Only depend on
`USB_HID` (already in via usbhid) plus `POWER_SUPPLY`/`LEDS_CLASS`/
`LEDS_TRIGGERS` (already in-tree), no firmware blobs.

Compiled `wacom.ko` (from `wacom_wac.c` + `wacom_sys.c`, no separate
`wacom.c` - upstream builds it purely as `wacom-y := wacom_wac.o
wacom_sys.o`), `hid-uclogic.ko` (`hid-uclogic-core.c` +
`hid-uclogic-rdesc.c` + `hid-uclogic-params.c`), and `hid-waltop.ko`
(single file) against the real matching `kernel-devel` in a fresh
podman build container. `hid-uclogic-core.c` needed two local headers
not present in kernel-devel - `usbhid/usbhid.h` and `hid-ids.h` - both
already staged elsewhere in this project (surface/hidquirks stages) via
the same "copy from the kernel source tree" pattern. All three modules
compiled clean once those headers were staged. Added new
`azurelinux-desktop-tablet-kmod` package (no ACPI-battery dependency,
this family doesn't touch battery hooks).

Checked legacy touchscreen drivers (`TOUCHSCREEN_ELAN`, `GOODIX`,
`SILEAD`, `ATMEL_MXT`) - all NOT SET, but mostly need firmware blobs or
are superseded on modern hardware by the HID multitouch path already
shipped. Not pursued.

Checked ACPI button/lid/fan (`ACPI_BUTTON`, `ACPI_FAN`, `ACPI_VIDEO`,
`ACPI_PROCESSOR`) - already `=y`/`=m`. `ACPI_CPUFREQ` NOT SET is
correct and expected (superseded by intel_pstate/amd_pstate).

Checked Super I/O hwmon (`SENSORS_NCT6775`, `IT87`, `W83627HF`,
`F71805F`, `DELL_SMM`) - all already `=m` in stock, a pleasant
surprise - common desktop-motherboard fan/voltage sensors need no OOT
work at all.

## Round 6 - server-vs-desktop kernel gaps: filesystems, USB, GPU/dock

Surveyed categories a server-oriented kernel config commonly turns off
but a workstation/laptop desktop needs on: filesystems, USB storage/
serial, cameras/mics, HDMI/DRM, docks, KVM switches, in-tree GPU.

Filesystems (exFAT, NTFS3, VFAT, MSDOS, UDF, HFS/HFS+, ISO9660,
overlayfs, XFS, Btrfs, F2FS) are already comprehensive in stock -
covers reading/writing removable media and disk images from any OS.
No gap.

USB mass storage (`usb-storage`/`uas`), full ALSA/HDA/USB-audio
(including HDMI audio codecs), and UVC webcams are NOT SET in stock
AZL but are **already covered** by this project's existing `storage`,
`sound`, and `uvc` OOT families (predates this round) - re-verified
they're wired correctly, no changes needed.

HDMI CEC is already comprehensive (`CEC_CORE`, i915's built-in HDMI
CEC via `DRM_DISPLAY_HDMI_CEC_NOTIFIER_HELPER`, plus USB CEC adapters
like Pulse-Eight). Thunderbolt/USB4 docks are already covered by stock
`CONFIG_USB4=m` (modern kernels fold Thunderbolt into the USB4
subsystem). DP MST helper is a bool selected transitively by DRM
drivers (i915/amdgpu), not a standalone OOT-buildable Kconfig item -
out of scope, same class as `PINCTRL_AMD`.

Found two real gaps, both compile-verified against the real matching
`kernel-devel`:

* **`azurelinux-desktop-usbserial-kmod`** (new) - stock AZL has no
  `USB_SERIAL` at all. Added `usbserial.ko` (`usb-serial.c` + `bus.c` +
  `generic.c` - `bus.c` is easy to miss, `usb_serial_bus_register()`/
  `usb_serial_bus_type` live there, not in `usb-serial.c`) plus
  `ftdi_sio.ko` (needs local `ftdi_sio_ids.h`), `cp210x.ko`,
  `pl2303.ko`, `ch341.ko` - the four chips behind most consumer
  USB-serial cables/adapters (Arduino, GPS mice, some docks and KVM
  switch config/firmware ports). No firmware blobs, only depends on
  stock `TTY`.
* **`azurelinux-desktop-udl-kmod`** (new) - stock AZL has no
  `DRM_UDL`. Added `udl.ko` for USB-attached DisplayLink video
  adapters, common on docking stations and multi-monitor USB hubs that
  lack native DisplayPort/HDMI passthrough. Only depends on stock DRM
  helpers (`DRM_GEM_SHMEM_HELPER`, `DRM_KMS_HELPER`, both already
  `=y`). Compiled clean on the first try, no extra headers needed.

Simple non-NVIDIA in-tree GPU drivers for older/virtual hardware
(`DRM_VMWGFX`, `DRM_GMA500`, `DRM_AST`, `DRM_QXL`, `DRM_VIRTIO_GPU`)
are already all `=m` in stock - covers VMware/QEMU/virt guests and
Aspeed BMC-class server graphics without any OOT work.
