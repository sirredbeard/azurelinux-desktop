# Hypervisor mouse defaults (GNOME Boxes / PS/2)

**Status:** diagnosed; product work in flight — guest agents listed in
live/installer package sets; psmouse OOT stage in
`scripts/build-desktop-kmods.sh` (needs kmod republish + image rebuild).
See also `findings/hypervisor-guest-agents.md`.

## What we saw (GNOME Boxes + live ISO, 2026-08-05)

Host: Fedora, `gnome-boxes` session VM `boxes-unknown`, media
`/home/fedora/azurelinux-desktop-live.iso`.

Boxes default domain (before any edits):

- machine `pc-i440fx`, video **qxl**, graphics **spice**
- inputs: **PS/2 mouse + PS/2 keyboard only** (no tablet)
- spice channel `com.redhat.spice.0` **disconnected** (no guest `spice-vdagent`)
- QEMU `mouse-mode: server` (relative / grab)
- QEMU active mouse: PS/2 only

Symptom: host pointer “swallowed” into the Boxes window, no useful
guest cursor. Matches a relative SPICE grab with **no working guest
pointer driver** for the device Boxes actually presents.

## What changed while debugging (this is why mouse worked later)

On the **host**, against the running domain only (not an image rebuild):

1. `virsh attach-device` **USB tablet**
2. `virsh attach-device` **virtio tablet**

After resume from guest sleep, QEMU showed:

```text
  Mouse #3: QEMU HID Tablet (absolute)
  Mouse #2: QEMU PS/2 Mouse
* Mouse #4: QEMU Virtio Tablet (absolute)   ← active
  mouse-mode: client
  com.redhat.spice.0 state=disconnected     ← still no vdagent
```

So the working mouse was **not** sleep magic and **not** spice-vdagent.
Sleep may have nudged guest udev/Mutter to pick up the hot-added
**virtio-tablet** (in-tree `virtio_input` on AZL). SPICE then moved to
`mouse-mode: client` because an absolute tablet exists.

USB tablet alone still needs our out-of-tree **usbhid** kmod in the
guest; virtio-tablet does not.

## Why our QEMU scripts are fine but Boxes is not

Project scripts force absolute input:

- `-device qemu-xhci -device usb-tablet` (or virtio-tablet)
- see `findings/qemu-gnome-interactive-testing.md`, `scripts/qemu-*.sh`

GNOME Boxes (and many “unknown Linux” templates) do **not** do that.
They keep classic PS/2 mouse for unrecognized guests.

## Azure kernel gap (same family as usbhid)

From AZL `6.18-x86_64-azl.config` / existing notes:

| Knob | AZL x86_64 | Effect |
| --- | --- | --- |
| `CONFIG_SERIO_I8042` | `y` | i8042 present (keyboard works) |
| `CONFIG_SERIO_LIBPS2` | `y` | PS/2 helper present |
| `CONFIG_KEYBOARD_ATKBD` | `y` | PS/2 keyboard works |
| `CONFIG_INPUT_MOUSE` | **not set** | no mouse class |
| `CONFIG_MOUSE_PS2` | **not set** | **no `psmouse`** |
| `CONFIG_USB_HID` | **not set** | USB mouse/tablet need our kmod |
| `CONFIG_VIRTIO_INPUT` | `m` | virtio-tablet works if hypervisor adds it |
| `CONFIG_INPUT_UINPUT` | `y` | spice-vdagent can create uinput device |

So: Boxes default PS/2 mouse has **nothing in-guest to drive it**.
Keyboard on the same controller still works.

## Do we need PS/2 drivers for “real world” hypervisors?

**Short answer: yes, if we want zero-config in tools that default to PS/2
for unknown Linux.** USB tablet + virtio are not universal defaults.

| Hypervisor / tool | Typical pointer when OS unknown | What we already cover | Still missing |
| --- | --- | --- | --- |
| Our QEMU scripts | usb-tablet or virtio-tablet | usbhid kmod + virtio_input | — |
| GNOME Boxes | PS/2 only (this run) | virtio only if user/XML adds it | **psmouse** |
| virt-manager / libvirt generic | often PS/2; tablet if OS profile known | same | **psmouse** |
| VirtualBox | often PS/2 and/or USB tablet; Guest Additions path | usbhid helps USB tablet | **psmouse**; optional vbox guest tools |
| VMware | vmmouse / tools path; may still expose PS/2 | optional `open-vm-tools` | **psmouse** baseline; tools package |
| Hyper-V | `hyperv_mouse` / synthetic, not classic PS/2 | optional `hyperv-daemons` | not solved by psmouse alone |

