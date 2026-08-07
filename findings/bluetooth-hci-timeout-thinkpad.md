# Bluetooth HCI failure on ThinkPad (OOT layout + recover)

**Status:** Fixed and confirmed on bare metal (2026-08-06). Root cause
was fixed in tree and verified under QEMU USB passthrough (2026-08-03).
The published `azurelinux-desktop-bluetooth-kmod` for
`6.18.31-1.12.azl4` carries the layout fix and works on the ThinkPad on
metal: firmware loads, BlueZ powers on, A2DP endpoints register, and a
paired audio device streams. No Oops, no HCI tx timeout. See
"Bare-metal confirm (2026-08-06)" below.

## Hardware

* Lenovo ThinkPad-class laptop, Intel BT USB `8087:0a2b` (Windstorm Peak)
* Nested AZL install on a container partition of the dual-boot host disk
* Kernel `6.18.31-1.9.azl4` (AZL `# CONFIG_BT is not set`; project OOT
  stack in `azurelinux-desktop-bluetooth-kmod`)
* Firmware `ibt-11-5.{sfi,ddc}` md5 matches working Fedora host

## What failed (symptoms)

* GNOME Settings → Bluetooth **Turned Off**, toggle did nothing
* Kernel: `command 0x0c03 tx timeout`, then
  `Reading Intel version command failed (-110)` (no firmware line)
* Later metal boots: immediate Oops in `sk_skb_reason_drop` from
  `btintel_shutdown_combined` during `hci_power_on` (no clean timeout
  first)
* Screencast also failed early on (PipeWire user units; separate
  finding, fixed and metal-confirmed)

Screenshots (host Pictures / nested home):

| File | What it shows |
| --- | --- |
| `Screenshot From 2026-08-03 13-11-42.png` | Settings BT off |
| `Screenshot From 2026-08-03 13-11-55.png` | Screencast failed (PipeWire) |

## Root cause (confirmed)

### 1. `struct hci_dev` layout mismatch (`CONFIG_BT_LEDS`) - primary crash

`net/bluetooth` (bluetooth.ko) was built with `-DCONFIG_BT_LEDS=1`.
`drivers/bluetooth` (btusb/btintel/...) was not.

`include/net/bluetooth/hci_core.h` inserts `power_led` **before** the
`open` / `close` / `setup` / `shutdown` / `send` function pointers when
LEDS is on. btintel then wrote `setup`/`shutdown` at the wrong offsets.
On `hci_power_on`, the core called a garbage "shutdown" pointer and
landed in `sk_skb_reason_drop` (page fault).

Evidence:

```
Workqueue: hci0 hci_power_on [bluetooth]
RIP: sk_skb_reason_drop+…
Call Trace:
  btintel_shutdown_combined+… [btintel]
  hci_dev_open_sync+… [bluetooth]
  hci_power_on+… [bluetooth]
```

Bare-metal journal evidence (2026-08-03): ThinkPad rfkill unblocked; HCI command timeouts under load; later recover path hit kernel Oops in the Bluetooth receive drop path (`sk_skb_reason_drop` / HCI stack) when the out-of-tree layout did not match `CONFIG_BT_LEDS` and related options.

### 2. Secondary issues (fixed, not sufficient alone)

| Issue | Fix |
| --- | --- |
| Early `modules-load` forced `btusb` before `thinkpad_acpi` rfkill | Comment-only modules-load + `softdep btusb pre: thinkpad_acpi` |
| Recover `systemctl start bluetooth` while unit is `Before=bluetooth.service` | Only restart bluetooth if this run stopped it |
| Recover hung on unbind after Oops | Timeout around unbind / quiesce |
| PipeWire user units not enabled | Preset + user wants (metal OK) |
| `/etc/locale.conf` mode 600 broke `lang.sh` sed when switching pwsh→bash | `chmod 644` in kickstarts |

USB authorize-cycle recover alone never produced a firmware line while
the layout-mismatched modules were installed.

## Fix

### Build (`scripts/build-desktop-kmods.sh`)

Both BT stages must pass the same `CONFIG_BT_*` set into the compiler
and into kbuild:

* `CONFIG_BT_BREDR`, `CONFIG_BT_LE`, `CONFIG_BT_HS`, **`CONFIG_BT_LEDS`**,
  `CONFIG_BT_LE_L2CAP_ECRED`, plus the HCIBTUSB helper MODULE defines

`bluetooth.ko` now exports `bt_leds_init` / `hci_leds_init`. btintel and
bluetooth agree on `struct hci_dev` layout.

### Nested install (offline, 2026-08-03)

Rebuilt modules in AZL container
(`mcr.microsoft.com/azurelinux-beta/base/core:4.0`) against
`kernel-devel-6.18.31-1.9.azl4`, stripped, installed to:

`/lib/modules/6.18.31-1.9.azl4.x86_64/extra/azurelinux-desktop/`

Also restaged recover helper, late unit, and:

```
# /etc/modprobe.d/azurelinux-desktop-bluetooth.conf
softdep btusb pre: thinkpad_acpi
options btusb reset=1
options btusb enable_autosuspend=0
```

Local RPM (not yet published to Pages):

`~/azl-work/kmod-bt-fix-out/azurelinux-desktop-bluetooth-kmod-6.18.31-1.9.azl4.x86_64.rpm`

