# QEMU + GNOME Wayland Interactive Testing: Quirks, Gotchas, and Rules of Thumb

Notes from interactive testing of the Azure Linux Desktop live ISO via QEMU monitor
(screendump + sendkey + mouse_move) on a Fedora host. Accumulated 2026-07-22/23.

---

## QEMU Launch

### Must-have flags

```bash
qemu-system-x86_64 \
  -enable-kvm -m 8G -smp 4 -cpu host \          # see CPU note below
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file="$WORKDIR/OVMF_VARS.fd" \
  -drive file="$ISO",media=cdrom,readonly=on,if=ide \
  -device usb-ehci -device usb-tablet \          # absolute mouse coords
  -net nic,model=virtio -net user \
  -vga virtio -display vnc=127.0.0.1:1 \
  -monitor unix:"$WORKDIR/monitor.sock",server,nowait \
  -serial file:"$WORKDIR/serial.log" \
  -daemonize -pidfile "$WORKDIR/qemu.pid"
```

**`-cpu host`** — required for .NET. The default `qemu64` CPU model lacks SSE4.1,
SSE4.2, and POPCNT; .NET 9+ aborts at startup with:
```
Fatal error.
The current CPU is missing one or more of the following instruction sets:
SSE, SSE2, SSE3, SSSE3, SSE4.1, SSE4.2, POPCNT
```
With `-cpu host`, the host CPU extensions are passed through and .NET runs fine.

**`-device usb-ehci -device usb-tablet`** — without this, `mouse_move` sends
relative deltas that drift randomly. With usb-tablet, coordinates are absolute
pixels on the guest framebuffer. Both devices are required; usb-tablet alone
does not work without usb-ehci on the same bus.

**`-m 8G`** — 4G is enough to boot but leaves only ~783 MB for the OverlayFS
upper tmpfs. This is tight enough that a Flatpak install OOMs the guest and
causes a silent reset. 8G gives ~1.5G overlay headroom.

**`-vga virtio`** — required for GNOME Wayland. With `-vga std` or `-vga qxl`,
GNOME either fails to start or renders blank windows. virtio-vga is the only
card that works reliably with the live ISO's KMS/DRM stack.

**VNC port reuse** — after killing a QEMU instance, the VNC port `:1` (5901)
may not be released immediately. Wait ~2 seconds before starting a new instance
or you get `Address already in use`. Keep one instance running at a time.

### Reboot rule of thumb

Kill and restart QEMU whenever:
- "Display output is not active" persists after mouse/key input
- The guest OOM-killed itself (signs: serial log stops mid-boot or at BdsDxe, screendump returns all-black after GNOME was up)
- Input stops working in an app that previously accepted it
- GNOME appears to have crashed (top bar disappears, desktop turns solid color)

Rebooting is faster than diagnosing a broken QEMU/guest state.

---

## Screendumps

### How to take one

```bash
printf "screendump /path/out.ppm\n" | socat - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1
convert /path/out.ppm /path/out.png && rm /path/out.ppm
```

Always convert to PNG immediately; PPM files are large (~3 MB each).

### "Display output is not active"

This QEMU VNC message appears in the screendump when:
1. The guest hasn't initialized virtio-vga yet (early UEFI/GRUB phase)
2. GNOME's display server has crashed or been killed
3. The guest itself has reset/rebooted and is back in UEFI POST

It is NOT a QEMU crash — the QEMU process is still running. Check
`info status` via the monitor socket to confirm. Check the serial log to see
how far along the boot is.

---

## Keyboard Input

### sendkey rules

