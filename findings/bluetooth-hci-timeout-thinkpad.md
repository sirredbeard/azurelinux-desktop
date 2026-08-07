# Bluetooth HCI failure on ThinkPad (OOT layout + recover)

**Status:** Fixed and confirmed on bare metal. Published `azurelinux-desktop-bluetooth-kmod` carries the layout fix. Firmware loads, BlueZ powers on, A2DP works. No Oops, no HCI tx timeout on the good path.

## Hardware

* Lenovo ThinkPad-class laptop, Intel BT USB `8087:0a2b`
* Nested AZL install on a dual-boot host disk partition
* AZL `# CONFIG_BT is not set`; project OOT stack in `azurelinux-desktop-bluetooth-kmod`
* Firmware `ibt-*.{sfi,ddc}` matches working Fedora host for this radio

## What failed

* GNOME Settings -> Bluetooth Turned Off; toggle did nothing
* Kernel: `command 0x0c03 tx timeout`, then `Reading Intel version command failed (-110)` (no firmware line)
* Later metal boots: Oops in `sk_skb_reason_drop` from `btintel_shutdown_combined` during `hci_power_on`
* Screencast also failed early (PipeWire user units; separate finding)

## Root cause

### 1. `struct hci_dev` layout mismatch (`CONFIG_BT_LEDS`) - primary crash

`net/bluetooth` (bluetooth.ko) was built with `-DCONFIG_BT_LEDS=1`.
`drivers/bluetooth` (btusb/btintel/...) was not.

`include/net/bluetooth/hci_core.h` inserts `power_led` **before** the `open` / `close` / `setup` / `shutdown` / `send` function pointers when LEDS is on. btintel then wrote `setup`/`shutdown` at the wrong offsets. On `hci_power_on`, the core called a garbage "shutdown" pointer and faulted in `sk_skb_reason_drop`.

Signature:

```
Workqueue: hci0 hci_power_on [bluetooth]
RIP: sk_skb_reason_drop+…
Call Trace:
  btintel_shutdown_combined+… [btintel]
  hci_dev_open_sync+… [bluetooth]
  hci_power_on+… [bluetooth]
```

### 2. Secondary issues (fixed, not enough alone)

* Early modules-load forced `btusb` before `thinkpad_acpi` rfkill -> comment-only modules-load + `softdep btusb pre: thinkpad_acpi`
* Recover unit restarted bluetooth while ordering was wrong -> only restart bluetooth if this run stopped it
* Recover hung on unbind after Oops -> timeouts around unbind / quiesce
* PipeWire user units not enabled -> preset + user wants (see related PipeWire finding)
* `/etc/locale.conf` mode 600 broke `lang.sh` when switching pwsh->bash -> chmod 644 in kickstarts

USB authorize-cycle recover alone never produced a firmware line while the layout-mismatched modules were installed.

## Fix

### Build (`scripts/build-desktop-kmods.sh`)

Both BT stages must pass the **same** `CONFIG_BT_*` set into the compiler and kbuild:

* `CONFIG_BT_BREDR`, `CONFIG_BT_LE`, `CONFIG_BT_HS`, **`CONFIG_BT_LEDS`**, `CONFIG_BT_LE_L2CAP_ECRED`, plus HCIBTUSB helper MODULE defines

`bluetooth.ko` then exports LED helpers and agrees with btintel on `struct hci_dev` layout.

Also keep RFCOMM_TTY on `subdir-ccflags-y` so `rfcomm/tty.c` sees the define. Define `CONFIG_BT_BCM_MODULE` and Intel/RTL/MTK siblings for helper headers that use `IS_ENABLED`.

### Runtime policy in the bluetooth RPM

```
# /etc/modprobe.d/azurelinux-desktop-bluetooth.conf
softdep btusb pre: thinkpad_acpi
options btusb reset=1
options btusb enable_autosuspend=0
```

modules-load conf is comment-only. udev loads btusb from USB aliases.

Recover assets ship from the RPM `%post` / `%files`:

* `assets/bluetooth/azurelinux-desktop-bt-usb-reset`
* `assets/systemd/azurelinux-desktop-bt-recover.service`
* `assets/systemd/azurelinux-desktop-bt-recover-late.service`
* `assets/udev/80-azurelinux-desktop-bt-power.rules`

Live, disk, and installer paths enable the recover units. Canary stays bluez-only (no desktop BT kmods load there).

## Verification

### QEMU USB passthrough after layout fix

```bash
AZL_QEMU_SNAPSHOT=1 AZL_QEMU_BT_PASSTHROUGH=1 \
  ./scripts/qemu-boot-installed-hostpart.sh
```

Good serial lines:

```
Bluetooth: hci0: Firmware revision 0.0 build 14 week 44 2021
Bluetooth: MGMT ver 1.23
```

Same firmware revision string as Fedora on this radio. No `0x0c03` / `-110` on the successful open path. Benign noise still seen: `Reading supported features failed (-16)` and LE Coded PHY messages.

Interactive: GNOME Bluetooth connected; audio through Bluetooth headphones worked under passthrough.

### Bare metal

Published kmod on metal:

```
Bluetooth: hci0: Firmware revision 0.0 build 14 week 44 2021
Bluetooth: hci0: Reading supported features failed (-16)
```

BlueZ D-Bus: `org.bluez.Adapter1 Powered = true`, A2DP endpoints registered, paired audio device reached streaming. Kernel not Oopsed; taint is only expected OOT/unsigned bits from project kmods.

Boot noise still present but harmless: CNVi USB device may take several `error -71` enumeration retries in the first seconds, then settles and loads firmware. Recover units may restart `bluetoothd` once.

Quirk for agents: `bluetoothctl show` may print nothing even while the adapter is powered and streaming. Prefer busctl:

```
busctl call org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties \
  Get ss org.bluez.Adapter1 Powered
```

Gather helper: `scripts/azl-bt-gather.sh`.

## QEMU passthrough notes

* Useful: proves HCI/firmware without `thinkpad_acpi`.
* CNVi under `usb-host` is still not a perfect metal substitute.
* Keep a single user-net NIC with SSH `hostfwd` (dual NICs broke SSH).
* Default user shell is `pwsh`; use `bash -c '…'` over SSH.
* Guest interaction quirks: `qemu-gnome-interactive-testing.md`.

## Follow-ups

* Published LEDS-fixed kmod and metal confirm: done.
* Optional later: SELinux `firmware_load` if denials appear after HCI is healthy.
* Cold power cycle if a dual-boot handoff wedges the controller (Windows Fast Startup / warm reboot class of CNVi issues).

## Related

* `pipewire-user-units-not-enabled.md` - screencast
* `locale-conf-mode-600.md` - bash lang.sh vs mode 600 locale.conf
* `out-of-tree-usb-kmods-pages.md` - kmod publish pipeline
* `desktop-kmod-waves-1-5.md` - BT builder pitfalls
* `systemd-modules-load-snd-hda.md` - same class of force-load boot failure
* `qemu-gnome-interactive-testing.md` - guest SSH / Wayland
