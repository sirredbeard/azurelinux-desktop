# WiFi missing on bare-metal Azure Linux Desktop install

**Status:** Confirmed fixed on bare metal. Published intel kmod (iwlwifi family) binds on ThinkPad-class hardware; NetworkManager gets a wlan device. Firmware packages and OOT modules both required.

Observed first on a dual-boot nested install on a laptop with Intel Wireless-AC 8260. Desktop booted; Settings showed no WiFi device.

## Host hardware (works under Fedora)

* WiFi PCI: Intel Wireless 8260 `[8086:24f3]`
* Fedora driver: `iwlwifi` + `iwlmvm`
* Fedora iface: `wlp…` connected
* Fedora firmware: `iwlwifi-8000C-*.ucode` from `iwlwifi-mvm-firmware`
* Fedora module pkg: `iwlwifi.ko` in `kernel-modules` (Fedora packaging layout)
* Also present on chassis: Intel Bluetooth `8087:0a2b`; optional WWAN unused here
* Wired: Intel e1000e (no cable in first test)

## What the project config already tried

Installer/live policy already aimed at WiFi userspace:

* NetworkManager enabled
* Installer (`kiwi/config.sh`): `NetworkManager-wifi`, `wpa_supplicant`, `linux-firmware`
* Live kickstart: NetworkManager, linux-firmware
* Fedora blocked from supplying NetworkManager*, linux-firmware, and many `*-firmware` packages so AZL owns them

That is enough for NM to manage WiFi **if a wlan interface exists**. It is not enough to create the interface on this hardware.

## What the install actually had (first pass)

* NetworkManager + NetworkManager-wifi + wpa_supplicant: present
* `linux-firmware`: present
* Split iwlwifi firmware packages: **missing** at first
* `kernel-modules-extra`: **missing** at first (and later proved irrelevant for iwlwifi)
* `iwlwifi.ko` / `iwlmvm.ko`: **absent**
* cfg80211 / mac80211 only
* No `/lib/firmware/iwlwifi-8000C*` until firmware RPMs were added
* Journal: PCI `8086:24f3` enumerated; no iwlwifi bind; NM only created lo + ethernet

## Root cause (two pieces)

### 1. First wrong guess: packaging layout

Fedora puts iwlwifi in plain `kernel-modules`. Azure Linux does **not**. Early fix added `kernel-modules-extra` and the four `iwl*`-firmware packages to live kickstarts, installer offline lists, and installer environment, and excluded those firmware names from Fedora.

Firmware packaging was a real gap and stayed fixed:

* `iwlwifi-mvm-firmware`
* `iwlwifi-dvm-firmware`
* `iwlwifi-mld-firmware`
* `iwlegacy-firmware`

### 2. Real driver gap: Kconfig

After nested reinstall, firmware RPMs and `kernel-modules-extra` were on disk, but still no wlan device.

From the installed kernel config:

```
CONFIG_CFG80211=m
CONFIG_MAC80211=m
# CONFIG_WLAN is not set
```

With `CONFIG_WLAN` off there is no `CONFIG_IWLWIFI`, no `iwlwifi.ko`, and AZL `kernel-modules-extra` only ships a small unrelated set. Confirmed: no iwlwifi modules under `/usr/lib/modules`, no `modules.dep` lines for iwl.

Same class of problem as USB HID / USB storage on this arch.

## Fix: out-of-tree intel kmod

Do not rebuild the Azure kernel. Supplement it.

* Package: **`azurelinux-desktop-intel-kmod`** (was `azurelinux-desktop-iwlwifi-kmod`; Provides/Obsoletes legacy name)
* Ships `iwlwifi.ko`, `iwlmvm.ko`, `iwldvm.ko`, `iwlmld.ko` under `/usr/lib/modules/<uname -r>/extra/azurelinux-desktop/`
* Built from the same Azure kernel source tarball and exact `kernel-devel` as the other desktop kmods (`scripts/build-desktop-kmods.sh`)
* `subdir-ccflags` force `CONFIG_IWL*_MODULE` for `IS_ENABLED()`; make line sets `CONFIG_IWL*=m` for object lists. Leave DEBUGFS / device tracing off so headers match which `.c` files compile
* `azurelinux-desktop-policy` Requires the intel kmod alongside every other sibling at the same kernel bind
* No dracut `add_drivers` for iwlwifi: Wi-Fi is not needed to mount root. `depmod` in `%post` is enough
* Firmware stays on the Azure packages already in the kickstart/kiwi lists

Pipeline: `out-of-tree-usb-kmods-pages.md`. Rename notes: `intel-surface-kmod-families.md`.

## Existing install refresh

```bash
dnf install -y azurelinux-desktop-policy
modprobe iwlwifi
```

Or rebuild/reinstall from media that already pulled the updated policy.

## Verification signatures

Good path:

* `modinfo iwlwifi` shows path under `extra/azurelinux-desktop`
* vermagic matches running kernel
* dmesg firmware load for `iwlwifi-8000C-*.ucode` (or the blob your NIC needs)
* NM shows a `wlp…` device and can associate

Bare metal on ThinkPad-class 8260 confirmed: interface up, NetworkManager connects.

Related: `intel-laptop-host-vs-azl-drivers.md`, `kmod-family-expansion-stock-vs-oot.md`.
