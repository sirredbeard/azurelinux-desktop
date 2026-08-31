# Hypervisor mouse defaults (GNOME Boxes / PS/2)

**Status:** Diagnosed; product work in flight. Guest agents listed in
live/installer package sets. psmouse OOT stage in
`scripts/build-desktop-kmods.sh` (needs kmod republish + image rebuild).
Bare-metal ThinkPad multitouch is a related but separate stack: same
psmouse package now also ships RMI4 SMBus modules. See
`thinkpad-two-finger-scroll-rmi-smbus.md`. See also
`hypervisor-guest-agents.md`.

## What we saw (GNOME Boxes + live ISO)

Boxes default domain:

- machine pc-i440fx, video qxl, graphics spice
- inputs: PS/2 mouse + PS/2 keyboard only (no tablet)
- spice channel disconnected without guest `spice-vdagent`
- QEMU mouse-mode: server (relative / grab)
- QEMU active mouse: PS/2 only

Symptom: host pointer swallowed into the Boxes window, no useful guest
cursor. Matches a relative SPICE grab with no working guest pointer
driver for the device Boxes actually presents.

## What changed while debugging

On the host, against the running domain only (not an image rebuild):

1. `virsh attach-device` USB tablet
2. `virsh attach-device` virtio tablet

After resume from guest sleep, QEMU showed virtio tablet active and
`mouse-mode: client`. SPICE channel still disconnected without vdagent.

So the working mouse was not sleep magic and not spice-vdagent. Sleep
may have nudged guest udev/Mutter to pick up the hot-added
virtio-tablet (in-tree `virtio_input` on AZL).

USB tablet alone still needs our out-of-tree usbhid kmod in the guest;
virtio-tablet does not.

## Why our QEMU scripts are fine but Boxes is not

Project scripts force absolute input:

- `-device qemu-xhci -device usb-tablet` (or virtio-tablet)
- see `qemu-gnome-interactive-testing.md`, `scripts/qemu-*.sh`

GNOME Boxes (and many "unknown Linux" templates) do not do that. They
keep classic PS/2 mouse for unrecognized guests.

## Azure kernel gap (same family as usbhid)

From AZL x86_64 config / existing notes:

- `CONFIG_SERIO_I8042=y`, `CONFIG_SERIO_LIBPS2=y`,
  `CONFIG_KEYBOARD_ATKBD=y`: keyboard works
- `CONFIG_INPUT_MOUSE` not set, `CONFIG_MOUSE_PS2` not set: no psmouse
- `CONFIG_USB_HID` not set: USB mouse/tablet need our kmod
- `CONFIG_VIRTIO_INPUT=m`: virtio-tablet works if hypervisor adds it
- `CONFIG_INPUT_UINPUT=y`: spice-vdagent can create uinput device

Boxes default PS/2 mouse has nothing in-guest to drive it. Keyboard on
the same controller still works.

## Do we need PS/2 drivers for real-world hypervisors?

Yes, if we want zero-config in tools that default to PS/2 for unknown
Linux. USB tablet and virtio are not universal defaults.

- Our QEMU scripts: usb-tablet or virtio-tablet (covered)
- GNOME Boxes: PS/2 only (needs psmouse)
- virt-manager / libvirt generic: often PS/2; tablet if OS profile known
- VirtualBox: often PS/2 and/or USB tablet; Guest Additions path
- VMware: vmmouse / tools path; may still expose PS/2
- Hyper-V: hyperv_mouse / synthetic, not classic PS/2

So:

1. psmouse (or upstream `CONFIG_INPUT_MOUSE=y` + `CONFIG_MOUSE_PS2=y`)
   is baseline for dumb PS/2 defaults. Prefer asking AZL for the config
   flip; OOT psmouse is the same churn class as usbhid.
2. Keep usbhid kmod for real USB mice and USB tablets.
3. Keep virtio_input (in-tree) when the hypervisor adds virtio-tablet.
4. Add guest agents at package level (separate from psmouse):
   spice-vdagent, qemu-guest-agent, open-vm-tools, hyperv-daemons.

