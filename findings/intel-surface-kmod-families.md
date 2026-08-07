# Intel + Surface kmod families (rename iwlwifi, add surface)

**Status:** implemented in tree; publish via Pages for live packages

**Constraint:** upstream / CBL-Mariner sources only. No linux-surface out-of-tree fork.

## Host probe (ThinkPad-class metal)

* HD Graphics 520 - `i915` from stock `kernel-modules` (`CONFIG_DRM_I915=m`)
* Xe path - stock `xe` (`CONFIG_DRM_XE=m`, unused on SKL)
* Wireless 8260 - `iwlwifi` + `iwlmvm` from **OOT** `azurelinux-desktop-intel-kmod`
* HDA ALC - `snd-hda-intel` + codecs from **OOT** sound-kmod
* BT USB - `btusb` + `btintel` from **OOT** bluetooth-kmod
* thinkpad extras - thinkpad_acpi + battery + privacy-screen from **OOT** thinkpad-kmod
* Type-C UCSI - typec / ucsi_acpi from **OOT** typec-kmod
* think-lmi, intel-hid, i2c-i801, thunderbolt, e1000e, mei - stock `kernel-modules{,-extra}`

ThinkPad gap check on this host: no extra OOT thinkpad modules beyond thinkpad-kmod. Stock AZL already enables THINKPAD_LMI, INTEL_HID_EVENT, I2C_I801, INTEL_WMI_THUNDERBOLT, and similar.

## Package rename

Old `azurelinux-desktop-iwlwifi-kmod` -> `azurelinux-desktop-intel-kmod`.

Family stage name `intel` (legacy stage `iwlwifi` still accepted). RPM Provides/Obsoletes the old name. Policy pulls the new name.

### What intel-kmod ships

* `iwlwifi.ko`, `iwlmvm.ko`, `iwldvm.ko`, `iwlmld.ko` (CONFIG_WLAN still off on AZL)

### What intel-kmod does not rebuild

* `CONFIG_DRM_I915` / `CONFIG_DRM_XE` - already `=m` in stock; full DRM OOT is fragile and redundant
* `CONFIG_SND_HDA_INTEL` - already in sound-kmod
* `CONFIG_BT_INTEL` - already in bluetooth-kmod (`btintel.ko`)
* `CONFIG_SND_SOC_SOF_INTEL_*` - large ASoC/SOF graph; deferred. Skylake-class and many Surfaces still use the HDA path

## New package: `azurelinux-desktop-surface-kmod`

Upstream-only Surface support. Stock AZL has:

```
# CONFIG_SURFACE_PLATFORMS is not set
# CONFIG_SERIAL_DEV_BUS is not set
# CONFIG_HID_MICROSOFT is not set
# CONFIG_HID_MULTITOUCH is not set
```

Built from the matching kernel source tarball:

* serdev - `serdev.ko`
* SSAM core - `surface_aggregator.ko` (with bus)
* SSAM clients - registry, hub, cdev, tabletsw, dtx, gpe, hotplug, platform_profile, acpi_notify, surfacepro3_button, surface3_power, surface3-wmi, and similar when present
* HID - `hid-microsoft.ko`, `hid-multitouch.ko`, plus `surface_hid*` / `surface_kbd` when present in tree

User-facing Kconfig names map as:

* `CONFIG_SURFACE_AGGREGATOR_TABLET_MODE` -> upstream `SURFACE_AGGREGATOR_TABLET_SWITCH`
* FAN/POWER style support -> `SURFACE_PLATFORM_PROFILE`, `SURFACE_3_POWER_OPREGION`, battery via registry/hub
* `CONFIG_SURFACE_AGGREGATOR_HID` -> `SURFACE_HID` / `SURFACE_KBD` + HID under `drivers/hid/surface-hid/`

## Image / CI wiring

* `publish-desktop-kmods.yml` full set includes `intel` + `surface`. Detect treats missing intel or leftover-only iwlwifi as incomplete.
* Policy Requires every sibling RPM present after package merge.
* Live / installer still install **`azurelinux-desktop-policy` only**.
* Canary asserts intel + surface module paths and package names.

## Build note (HID / BTF)

CI once failed on `hid-microsoft.c: hid-ids.h: No such file`. Fix: copy `hid-ids.h` / `hid-haptic.h` and stage `include/linux/surface_aggregator` from the kernel tarball. BTF "Skipping … vmlinux" is harmless. No vmlinux required. See `surface-hid-oot-build.md`.

## Validation

1. Dispatch `publish-desktop-kmods` with `republish=true` when forcing a full set.
2. Confirm Pages manifest has `azurelinux-desktop-intel-kmod-*.rpm` and `azurelinux-desktop-surface-kmod-*.rpm`.
3. Canary: `dnf install kernel azurelinux-desktop-policy` resolves both siblings.
4. Metal ThinkPad: Wi-Fi/BT/HDA still from `extra/azurelinux-desktop`.
5. Surface hardware when available: SSAM devices enumerate; Type Cover HID binds.

## Follow-ups

* Optional SOF Intel family if newer Surfaces need DSP audio beyond HDA.
* Drop residual `azurelinux-desktop-iwlwifi-kmod` RPMs from Pages after a full publish (merge logic already skips when intel is present).

Related: `kmod-family-expansion-stock-vs-oot.md`, `out-of-tree-usb-kmods-pages.md`, `wifi-missing-on-bare-metal.md`.
