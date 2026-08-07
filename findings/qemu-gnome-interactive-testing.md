# QEMU + GNOME Wayland interactive testing

**Status:** active testing notes

Practical notes for interactive testing of Azure Linux Desktop in QEMU.
Keep this short. Prefer SSH into the guest over fighting Wayland mouse
from the QEMU monitor.

## Launch essentials

```bash
qemu-system-x86_64 \
  -enable-kvm -m 8G -smp 4 -cpu host \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file="$WORKDIR/OVMF_VARS.fd" \
  -drive file="$ISO",media=cdrom,readonly=on,if=ide \
  -device usb-ehci -device usb-tablet \
  -net nic,model=virtio -net user,hostfwd=tcp::2222-:22 \
  -vga virtio -display vnc=127.0.0.1:1 \
  -monitor unix:"$WORKDIR/monitor.sock",server,nowait \
  -serial file:"$WORKDIR/serial.log" \
  -daemonize -pidfile "$WORKDIR/qemu.pid"
```

Key flags:

- `-cpu host`: required for .NET. Default `qemu64` lacks SSE4.1/4.2 and
  POPCNT; .NET aborts at startup.
- `-device usb-ehci -device usb-tablet`: absolute mouse coords. Both
  devices required together.
- `-m 8G`: 4G boots but Flatpak install OOMs. 8G gives overlay headroom.
- `-vga virtio`: required for GNOME Wayland. std/qxl often blank or fail.
- `hostfwd=tcp::2222-:22`: SSH into the guest. Preferred interaction path.
- Fresh writable `OVMF_VARS.fd` per test. Always attach OVMF CODE + VARS
  for installer/EFI work.

Project helpers under `scripts/qemu-*.sh` already encode these patterns.

## SSH first, monitor second

Wayland mouse clicks via QEMU monitor are unreliable. Prefer:

```bash
ssh -p 2222 liveuser@127.0.0.1
# or azurelinux@ for installed images
```

Default user shell is often `pwsh`. Wrap POSIX one-liners:

```bash
ssh -p 2222 liveuser@127.0.0.1 "bash -c 'systemctl is-active gdm'"
```

Live ISO may ship with `sshd` disabled. Enable for a session if needed,
then start it. Empty-password or known live credentials are session
local; do not bake secrets into the ISO for debug.

## GTK display vs VNC

- VNC (`-display vnc=127.0.0.1:N`) is the reliable path for scripted
  capture.
- GTK (`-display gtk`) is fine for manual eyes-on. Host Wayland pointer
  grab is flaky for automation.
- QEMU monitor `screendump` works for Plymouth and early boot. After
  Mutter/Wayland takes virtio-gpu, screendump is often all black. Capture
  the VNC framebuffer instead (Python RFB client or a real VNC viewer).

## Keyboard and Super key gotchas (if you must use sendkey)

- Super/`key_leftmeta` only works when an app window has focus. On the
  bare desktop with no windows, Super does nothing. Keep a terminal open.
- Never close all windows during a QEMU monitor session or you are stuck.
- Bash word-splitting eats spaces in naive type loops; index characters
  with substring expansion if you must type via sendkey.
- Looking Glass evaluator drops `.` from `sendkey period`/`dot`. Prefer
  Super from a focused terminal over LG for Activities.

## Mouse via monitor (limited)

With usb-tablet, `mouse_move X Y` is absolute on the guest framebuffer.
Always pair `mouse_button 1` with `mouse_button 0` (release).

Dock icons inside Activities often ignore QEMU pointer events. Prefer
Activities search + Enter, or SSH to launch apps.

## App notes under QEMU

- VS Code Insiders / Edge Canary: often need `--no-sandbox` in live
  OverlayFS.
- GitHub Desktop: process starts; Electron window may stay blank under
  QEMU virtio-vga/Wayland. Real hardware is fine. Check process, not
  pixels.
- Microsoft Edit: TUI inside GNOME Terminal, not a separate GTK window.
- .NET: needs `-cpu host` (see above).

## Timing (order of magnitude, KVM 8G)

- UEFI/GRUB: a few seconds
- Plymouth: tens of seconds
- GNOME Activities visible: on the order of a minute from power-on

Serial log with `quiet rhgb` shows little after UEFI. Poll VNC or use
boot helpers for progress.

## Installer ISO testing

Anaconda TUI is console-mode, not a rich graphical scene. Headless
screendump is a poor signal during Plymouth and TUI.

Preferred approach:

1. Static filesystem check first (two-layer squashfs: outer
   `LiveOS/squashfs.img`, inner `LiveOS/rootfs.img`).
2. Full interactive install with GTK display or a real VNC viewer.
3. After install, reboot without the ISO to test the installed target.

Installer GRUB timeout is short. A mostly-black frame after GRUB often
means Plymouth started, not a hang.

## Snapshot pattern

Use `-snapshot` or a throwaway overlay so downloaded artifacts stay
clean. For installer tests, create a fresh empty target disk and a fresh
`OVMF_VARS.fd` per run.

## qcow2 vs live ISO

The live qcow2 is an installed disk image, not a live overlay.
`livesys.service` is conditioned on `rd.live.image` and will not run.
`liveuser` is pre-created at build time for the disk path. GDM autologin
and system dconf still apply.

## Common failures

- "Display output is not active": early UEFI/GRUB, guest reset, or GNOME
  display died. Check `info status` and serial log; reboot QEMU if stuck.
- All-black screendump after GNOME: use VNC capture, not monitor
  screendump.
- Guest OOM: raise RAM; avoid heavy Flatpak work at 4G.
- VNC address in use: wait a couple seconds after kill before relaunch.
- Super key no-op: no focused window; keep a terminal open or reboot.

## Related

- `plymouth-boot-animation.md`
- `scripts/qemu-test-live-iso.sh`, `scripts/qemu-test-disk-image.sh`,
  `scripts/qemu-test-install-iso.sh`