So:

1. **psmouse (or upstream `CONFIG_INPUT_MOUSE=y` + `CONFIG_MOUSE_PS2=y`)**  
   Baseline for “dumb” PS/2 defaults (Boxes, generic QEMU/libvirt, many
   VBox setups). i8042/libps2 are already built-in; only the mouse
   protocol driver is missing. Prefer asking AZL for the config flip;
   out-of-tree `psmouse` is possible but same churn class as usbhid.

2. **Keep usbhid kmod**  
   Real USB mice and USB tablets (VBox/QEMU tablet).

3. **Keep virtio_input (in-tree)**  
   Best path when the hypervisor actually adds virtio-tablet.

4. **Add guest agents (package-level, separate from psmouse)**  
   - `spice-vdagent` + enable `spice-vdagentd` — Boxes/virt-manager SPICE
     channel, clipboard, resize; absolute mouse via uinput is **uneven
     under GNOME Wayland** (Mutter), so not a full PS/2 substitute.
   - `qemu-guest-agent` — lifecycle/shutdown from host.
   - `open-vm-tools` / `open-vm-tools-desktop` — VMware.
   - `hyperv-daemons` — Hyper-V.

Agents improve integration; they do **not** replace a kernel mouse
driver when the only device is PS/2 and vdagent is absent or Wayland
ignores uinput warps.

## Product direction (recommended)

1. **Treat PS/2 mouse like usbhid:** either AZL kernel config enablement
   or a small out-of-tree `psmouse` kmod wired through the same Pages
   policy channel if upstream will not flip the bit.
2. **Ship VM guest stack on live + installed:** `spice-vdagent`,
   `qemu-guest-agent`, and the VMware/Hyper-V tools that already fit
   Fedora package policy.
3. **Do not rely on Boxes learning our OS** or on users editing XML.
4. **Keep project QEMU scripts on usb-tablet/virtio-tablet** for CI.

## Window resize / letterboxing in GNOME Boxes (same session)

**Symptom:** Guest desktop stays a fixed size inside a larger Boxes
window (black bars). Screenshot
`Screenshot From 2026-08-05 18-26-23.png` shows Activities with the
session framed in letterbox.

**Host evidence (same domain):**

```text
com.redhat.spice.0 state=disconnected
video model=qxl
graphics type=spice
```

Live package list has **no** `spice-vdagent` (only unrelated
`spice-glib` / `spice-gtk3` client libs pulled as deps).

SPICE dynamic guest resolution is a **guest agent** feature: session
`spice-vdagent` + system `spice-vdagentd` talk over
`/dev/virtio-ports/com.redhat.spice.0` and adjust virtual monitors to
the client window. Without the package, Boxes can only scale or
letterbox a fixed guest mode.

This is independent of the PS/2 vs tablet mouse gap, but the fix set
overlaps: ship and enable `spice-vdagent` (and usually
`qemu-guest-agent`) on live + installed images.

Wayland note: modern `spice-vdagent` has session integration beyond
classic X11; still verify resize under our GNOME Wayland session after
adding the package. QXL vs virtio-gpu affects display path more than
the agent channel; Boxes defaulted to QXL here and GNOME did start.

## Product work (this pass)

- Guest agents in live kickstart + installer `INSTALL_PKGS` (ship-all).
- `psmouse` OOT stage + `azurelinux-desktop-psmouse-kmod` packaging in
  `build-desktop-kmods.sh` (core + trackpoint; mirrors aarch64 AZL
  `CONFIG_MOUSE_PS2=m`).
- CI fail (run 31061711603): `psmouse-base.c` includes every protocol
  header; first build only copied a few. Fix: copy all `*.h` from
  `drivers/input/mouse/` before compiling.
- Still need: publish desktop kmods with psmouse, full ISO/disk rebuild,
  Boxes runtime confirm without host tablet attach.

## Key commands (host debug)

```bash
virsh -c qemu:///session dumpxml boxes-unknown | grep -E 'input|spice|qxl'
virsh -c qemu:///session qemu-monitor-command boxes-unknown --hmp 'info mice'
virsh -c qemu:///session qemu-monitor-command boxes-unknown --hmp 'info spice'
# temporary only:
virsh -c qemu:///session attach-device boxes-unknown /dev/stdin --live <<'EOF'
<input type='tablet' bus='virtio'/>
EOF
```
