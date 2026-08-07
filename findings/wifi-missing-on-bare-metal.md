# WiFi missing on bare-metal Azure Linux Desktop install

**Status:** Confirmed fixed on bare metal (2026-08-06). The published
`azurelinux-desktop-iwlwifi-kmod` for `6.18.31-1.12.azl4` works on the
ThinkPad: `wlp58s0` comes up and NetworkManager connects (`iwlwifi` +
`iwlmvm` from `/lib/modules/*/extra/azurelinux-desktop/`). Earlier state:
addressed by iwlwifi OOT kmod, needed metal re-check after kernel bumps.

Observed 2026-08-02 on dual-boot nested install (`host container partition`) on a laptop
with Intel Wireless-AC 8260. Desktop booted; Settings showed no WiFi device.

## Host hardware (works under Fedora)

| Piece | Detail |
| --- | --- |
| WiFi PCI | `3a:00.0` Intel Wireless 8260 `[8086:24f3]` rev 3a |
| Subsystem | Dual Band Wireless-AC 8260 `[8086:0010]` |
| Fedora driver | `iwlwifi` + `iwlmvm` |
| Fedora iface | `wlp58s0` (connected) |
| Fedora firmware | `iwlwifi-8000C-36.ucode` from **`iwlwifi-mvm-firmware`** |
| Fedora module pkg | `iwlwifi.ko` in **`kernel-modules`** (Fedora packaging) |
| Also present | Intel Bluetooth `8087:0a2b`; Sierra EM7455 WWAN (unused here) |
| Wired | Intel e1000e `enp0s31f6` (no cable in test) |

## What the project config installs (intent)

Installer/live policy already tries to make WiFi *userspace* work:

- `NetworkManager` enabled
- **Installer (`kiwi/config.sh`)**: explicit `NetworkManager-wifi`, `wpa_supplicant`, `linux-firmware`
- **Live kickstart**: `NetworkManager`, explicit `linux-firmware` (NM-wifi/wpa often as weak deps on live path)
- Fedora is blocked from supplying `NetworkManager*`, `linux-firmware`, and many `*-firmware` packages so AZL owns them

That is enough for NM to *manage* WiFi **if a wlan interface exists**. It is
not enough to create the interface on this hardware.

## What the installed system actually had

| Component | Status on Azure Linux install |
| --- | --- |
| `NetworkManager` 1.54.3 azl4 | installed, enabled, started |
| `NetworkManager-wifi` | installed; plugin loaded |
| `wpa_supplicant` (Fedora 43) | installed; started when NM needed it |
| `linux-firmware` azl4 | installed |
| Split firmware pkgs | **not installed** (`iwlwifi-mvm-firmware` etc. exist in AZL repo) |
| `kernel` / `kernel-modules` / `kernel-modules-core` | installed |
| `kernel-modules-extra` | **not installed** (exists in AZL repo) |
| `iwlwifi.ko` / `iwlmvm.ko` | **absent** from `/lib/modules/...` |
| `cfg80211` / `mac80211` | present only |
| `/lib/firmware/iwlwifi-8000C*` | **absent** |
| Journal | PCI `8086:24f3` enumerated; **no iwlwifi bind**; NM only creates `lo` + `enp0s31f6` |

Bare-metal journal excerpt pattern:

- `pci 0000:3a:00.0: [8086:24f3] ... class 0x028000`
- NM: Wi-Fi radio enabled, `NMWifiFactory` loaded
- NM: new Ethernet `enp0s31f6` only — **never a wifi device**
- No `iwlwifi: loaded firmware` lines (contrast Fedora host dmesg)

## Root cause (two missing pieces)

1. **Kernel driver not packaged into the installed module set**  
   AZL’s `kernel-modules` does **not** ship Intel WiFi drivers (no
   `drivers/net/wireless/intel/iwlwifi`). Those live in **`kernel-modules-extra`**,
   which the kickstart never lists. Fedora puts `iwlwifi` in plain
   `kernel-modules`, so “install kernel-modules” is not portable across the
   two packaging layouts.

2. **Intel WiFi firmware not in the installed firmware set**  
   AZL splits firmware like Fedora. Meta/`linux-firmware` on the install does
   **not** contain `iwlwifi-8000C-*.ucode`. The 8260 needs
   **`iwlwifi-mvm-firmware`** (confirmed on the host: that package owns
   `8000C-36`). Azure Linux base repo ships `iwlwifi-mvm-firmware`,
   `iwlwifi-dvm-firmware`, `iwlwifi-mld-firmware`, `iwlegacy-firmware`, but
   none were pulled in.

Userspace was fine. The radio never got a driver or firmware, so GNOME had
nothing to show.

## Secondary note

Both `NetworkManager` and `systemd-networkd` were enabled on the install.
That did not block WiFi here (no wlan device existed), but it is still a
parity/noise issue vs the live kickstart policy (“NetworkManager only”).

## Fix direction (product) — applied

Added to live kickstarts, installer offline package list (`kiwi/config.sh`),
and installer environment (`kiwi/azl-desktop-installer.kiwi`):

- `kernel-modules-extra`
- `iwlwifi-mvm-firmware`
- `iwlwifi-dvm-firmware`
- `iwlwifi-mld-firmware`
- `iwlegacy-firmware`

Also appended the four `iwl*`-firmware names to `FEDORA_EXCLUDES` / Fedora
`excludepkgs` so AZL keeps owning that firmware set.

Rebuild live ISO + installer ISO via release workflows after this lands.
Bare-metal retest: expect `iwlwifi` bind and a `wlp…` device in NM.

## Verified on release `2026.08.02`

Package lists refreshed from that release:

