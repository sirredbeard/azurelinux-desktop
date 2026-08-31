# ThinkPad two-finger scroll missing (Synaptics SMBus / RMI4)

**Status:** Diagnosed and proven on bare metal. Product fix is in
`scripts/build-desktop-kmods.sh` (psmouse stage ships `rmi_core` +
`rmi_smbus` with `psmouse`). Needs kmod republish and an image rebuild
before installs get it for free. Tracks GitHub issue #8.

## What we saw

Bare-metal ThinkPad T470s on Azure Linux 4.0 Desktop
(kernel `6.18.31-1.16.azl4`):

* Pointer device showed up as a relative "PS/2 Synaptics" mouse
* libinput scroll method was button-only (no two-finger)
* TrackPoint still moved the cursor
* Wi-Fi and the rest of the desktop stack were otherwise usable

```
# libinput list-devices (before)
Device:           SynPS/2 Synaptics TouchPad
Scroll methods:   *button
```

Pad serio firmware id on this unit:

```
PNP: LEN007f PNP0f13
```

## Host under Fedora (works)

Same chassis under Fedora uses SMBus + RMI4. The pad is a real
multitouch clickpad, not a relative PS/2 mouse. Two-finger scroll and
edge scroll both work. That is the target behavior.

## Why AZL fails

Stock Azure Linux x86_64 cloud kernel turns desktop input off:

* `CONFIG_INPUT_MOUSE` not set (no in-tree `psmouse`)
* `CONFIG_RMI4_CORE` / `CONFIG_RMI4_SMB` not set

The project already ships an out-of-tree `psmouse` kmod for GNOME Boxes
and other PS/2-default hypervisors (see
`findings/hypervisor-mouse-ps2-boxes.md`). That is enough for a dumb
PS/2 mouse. It is not enough for a ThinkPad Synaptics InterTouch pad.

On these pads the kernel is supposed to:

1. Probe on PS/2 and notice InterTouch capability
2. Hand the device to SMBus (`rmi4_smbus` at 0x2c)
3. Drive multitouch through RMI4 (`rmi_core` F11/F12, buttons via F30,
   TrackPoint via F03)

Without step 2 and 3 you stay in relative PS/2 mode forever. libinput
cannot invent multitouch axes from that.

Also: upstream `smbus_pnp_ids` already lists `LEN007a` and `LEN006c` for
T470s. This machine reports `LEN007f`. With
`synaptics_intertouch` left at the allowlist default, `LEN007f` never
gets the SMBus path unless we add the id or force InterTouch on.

## Dead ends

* libinput/Mutter tweaks alone: no. Relative PS/2 has nothing to scroll
  with two fingers.
* `i2c-hid` / `hid-rmi`: wrong bus for this generation. The handoff is
  SMBus InterTouch, not HID over I2C.
* Loading `psmouse` with `synaptics_intertouch=1` **without** RMI:
  SMBus client appears, nothing binds, pad disappears. Do not ship the
  option without `rmi_core` + `rmi_smbus`.

## What fixed it on this machine

Built out-of-tree against the matching
`CBL-Mariner-Linux-Kernel` `rolling-lts/azl4/6.18.31.1` sources:

* `rmi_core.ko` (bus, driver, F01, 2D sensor, F03, F11, F12, F30)
* `rmi_smbus.ko`
* existing OOT `psmouse.ko` with InterTouch enabled

Load order that worked:

```
modprobe rmi_core
modprobe rmi_smbus
modprobe psmouse synaptics_intertouch=1
```

After that:

```
# dmesg
rmi4_smbus 0-002c: registering SMbus-connected sensor
rmi4_f01 rmi4-00.fn01: found RMI device, manufacturer: Synaptics, product: TM3145-007

# libinput
Device:           Synaptics TM3145-007
Scroll methods:   *two-finger edge
```

Two-finger scroll works. Edge scroll works. TrackPoint still works
(F03 serio).

## Product change

`azurelinux-desktop-psmouse-kmod` now builds and ships the full stack:

* `psmouse.ko` with `CONFIG_RMI4_SMB=1` so InterTouch is not hard-off
* `rmi_core.ko`, `rmi_smbus.ko`
* `modules-load.d`: `rmi_core`, `rmi_smbus`, `psmouse` (RMI first)
* `modprobe.d`: `options psmouse synaptics_intertouch=1` and
  `softdep psmouse pre: rmi_core rmi_smbus`
* OOT one-line allowlist add: `LEN007f` next to the existing T470s ids

VM safety: plain PS/2 mice (Boxes default) never enter the Synaptics
InterTouch path. Only pads that claim InterTouch try SMBus. If RMI is
missing, do not force InterTouch.

## Follow-ups

* Republish desktop kmods so installed systems pick this up from the
  Pages repo
* Long term: ask AZL for in-tree `CONFIG_INPUT_MOUSE` + `CONFIG_RMI4_*`
* Other Lenovo PNP ids that advertise InterTouch but sit off the
  allowlist are covered by `synaptics_intertouch=1` once RMI ships