Agents improve integration. They do not replace a kernel mouse driver
when the only device is PS/2 and vdagent is absent or Wayland ignores
uinput warps.

## Window resize / letterboxing in GNOME Boxes

Symptom: guest desktop stays a fixed size inside a larger Boxes window
(black bars).

Host evidence: spice channel disconnected, video qxl, graphics spice.
Live package list had no spice-vdagent.

SPICE dynamic guest resolution is a guest agent feature: session
spice-vdagent + system spice-vdagentd talk over the spice virtio port
and adjust virtual monitors to the client window. Without the package,
Boxes can only scale or letterbox a fixed guest mode.

Independent of the PS/2 vs tablet mouse gap, but the fix set overlaps:
ship and enable spice-vdagent (and usually qemu-guest-agent) on live +
installed images.

Wayland note: modern spice-vdagent has session integration beyond
classic X11; still verify resize under our GNOME Wayland session after
adding the package.

## Product work (this pass)

- Guest agents in live kickstart + installer INSTALL_PKGS (ship-all).
- psmouse OOT stage + `azurelinux-desktop-psmouse-kmod` packaging in
  `build-desktop-kmods.sh` (core + trackpoint; mirrors aarch64 AZL
  `CONFIG_MOUSE_PS2=m`).
- CI fail once: `psmouse-base.c` includes every protocol header; first
  build only copied a few. Fix: copy all `*.h` from
  `drivers/input/mouse/` before compiling.
- Live ISO rebuilt with psmouse + spice-vdagent.

## Boxes runtime after that rebuild: cursor yes, click/key no

What Boxes presents:

- PS/2 mouse + PS/2 keyboard only
- graphics spice + video qxl
- spice channel connected; mouse-mode client
- active QEMU mouse: PS/2 only until host hot-adds tablet

Guest evidence (via qemu-guest-agent channel hot-added):

- psmouse loaded (ImExPS/2 Generic Explorer Mouse)
- AT keyboard present
- spice-vdagent tablet uinput present
- usbhid not loaded until modules-load fix (USB tablet hot-add did not
  bind)
- packages on ISO: spice-vdagent, qemu-guest-agent, psmouse kmod,
  open-vm-tools, hyperv-daemons, vbox additions
- spice channel connected; window resize works
- i8042 IRQ on HMP `sendkey` increments (kernel gets keys)
- First GNOME session UI: no response to keys or clicks
- After logind session Terminate + re-login: keyboard works
- Empty liveuser password at GDM rejected

So: drivers and vdagent display path are largely fine. The broken state
was userspace session input (and/or lock/greeter trap), not missing
psmouse.

### Failure mode that matches the user report

1. spice-vdagent gives a visible client cursor + dynamic resize.
2. Boxes has no tablet; click path is vdagent uinput buttons (uneven
   under GNOME Wayland) or PS/2 mouse (relative, easy to miss).
3. If the session is on the lock/GDM password UI and empty password is
   rejected, you need working keys or clicks to recover.
4. One observed session was fully wedged for input even on an unlocked
   desktop (IRQs yes, UI no) until the session was killed.

### Mitigations landed / next

- Live dconf: disable screensaver lock + `disable-lock-screen` (live
  kickstart only) so a dead click path cannot trap on the lock UI.
- usbhid kmod: add `modules-load.d` so USB tablet binds reliably when
  the hypervisor presents one.
- Still ideal long-term: hypervisor tablet (virtio/USB) for absolute
  clicks; Boxes does not add one for unknown OS profiles.
- Re-login or logind session restart recovers a wedged input session.

### Temporary host-side debug

```bash
virsh -c qemu:///session attach-device boxes-unknown-2 /dev/stdin --live <<'EOF'
<input type='tablet' bus='virtio'/>
EOF
```

## Key commands (host debug)

```bash
virsh -c qemu:///session dumpxml boxes-unknown | grep -E 'input|spice|qxl'
virsh -c qemu:///session qemu-monitor-command boxes-unknown --hmp 'info mice'
virsh -c qemu:///session qemu-monitor-command boxes-unknown --hmp 'info spice'
```