- Live: `findings/live-package-list.txt` from the ISO rootfs
  `var/log/azl-desktop-package-list.txt` (1180 packages). Includes
  `kernel-modules-extra-6.18.31-1.9.azl4` and the four `iwl*`-firmware
  packages plus `NetworkManager-wifi`.
- Installer runtime: `findings/installer-package-list.txt` from Actions
  artifact on run `30767991891`. Includes the same kernel-modules-extra
  and iwlwifi firmware set (installer list is the install environment,
  not the full offline desktop target).

Nested reinstall to `host container partition` with the post-kmod installer completed
2026-08-02 evening. Firmware RPMs and `kernel-modules-extra` are on the
nested root. **Wi-Fi still cannot work** until the kernel grows WLAN
drivers (see below).

## Correction after nested reinstall (2026-08-02)

The earlier “put drivers in `kernel-modules-extra`” story matched Fedora
packaging intuition. On **Azure Linux 4.0 x86_64** it is wrong.

From the installed nested kernel config
(`/usr/lib/modules/6.18.31-1.9.azl4.x86_64/config`):

```
CONFIG_CFG80211=m
CONFIG_MAC80211=m
# CONFIG_WLAN is not set
```

With `CONFIG_WLAN` off, there is no `CONFIG_IWLWIFI`, no `iwlwifi.ko`,
and AZL’s `kernel-modules-extra` only ships a small unrelated set (can,
ocfs2, tcp congestion, usbip, … — 58 files). Confirmed on the nested
root after install:

| Piece | Present? |
| --- | --- |
| `kernel-modules-extra` RPM | yes |
| `iwlwifi-mvm-firmware` (and siblings) | yes (`iwlwifi-8000C-*.ucode.xz` on disk) |
| `iwlwifi.ko` / `iwlmvm.ko` anywhere under `/usr/lib/modules` | **no** |
| `modules.dep` lines for iwl | **no** |

So: firmware packaging was a real gap and is fixed in the image inputs.
The **driver** gap is a kernel Kconfig gap, same family as USB HID /
USB storage on this arch.

## Fix (product) — out-of-tree iwlwifi kmod

Chose option 1: do **not** rebuild the Azure kernel. Supplement it.

* Package: `azurelinux-desktop-iwlwifi-kmod` ships `iwlwifi.ko`,
  `iwlmvm.ko`, `iwldvm.ko`, `iwlmld.ko` under
  `/usr/lib/modules/<uname -r>/extra/azurelinux-desktop/`.
* Built from the same Azure kernel source tarball and exact
  `kernel-devel` as the USB kmods (`scripts/build-desktop-kmods.sh`).
* `subdir-ccflags` force `CONFIG_IWL*_MODULE` for `IS_ENABLED()`;
  make command line sets `CONFIG_IWL*=m` for object lists. Leave
  `CONFIG_IWLWIFI_DEBUGFS` / device tracing off so header `#ifdef`
  matches which `.c` files compile.
* `azurelinux-desktop-policy` now `Requires` the iwlwifi kmod RPM
  alongside usbhid and usb-storage (same NEVRA / same kernel bind).
* No dracut `add_drivers` for iwlwifi: Wi-Fi is not needed to mount
  root. `depmod` in `%post` is enough.
* Firmware stays on the Azure packages already in the kickstart/kiwi
  lists (`iwlwifi-mvm-firmware` and siblings).

Pipeline detail:
[`out-of-tree-usb-kmods-pages.md`](out-of-tree-usb-kmods-pages.md).

Local podman proof (2026-08-02): four modules built against
`6.18.31-1.9.azl4.x86_64` with matching vermagic and depends on
`cfg80211`/`mac80211`/`iwlwifi` as expected.

Bare-metal retest after Pages publish + image rebuild (or `dnf install
azurelinux-desktop-policy` refresh on an existing nested root +
`modprobe iwlwifi`): expect PCI `8086:24f3` to bind, firmware load of
`iwlwifi-8000C-*.ucode`, and a `wlp…` device in NetworkManager.

## Workaround on existing nested install (pre-iwlwifi kmod)

Firmware + `kernel-modules-extra` alone will **not** create a wlan
device on Azure Linux 4.0 x86_64. After the Pages repo carries
`azurelinux-desktop-iwlwifi-kmod` for your running kernel:

```bash
dnf install -y azurelinux-desktop-policy
modprobe iwlwifi
```

Or rebuild/reinstall from media that already pulled the updated policy.

## Release verification (2026.08.03)

Pages repo (browsable):
https://sirredbeard.github.io/azurelinux-desktop/repo/

Published for `6.18.31-1.9.azl4.x86_64`:
`azurelinux-desktop-iwlwifi-kmod` plus updated policy that Requires it.

Filesystem check on release media (7z on rootfs.img, no root mount):

| Artifact | `iwlwifi.ko` / `iwlmvm` / `iwldvm` / `iwlmld` under `extra/azurelinux-desktop/` | Offline RPM |
| --- | --- | --- |
| Live ISO `2026.08.03` | yes (all four) | n/a (installed in rootfs) |
| Installer ISO `2026.08.03` | yes (all four) | `opt/azl-offline-repo/azurelinux-desktop-iwlwifi-kmod-…rpm` + policy + `iwlwifi-mvm-firmware` |

`modinfo` on installer `iwlwifi.ko` / `iwlmvm.ko`: vermagic
`6.18.31-1.9.azl4.x86_64`; depends include `cfg80211` / `mac80211` as
expected.

Bare-metal radio bind on the laptop 8260 is still the runtime proof
after install or `dnf install azurelinux-desktop-policy` on an existing
nested root.