### Image paths

Recover assets + modprobe options ship from the bluetooth kmod RPM
`%post` / `%files`. Live, disk, and installer kickstarts enable the
recover units. Canary stays bluez-only (no desktop BT kmods).

## Verification

### QEMU USB passthrough after layout fix (2026-08-03 ~15:19)

```bash
AZL_QEMU_SNAPSHOT=1 AZL_QEMU_BT_PASSTHROUGH=1 \
  ./scripts/qemu-boot-installed-hostpart.sh
```

QEMU serial (LEDS-fix kmod attempt):

```
Bluetooth: hci0: Firmware revision 0.0 build 14 week 44 2021
Bluetooth: MGMT ver 1.23
Bluetooth: RFCOMM ver 1.11
```

Same firmware revision string as Fedora host on this radio. No
`0x0c03` / `-110` on the successful open path. Benign noise still
seen: `Reading supported features failed (-16)` and LE Coded PHY
messages (also common on Intel combined devices).

Interactive (user): GNOME Bluetooth connected; audio through Bluetooth
headphones worked end-to-end under passthrough.

### Earlier failures (pre-fix) for comparison

* Bare metal / QEMU dry-run: `0x0c03` + Intel version `-110`, no firmware
* Metal after recover race: Oops in `sk_skb_reason_drop`
* Bare-metal and QEMU serial journals from 2026-08-03 BT diagnose runs
  (kept under `~/azl-work` workdirs during the session; key lines are inlined above)

### Bare metal

Confirmed on metal 2026-08-06, ThinkPad booted from the nested install,
published kmod `azurelinux-desktop-bluetooth-kmod-6.18.31-1.12.azl4`:

```
Bluetooth: hci0: Firmware revision 0.0 build 14 week 44 2021
Bluetooth: hci0: Reading supported features failed (-16)
```

Same firmware string as the good QEMU run. The `-16` line is the known
benign noise on this Intel combined device. BlueZ D-Bus reads
`org.bluez.Adapter1 Powered = true`, A2DP source/sink endpoints
registered, and paired audio device `E4:58:BC:5C:EE:30` reached
`fd ready` (audio streaming). Kernel not Oopsed; taint is only the
expected OOT/unsigned bits (`12288`) from the project kmods.

Boot noise still present but harmless: the CNVi USB device on `usb 1-4`
takes several `error -71` enumeration retries in the first ~4 seconds,
then settles and loads firmware at ~8.7s. The recover units did their
job; `bluetoothd` was restarted once (pid changed) and came up clean.

Quirk for agents: `bluetoothctl show` printed nothing in this session
even while the adapter was powered and streaming. Use busctl as the
authoritative check:

```
busctl call org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties \
  Get ss org.bluez.Adapter1 Powered
```

Older note: gather helper `~/azl-bt-gather.sh` on the azurelinux home
(also `scripts/azl-bt-gather.sh` in-repo). Marker file on nested home:
`BT_LEDS_LAYOUT_FIX_INSTALLED.txt`.

## Shipped pieces

| Piece | Path |
| --- | --- |
| USB reset helper | `assets/bluetooth/azurelinux-desktop-bt-usb-reset` |
| Early oneshot | `assets/systemd/azurelinux-desktop-bt-recover.service` |
| Late oneshot | `assets/systemd/azurelinux-desktop-bt-recover-late.service` |
| udev power rule | `assets/udev/80-azurelinux-desktop-bt-power.rules` |
| PipeWire user preset | `assets/systemd/80-azurelinux-desktop-pipewire.preset` |
| Kmod build (LEDS parity) | `scripts/build-desktop-kmods.sh` bluetooth stage |
| Gather script | `scripts/azl-bt-gather.sh` |
| QEMU hostpart + snapshot | `scripts/qemu-boot-installed-hostpart.sh` |
| Non-interactive BT test | `scripts/test-bt-qemu-passthrough.sh` |

## QEMU passthrough notes

* Useful: proves HCI/firmware without `thinkpad_acpi`.
* CNVi under `usb-host` is still not a perfect metal substitute; this
  run happened to re-enumerate cleanly after the layout fix.
* Keep a single user-net NIC with SSH `hostfwd` (dual NICs broke SSH).
* Default user shell is `pwsh`; use `bash -c '…'` over SSH.

## Follow-ups

1. ~~Publish rebuilt `azurelinux-desktop-bluetooth-kmod`~~ Done -
   published `6.18.31-1.12.azl4` build carries the LEDS fix and is
   metal-confirmed.
2. ~~Bare-metal confirm~~ Done 2026-08-06 (see above). Optional gather
   tarball skipped; the journal lines above are the evidence.
3. Optional later: SELinux `firmware_load` capability if denials appear
   after HCI is healthy; Fedora 7.x BT source overlay only if a new
   Intel init regression shows up on other hardware.
4. Cold power cycle if a dual-boot handoff ever wedges the controller
   again (Windows Fast Startup / warm reboot class of CNVi issues).

## Related

* `pipewire-user-units-not-enabled.md` - screencast (metal confirmed)
* `locale-conf-mode-600.md` - bash `lang.sh` vs mode 600 locale.conf
* `out-of-tree-usb-kmods-pages.md` - kmod publish pipeline
* `qemu-gnome-interactive-testing.md` - guest SSH / Wayland