- Use `sendkey <key>` via the monitor socket.
- Letters: `sendkey a`, `sendkey b`, etc. (lowercase only; uppercase = `sendkey shift-a`)
- Space: `sendkey spc`
- Hyphen/dash: `sendkey minus`
- Dot: `sendkey dot`
- Slash: `sendkey slash`
- Underscore: `sendkey shift-minus`
- Enter/Return: `sendkey ret`
- Backspace: `sendkey backspace`
- Tab: `sendkey tab`
- Escape: `sendkey esc`
- Alt+F4: `sendkey alt-f4`
- Super/Meta/Windows key: `sendkey key_leftmeta` (**not** `sendkey super` — that doesn't work reliably)

### Bash word-splitting gotcha with type_line

When building a `type_line` function with `for c in $(echo "$line" | fold -w1)`,
bash word-splitting eats spaces — `"gh --version"` becomes `"gh"` then `"--version"`
typed as one run with no space. The fix is to use bash substring indexing:

```bash
type_line() {
    local line="$1"; local i=0
    while [ $i -lt ${#line} ]; do
        local c="${line:$i:1}"
        case "$c" in
            ' ') sendkey spc ;; '-') sendkey minus ;; '.') sendkey dot ;;
            '/') sendkey slash ;; *) sendkey "$c" ;;
        esac
        i=$(( i + 1 ))
    done
    sendkey ret
}
```

### Looking Glass evaluator: `sendkey period` / `sendkey dot` does not produce `.`

When the Looking Glass JS evaluator (`Alt+F2 → lg`) has focus, QEMU `sendkey period`
and `sendkey dot` do not insert a literal `.` into the input field. The keystroke
is either silently dropped or the Clutter-based evaluator widget does not handle
it the same way a normal text input would. As a result, chained property access
like `Main.overview.toggle()` ends up as `Mainoverviewtoggle()` — the dots are
missing — and throws `ReferenceError`.

**Workaround:** no reliable `sendkey` fix has been found for this. Use the Super
key approach instead (`key_leftmeta` from a focused app window). If Activities
needs to be opened from inside Looking Glass, close LG first (`sendkey esc`),
return focus to a terminal window, then use `sendkey key_leftmeta`.

**Note on previous success:** `Main.overview.toggle()` via Looking Glass was
successfully used in an earlier session where the dots registered. The difference
may be focus state, GNOME Shell version, or timing — it is not reliable enough to
depend on.

---

### Super key (key_leftmeta) only works when an app window has focus

**This is the biggest gotcha.** `sendkey key_leftmeta` triggers GNOME Activities
**only** when some app window (terminal, browser, etc.) has keyboard focus.
When on the bare desktop with no windows open, GNOME Wayland does not receive
the key event at all — sendkey goes nowhere. Same for Ctrl+Alt+T, hot-corner
mouse move, and typing-to-search.

**Implication:** once you close all windows and land on the empty desktop, you
are stuck. You cannot get back to Activities or open a terminal via QEMU input.
**Reboot** to get a fresh session with livesys-gnome auto-opening Activities.

**Rule:** never close all windows. Always keep at least one terminal open.
Use `terminal &` background launches so the original terminal stays usable.

---

## Mouse Input

### mouse_move coordinates

With `-device usb-tablet`, `mouse_move X Y` takes absolute pixel coordinates
matching the VNC framebuffer resolution (1280×800 in the default live ISO setup).
Coordinates are zero-indexed from the top-left.

### Left click

```bash
printf "mouse_button 1\n" | socat - "UNIX-CONNECT:$SOCK" >/dev/null  # press
printf "mouse_button 0\n" | socat - "UNIX-CONNECT:$SOCK" >/dev/null  # release
```

Always send both press (1) and release (0). Failing to release causes the guest
to think the button is held down.

### Right click

```bash
printf "mouse_button 2\n" | socat - "UNIX-CONNECT:$SOCK" >/dev/null  # press
printf "mouse_button 0\n" | socat - "UNIX-CONNECT:$SOCK" >/dev/null  # release
```

Button mask: 1=left, 2=right, 4=middle (bitmask, can combine).

### Single vs double click

GNOME Activities icons launch on a **single** click. Double-clicking usually
works too but can cause two launches. Use single click with a short sleep after.

### Dock icons in Activities don't respond to QEMU pointer events

Clicking on dock (dash-to-dock) icons while inside the GNOME Activities overview
produces no response via QEMU `mouse_button`. This appears to be how the Shell
compositor routes pointer events to the Clutter layer for the dash-to-dock
extension vs. the standard Wayland surface layer.

**Workaround:** use Activities search + Enter to launch apps instead of clicking
dock icons. To check the running-app dock icon appearance, open Activities via
`sendkey key_leftmeta` (requires an app window to be focused first) and observe
the workspace switcher.

### PowerShell dock identity — confirmed working

When launched from Activities search → Enter, the GNOME Terminal window title
bar shows **"PowerShell"** (not "Terminal"). This confirms that the D-Bus service
file with `app-id=org.azurelinux.PowerShell` is correctly wiring the gnome-terminal
instance to the PowerShell `.desktop` entry. GNOME Shell uses the window title /
app-id to assign dock grouping, so the PowerShell icon in the dock will group
this window correctly.

Note: verifying the dock icon itself (not just the title) requires a real boot
session — QEMU `key_leftmeta` only works when an app window has focus, and once
Activities is opened, `key_leftmeta` stops toggling it back reliably from QEMU
monitor.

### Running-app dot indicator — not verifiable via QEMU screendump

GNOME Shell renders a small dot (or short line depending on GNOME Shell theme)
below each running app's icon in the dash/dock to indicate it has an open
window. This "running dot" or "running indicator" is:

- A subtle pixel-level rendering detail positioned just under each dock icon
- **Not verifiable through QEMU `screendump` + pixel analysis** because the
  screendump captures at display resolution, the dot is very small, and
  screendump quality in the QEMU software renderer (without proper DRM output)
  is too lossy to reliably detect it
- Also not verifiable via Activities search, keyboard navigation, or SSH — it's
  a visual indicator only

**Practical implication:** whether the PowerShell dock icon shows a running dot
when PowerShell is active can only be confirmed via direct visual inspection of
a real boot session (physical or VM with VGA passthrough / proper display
output). This is not a blocker for any functional check — the app identity
(title bar, D-Bus app-id) is verifiable via SSH and has been confirmed correct.
The dot is cosmetic confirmation that the dock grouping is correct.

**What IS verifiable in QEMU:** that the title bar reads "PowerShell" (not
"Terminal") confirms correct app-id wiring, which is what the dock uses for
grouping and the running-indicator logic. If the app-id is correct, GNOME will
render the running dot against the right dock slot.

The GNOME dock (dash-to-dock) is configured with `intellihide` — it hides when
a window overlaps it. On the bare desktop it **only appears inside the Activities
overview**, not on the plain desktop. The dock does not reveal itself by moving
the mouse to the screen edge from outside Activities.

To reach dock icons without a keyboard Super key:
- Keep an app window open, then `sendkey key_leftmeta` (Super) from inside the
  window to toggle Activities
- Or click the Activities pill (workspace indicator) in the top-left of the
  top bar (~30, 15) — this works when GNOME shell has focus

---

## GNOME Activities and Search

### Auto-open on first boot

`livesys-gnome` opens the Activities overview automatically on the first boot of
a live session. The search box is pre-focused — type immediately, no click needed.
This is the best window to grab dock icons.

### Search opens Terminal/Edit/.NET/PowerShell

Searching "terminal" from Activities returns four icons in this order:
1. Terminal (GNOME Terminal, black `>_` icon)
2. Edit (Microsoft Edit, teal/green diamond)
3. .NET (purple/teal diamond)
4. PowerShell (purple terminal icon)

Press **Enter** to launch the first result (Terminal). Clicking icons directly
from QEMU is unreliable — Enter is more reliable for the first result.

### Terminal launches PowerShell as default shell

GNOME Terminal opens with `PowerShell 7.x.x` as the login shell (`PS /home/liveuser>`
prompt). This is correct — our `/etc/passwd` sets `pwsh` as the default shell for
`liveuser`.

### PowerShell gotcha: `--` in commands

PowerShell intercepts `--` as parameter delimiters. `gh--version` is parsed as a
single token; `gh --version` requires an actual space character typed with
`sendkey spc` (not part of a `fold -w1` loop, which eats spaces — see keyboard
section). Always verify typed commands in the screenshot before waiting for output.

---

## App-specific Notes

### edit (Microsoft Edit)

Launches as a **TUI** (terminal UI) inside GNOME Terminal — not a separate GTK
window. The Terminal window title changes to `Untitled-1.txt - edit`. Close with
**Ctrl+Q**. The `.desktop` icon and search icon both show the correct teal
Microsoft Edit logo.

### VS Code Insiders

Launch: `code-insiders --no-sandbox &` (the `--no-sandbox` flag is required in
the live OverlayFS environment; without it the sandbox setup may fail).
Shows "Welcome to VS Code / Sign in to use GitHub Copilot" on first launch. ✅

### GitHub Desktop

Launch: `github-desktop &`. The process starts and creates a window (visible as
a dark gray rectangle in QEMU). The window content does **not** render under
QEMU virtio-vga/Wayland — the Electron renderer produces a blank canvas.
This is a QEMU test environment limitation; GitHub Desktop renders correctly on
real hardware. The blank window confirms the process starts successfully.

### Microsoft Edge Canary

Launch: `microsoft-edge-canary --no-sandbox &`. Renders correctly in QEMU Wayland
(unlike GitHub Desktop). Shows "Welcome to Microsoft Edge" first-run dialog. ✅

### dotnet

`dotnet --version` fails in QEMU with the default CPU model:
```
Fatal error.
The current CPU is missing one or more of the following instruction sets:
SSE, SSE2, SSE3, SSSE3, SSE4.1, SSE4.2, POPCNT
```
**Fix:** launch QEMU with `-cpu host`. This passes through the host CPU's
extensions (any modern x86_64 host has these). Alternatively, use
`-cpu qemu64,+sse4.1,+sse4.2,+popcnt` if host passthrough is not desired.
This is a QEMU test environment limitation — .NET runs fine on real hardware.

### gh / GitHub CLI

`gh --version` works fine in PowerShell with proper spacing. Output:
`gh version 2.96.0 (2026-07-02)`. ✅

### copilot (GitHub Copilot CLI)

`copilot --version` works. First run takes ~6 seconds for package extraction.
Output: `GitHub Copilot CLI 1.0.73.` ✅

---

## Timing

| Phase | Typical duration (QEMU KVM, 8G RAM) |
|---|---|
| UEFI POST → GRUB | ~3s |
| GRUB timeout | 1s |
| Plymouth (logo + dots) | ~65s |
| Plymouth → black | ~2s |
| GNOME shell loading | ~5s |
| GNOME Activities visible | ~75s total from power-on |

Serial log only shows UEFI output (GRUB and Linux don't redirect to ttyS0 with
`quiet rhgb`). Use screendump polling or `boot-monitor.py` to track Plymouth
and GNOME phases.

---

## Common Failure Modes and Recovery

| Symptom | Cause | Recovery |
|---|---|---|
| "Display output is not active" | Guest in UEFI/GRUB, OR guest reset | Wait for boot, or check serial log; reboot QEMU if stuck |
| All-black screendump, no message | Plymouth running (display initializing) | Normal — wait |
| key_leftmeta does nothing | No app window focused | Keep terminal open; reboot if all windows closed |
| `sendkey` types wrong char | Timing too fast | Increase sleep between sendkeys (0.07–0.12s works) |
| App launches but window is gray | Electron/Wayland/virtio-vga render failure | QEMU-only issue; test binary presence instead |
| Guest OOM reset | Flatpak install in 4G VM | Use 8G RAM; `--no-static-deltas` does not help with OverlayFS space issue |
| VNC "Address already in use" | Previous QEMU released port slowly | Wait 2s after kill before relaunching |
| Terminal prompt missing after launch | App launched in foreground | Always use `appname &` for GUI apps from terminal |
| `Main.overview.toggle()` fails in Looking Glass (`ReferenceError`) | `sendkey period`/`sendkey dot` drops `.` in Clutter evaluator widget | Close LG (`esc`), return focus to terminal, use `sendkey key_leftmeta` instead |

---

## Installer ISO interactive testing limitations (headless VNC + screendump)

Unlike the live ISO and live qcow2 where GNOME Shell renders rich graphical
content easily captured by screendump, the installer ISO presents unique
challenges in a headless VNC + screendump environment:

- **Plymouth covers tty0 during boot**: the boot splash (dark background +
  animated dots) fills the VGA framebuffer. The screendump captures an almost
  entirely black image (~98% dark pixels). The 1–2% bright pixels are Plymouth
  animation dots — too small and low-contrast for reliable progress detection.

- **Anaconda TUI is console-mode, not graphical**: Anaconda in `--text` mode
  renders a curses UI on the Linux console (tty1). This is NOT a graphical
  framebuffer scene — screendump captures the VGA text-mode canvas, which
  maps inconsistently to pixel colors in the VNC framebuffer.

- **Interaction timing is opaque**: the boot sequence goes
  GRUB → kernel → Plymouth → squashfs mount (slow, ~2–5 min for 2.9 GB) →
  autologin → `bash_profile` → `anaconda-launcher.sh` → username prompt.
  Without serial console output (installer uses `console=tty0 rhgb quiet`)
  or a GUI window, knowing when to send username/password input is not
  reliable.

**Recommended approach for installer ISO verification:**

1. **Static filesystem verification** (mount the squashfs): mount the installer
   ISO's `LiveOS/squashfs.img`, then its `LiveOS/rootfs.img`, and inspect the
   installer rootfs directly. Verify kickstart content, file permissions, and
   scripts without booting. This is reliable and reproducible headlessly.

2. **Full interactive test** requires a display: use `scripts/qemu-test-install-iso.sh`
   (uses `-display gtk`) from a machine with a GUI. Alternatively, use `-vnc :N`
   with a real VNC viewer (e.g. `vncviewer`) that provides live video.

3. **Serial console workaround (advanced)**: boot the installer ISO in QEMU with
   `-nographic -serial mon:stdio` after temporarily patching the GRUB entry to
   remove `terminal_output gfxterm` and add `console=ttyS0,115200`. Not worth
   modifying a production ISO; use this only for debugging specific early-boot
   issues on a development build.

**GRUB config note**: the installer ISO's GRUB uses `timeout=5`. If the screen
appears frozen with GRUB rendered (1280×800, ~2% bright pixels), it's likely NOT
stuck — Plymouth has started and the installation is proceeding. The GRUB menu
auto-selects after 5 seconds; screendump won't show clear transition because
Plymouth immediately fills the VGA framebuffer with the dark splash.


---

## VNC framebuffer capture vs `screendump` (2026-07-24)

`screendump` via the QEMU monitor **does not reliably capture the GNOME Wayland
session** once Mutter/Wayland takes over the virtio-gpu DRM device. The command
writes a valid PPM file (correct dimensions) but the content is all-black after
GNOME has initialized. Plymouth screendumps work because Plymouth runs before
Wayland takes over.

**Use a direct VNC client capture instead:**

```python
import socket, struct
from PIL import Image

def vnc_grab(port, outfile):
    s = socket.create_connection(('localhost', port), timeout=15)
    s.settimeout(20)
    ver = s.recv(12); s.send(b'RFB 003.008\n')
    n = struct.unpack('B', s.recv(1))[0]; types = s.recv(n) if n else b''
    s.send(struct.pack('B', 1)); s.recv(4)  # security result
    s.send(struct.pack('B', 1))             # ClientInit shared=1
    w, h = struct.unpack('>HH', s.recv(4)); s.recv(16)
    name_len = struct.unpack('>I', s.recv(4))[0]; s.recv(name_len)
    # Request full framebuffer update
    s.send(struct.pack('>BBHHHH', 3, 0, 0, 0, w, h))
    msg_type = struct.unpack('B', s.recv(1))[0]; s.recv(1)
    n_rects = struct.unpack('>H', s.recv(2))[0]
    pixels = bytearray(w * h * 4)
    for _ in range(n_rects):
        x, y, rw, rh, enc = struct.unpack('>HHHHi', s.recv(12))
        if enc == 0:  # Raw encoding
            size = rw * rh * 4; data = b''
            while len(data) < size:
                data += s.recv(min(16384, size - len(data)))
            for row in range(rh):
                for col in range(rw):
                    px = (y+row)*w + (x+col)
                    pixels[px*4:(px+1)*4] = data[(row*rw+col)*4:(row*rw+col+1)*4]
    s.close()
    Image.frombytes('RGBA', (w,h), bytes(pixels)).convert('RGB').save(outfile)
```

This captures the actual VNC framebuffer stream, which reflects what the
virtio-gpu DRM device is rendering. The image will be in BGR byte order for
virtio-gpu; swap channels when saving if colors look wrong (swap `[i]` and
`[i+2]` when writing the PPM).

**qcow2 architecture note**: the live qcow2 (`azurelinux-desktop-live.qcow2`)
is an *installed disk image*, not a live-ISO overlay. `livesys.service` has
`ConditionKernelCommandLine=rd.live.image` and will not run from a disk image
(no `rd.live.image` in the GRUB cmdline). `liveuser` is therefore pre-created
at build time by the disk-image-specific `%post` block in the workflow. GDM
autologin (`AutomaticLogin=liveuser`) in `/etc/gdm/custom.conf` then works as
expected. The GNOME session loads with the system dconf dark mode and wallpaper
settings from `/etc/dconf/db/local.d/`.

**Expected colors for color analysis:**

| State | avg (R,G,B) | Notes |
|---|---|---|
| All black (blank/screensaver) | (0,0,0) | Power-save or Plymouth off |
| Plymouth active | ~(10,10,10) +dots | Dark background, bright spinner |
| GNOME desktop (dark wallpaper `adwaita-d.jpg`) | ~(12,30,70) | Deep navy blue |
| GNOME desktop (light wallpaper `adwaita-l.jpg`) | ~(3,63,222) | Bright blue |
| GDM login greeter | dark + centered element | Check center vs bg variance |
