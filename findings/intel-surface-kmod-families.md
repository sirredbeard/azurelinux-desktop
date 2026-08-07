# Intel + Surface kmod families (rename iwlwifi, add surface)

**Status:** implemented in tree; Pages rebuild required for live packages.  
**Constraint:** upstream / CBL-Mariner sources only — no linux-surface out-of-tree fork.

## Host probe (ThinkPad T470s, this metal)

| Device | Driver | Source |
| --- | --- | --- |
| HD Graphics 520 | `i915` | stock `kernel-modules` (`CONFIG_DRM_I915=m`) |
| Xe path | `xe` | stock (`CONFIG_DRM_XE=m`, unused on SKL) |
| Wireless 8260 | `iwlwifi` + `iwlmvm` | **OOT** `azurelinux-desktop-intel-kmod` |
| HDA ALC | `snd-hda-intel` + codecs | **OOT** `azurelinux-desktop-sound-kmod` |
| BT USB | `btusb` + `btintel` | **OOT** `azurelinux-desktop-bluetooth-kmod` |
| thinkpad extras | `thinkpad_acpi` + battery + privacy-screen | **OOT** thinkpad-kmod |
| Type-C UCSI | `typec` / `ucsi_acpi` | **OOT** typec-kmod |
| think-lmi, intel-hid, i2c-i801, thunderbolt, e1000e, mei | stock modules | `kernel-modules{,-extra}` |

**ThinkPad gap check:** no additional OOT thinkpad modules required on this host
beyond the existing `thinkpad-kmod` trio. Stock AZL already enables
`THINKPAD_LMI`, `INTEL_HID_EVENT`, `I2C_I801`, `INTEL_WMI_THUNDERBOLT`, etc.

## Package rename

| Old | New |
| --- | --- |
| `azurelinux-desktop-iwlwifi-kmod` | `azurelinux-desktop-intel-kmod` |
| family stage `iwlwifi` | `intel` (legacy stage name still accepted) |

RPM `Provides`/`Obsoletes` the old name for upgrades. Policy pulls the new name.

### What intel-kmod ships

- `iwlwifi.ko`, `iwlmvm.ko`, `iwldvm.ko`, `iwlmld.ko` (CONFIG_WLAN still off on AZL)

### What intel-kmod does *not* rebuild (and why)

| Symbol / area | Why not OOT here |
| --- | --- |
| `CONFIG_DRM_I915` / `CONFIG_DRM_XE` | Already `=m` in stock AZL; full DRM OOT is fragile and redundant |
| `CONFIG_SND_HDA_INTEL` | Already in `azurelinux-desktop-sound-kmod` |
| `CONFIG_BT_INTEL` | Already in `azurelinux-desktop-bluetooth-kmod` (`btintel.ko`) |
| `CONFIG_SND_SOC_SOF_INTEL_*` | Large ASoC/SOF graph; deferred. Skylake-class + many Surfaces use HDA path today |

## New package: `azurelinux-desktop-surface-kmod`

Upstream-only Surface support forced on because stock AZL has:

```text
# CONFIG_SURFACE_PLATFORMS is not set
# CONFIG_SERIAL_DEV_BUS is not set
# CONFIG_HID_MICROSOFT is not set
# CONFIG_HID_MULTITOUCH is not set
```

Built from the matching kernel source tarball:

| Area | Modules (representative) |
| --- | --- |
| serdev | `serdev.ko` |
| SSAM core | `surface_aggregator.ko` (with bus) |
| SSAM clients | registry, hub, cdev, tabletsw, dtx, gpe, hotplug, platform_profile, acpi_notify, surfacepro3_button, surface3_power, surface3-wmi |
| HID | `hid-microsoft.ko`, `hid-multitouch.ko`, plus `surface_hid*` / `surface_kbd` when present in tree |

User-facing Kconfig names map as:

- `CONFIG_SURFACE_AGGREGATOR_TABLET_MODE` → upstream `SURFACE_AGGREGATOR_TABLET_SWITCH`
- “FAN/POWER” style support → `SURFACE_PLATFORM_PROFILE`, `SURFACE_3_POWER_OPREGION`, battery via registry/hub (not separate FAN kconfig)
- `CONFIG_SURFACE_AGGREGATOR_HID` → `SURFACE_HID` / `SURFACE_KBD` + HID core under `drivers/hid/surface-hid/`

## Image / CI wiring

- `publish-desktop-kmods.yml` full set includes `intel` + `surface`; detect treats missing intel or leftover-only iwlwifi as incomplete.
- Policy Requires every sibling RPM present after package merge.
- Live / installer still install **`azurelinux-desktop-policy`** only (pulls siblings).
- Canary `test-canary-container.sh` asserts intel + surface module paths and package names.

## Validation

1. Dispatch `publish-desktop-kmods` with `republish=true`.
2. Confirm Pages manifest has `azurelinux-desktop-intel-kmod-*.rpm` and `azurelinux-desktop-surface-kmod-*.rpm` (no need for iwlwifi name).
3. Canary: `dnf install kernel azurelinux-desktop-policy` resolves both new siblings.
4. Metal ThinkPad: Wi-Fi/BT/HDA unchanged; `modinfo iwlwifi` still from `extra/azurelinux-desktop`.
5. Surface hardware (when available): SSAM devices enumerate; Type Cover HID binds.

## Follow-ups

- Optional SOF Intel family if newer Surfaces need DSP audio beyond HDA.
- Drop any residual `azurelinux-desktop-iwlwifi-kmod` RPMs from Pages after one full publish cycle (merge logic already skips when intel is present).
