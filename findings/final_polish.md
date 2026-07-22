# Live ISO final-polish issues

## Fix execution tracker (2026-07-22)

This section tracks the current polish fixes split into:

- **(a) local container/overlay-verifiable fixes**
- **(b) full image rebuild/runtime-verification fixes**

### (a) Local container/overlay-verifiable fixes (completed locally)

| Fix | Change applied | Local verification run | Result |
| --- | --- | --- | --- |
| `.NET` launcher desktop entry validity | `assets/desktop/dotnet.desktop` now calls `Exec=/usr/local/bin/azl-dotnet-terminal`; new helper `assets/bin/azl-dotnet-terminal`; staged by both live and installer `%post --nochroot` asset copy blocks | `desktop-file-validate assets/desktop/dotnet.desktop`; `shellcheck assets/bin/azl-dotnet-terminal` | **Pass** (entry validates; helper lints cleanly) |
| Installer-created admin default shell | `kiwi/anaconda-launcher.sh` now injects `user ... --shell=/usr/bin/pwsh` | Static generated-directive check in source + `shellcheck kiwi/anaconda-launcher.sh` | **Pass** (directive corrected in source; script lints cleanly) |
| PowerShell app-id launch race hardening | Added `assets/dbus/org.azurelinux.PowerShell.service`; simplified `assets/bin/azl-powershell-terminal` to rely on D-Bus activation; staged in live+installer asset copy blocks | `shellcheck assets/bin/azl-powershell-terminal` plus repo-policy/installroot preflight scripts below | **Pass** (syntax and staging paths validated locally; runtime dock indicator still requires rebuilt-image GUI boot) |
| Repo policy and package-set integrity after launcher/shell changes | No package-list drift introduced by current polish edits | `./scripts/test-container-repos.sh`; `./scripts/podman-test-azl4-fedora.sh`; `./scripts/test-installer-runtime-resolve.sh /home/fedora/azl-work/installer-runtime-resolve-20260722-1712`; `./scripts/test-hybrid-container-local.sh` | **Pass** (all four completed; no resolver breakage from this fix set) |

### (b) Full rebuild/runtime-verification fixes (shipped to GitHub Actions)

These need rebuilt artifacts and GUI/runtime boot validation, not just static/container checks:

- PowerShell dock active-indicator ownership (`org.azurelinux.PowerShell` vs `org.gnome.Terminal`)
- `.NET` GNOME icon visibility in live and installed sessions
- Installer-created administrator default shell behavior in the first installed boot/session
- Plymouth boot behavior and logo composition
- Live-session Flatpak writable-space behavior

**Local preflight before dispatch:**

- `./scripts/test-container-repos.sh` → pass
- `./scripts/podman-test-azl4-fedora.sh` → pass
- `./scripts/test-installer-runtime-resolve.sh /home/fedora/azl-work/installer-runtime-resolve-20260722-1712` → pass
- `./scripts/test-hybrid-container-local.sh` → pass
- `./scripts/test-installer-kiwi-build.sh /home/fedora/azl-work/installer-kiwi-local-20260722-1718` → failed locally at KIWI bind-mount `/dev` step under this host/container combination (`KiwiMountKernelFileSystemsError` mounting `/workspace/.../image-root/dev`), so authoritative verification moved to GitHub Actions build path.

**GitHub Actions dispatch status (full-rebuild category):**

- `release-live-iso.yml` (ISO-only requested): https://github.com/sirredbeard/azurelinux-desktop/actions/runs/29960854444  
  Status at dispatch check: `pending` (head SHA `2c71482355922e6d34937a7b3736ed3aa9fbbb22`)
- `release-installer-iso.yml`: https://github.com/sirredbeard/azurelinux-desktop/actions/runs/29960854403  
  Status at dispatch check: `in_progress` (head SHA `2c71482355922e6d34937a7b3736ed3aa9fbbb22`)

Result capture plan for this same tracker section after completion:

1. Record workflow conclusion, failed/blocked step (if any), and retained log excerpt location.
2. Record artifact verification steps executed with project scripts.
3. Record per-fix runtime outcome (`passed`, `regressed`, or `needs follow-up`) for:
   - PowerShell dock identity
   - `.NET` launcher/icon visibility
   - installer-created admin default shell
   - any Plymouth/Flatpak checks included in the produced artifacts

This is the user-facing QA record for the `2026.07.22` live ISO. The live
session booted in GUI QEMU with UEFI, 8 GiB RAM, and a USB tablet. Dark mode,
automatic `liveuser` login, input, and the expected custom applications work.
The remaining work below is about the parts people see first and the ability
to install a small Flatpak in the live session.

## Issue: boot-time text before Plymouth

**Observed:** Firmware and boot-manager status lines are visible on the black
screen before Plymouth starts. The screenshot shows UEFI `BdsDxe` messages
while loading the QEMU DVD boot entry.

**What this is not:** The visible screenshot does not show the older
`get_url_handler: command not found` livenet message. That known dracut
ordering bug was patched in the live-root build path, but it needs a
read-only initramfs check and a fresh boot-log check before calling it fully
closed.

**Likely cause:** OVMF writes boot status to the framebuffer before the
kernel has initialized Plymouth. The live ISO's hidden GRUB configuration
reduces menu exposure, but it cannot hide firmware output that occurs before
GRUB and the kernel.

**On-disk evidence:** The live root selects `Theme=azurelinux`, but the live
initramfs has only the stock commented `plymouthd.conf` and the stock
`details` theme. It does not contain the Azure theme files. Therefore the
published live initramfs cannot select the configured Azure theme during the
early-boot phase; a later root-mounted Plymouth instance can still load it.

**Tried:** Hidden GRUB timeout, `rhgb quiet`, the Azure Plymouth theme in the
root filesystem, and the target-root livenet hook patch.

**Next options:**

1. Confirm the exact lines with a serial/boot log and separately verify that
   the rebuilt initramfs has no bare pre-source `get_url_handler` call.
2. Keep the unavoidable short OVMF firmware text in QEMU if it is only a
   test-VM artifact. Test physical UEFI hardware before treating it as a
   shipped-image regression.
3. If GRUB or kernel text remains after firmware hand-off, tighten the
   relevant boot arguments or Plymouth initramfs inclusion instead of
   suppressing diagnostic output blindly.



## Plymouth Boot-Splash Remediation Report — Azure Linux Desktop Derivative

### Executive Summary

Four distinct Plymouth issues are present in this project. Issues 2 and 3 share the same root cause: `console=ttyS0,115200` in kernel cmdlines causes Plymouth's device manager to unconditionally force text/details mode and skip all graphical renderer setup. Issue 1 is a GRUB console configuration problem that can be fixed with a single `grub_template.cfg` patch. Issue 4 requires adding a proportional scale function to the Plymouth `.script` file.

---

### Repositories Discovered

| Repo | Purpose |
|------|---------|
| `microsoft/azurelinux` | AZL base: `specs/p/plymouth/`, `base/comps/azurelinux-logos/`, `base/images/vm-iso-installer/` |
| `dracutdevs/dracut` | `modules.d/50plymouth/` — initramfs Plymouth packaging logic |
| `weldr/lorax` | lorax templates for Fedora installer ISO (reference only — this project uses KIWI) |
| `rhinstaller/anaconda` | dracut hooks, `anaconda-lib.sh` |
| `gitlab.freedesktop.org/plymouth/plymouth` | Plymouth source: `src/main.c`, `src/libply-splash-core/ply-device-manager.c`, `themes/script/script.script` |
| Local: `/home/fedora/azl-work/azurelinux` | AZL base + plymouth.spec with AZL-specific patches |
| Local: `/home/fedora/azurelinux-desktop-artifacts/` | CI build artifacts: ISOs, kickstart, build logs |

---

## Issue 1 — UEFI Firmware Text (BdsDxe) Before Plymouth

### Root Cause

The GRUB template at `base/images/vm-iso-installer/grub_template.cfg` uses:

```
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_output console serial
terminal_input console serial
```

`terminal_output console` keeps GRUB in text/VGA-text mode. The BdsDxe messages (`BdsDxe: loading ...`, `BdsDxe: starting ...`) are UEFI firmware messages emitted before GRUB loads — they can't be suppressed at the UEFI level without firmware vendor support. However, `terminal_output console` keeps the VGA text mode active through GRUB, so when the kernel takes over there is no framebuffer mode set, and the EFI GOP mode (needed for Plymouth DRM rendering) is not pre-loaded by GRUB. This also means GRUB's own `echo 'Loading kernel...'` lines appear as text.

The lorax Fedora reference config correctly uses:
```
insmod efi_gop
insmod efi_uga
insmod all_video
set gfxpayload=keep
```
which switches GRUB to graphical mode, keeping a clean GOP framebuffer for Plymouth. GRUB also calls `clear` internally after switching to gfxterm, hiding the prior firmware text.

### Remediation

**`base/images/vm-iso-installer/grub_template.cfg`** — add GOP/graphical mode before menuentry blocks:

```grub
set default=0
set timeout=${boot_timeout}

# ── Graphical console (hides pre-GRUB BdsDxe text, keeps EFI framebuffer) ──
insmod efi_gop
insmod efi_uga
insmod all_video
set gfxmode=auto
set gfxpayload=keep
terminal_output gfxterm
# Clear the screen immediately after GRUB takes it; removes BdsDxe text
clear

# ── Serial I/O for headless/debug access ──
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
# NOTE: do NOT add 'serial' to terminal_output — that reverts to text mode

menuentry "Install Azure Linux 4.0" --class os {
    search ${search_params}
    linux ($$root)/${bootpath}/${kernel_file} ${boot_options} azl.autoinstall inst.nosave=all_ks
    initrd ($$root)/${bootpath}/${initrd_file}
}

menuentry "Try Azure Linux 4.0 (Live)" --class os {
    search ${search_params}
    linux ($$root)/${bootpath}/${kernel_file} ${boot_options} inst.nosave=all_ks
    initrd ($$root)/${bootpath}/${initrd_file}
}
```

Key points:
- `terminal_output gfxterm` alone (no `console`) switches GRUB into graphical mode, which executes `clear`, wiping BdsDxe text from the framebuffer.
- `set gfxpayload=keep` tells the kernel to inherit the framebuffer mode GRUB negotiated with the EFI GOP driver — this is what lets Plymouth's DRM/simpledrm renderer find a display immediately on boot.
- `terminal_input serial console` keeps serial as an input source for interactive rescue menus without the output reverting to text mode.
- Remove the `echo 'Loading kernel...'` / `echo 'Loading initrd...'` lines — they serve no purpose with gfxterm and add visible text flicker.

**Citation:** `weldr/lorax:share/templates.d/99-generic/live/config_files/x86/grub2-efi.cfg`  
**Citation:** `weldr/lorax:share/templates.d/99-generic/live/config_files/x86/grub2-bios.cfg`

---

## Issue 2 — No Plymouth During Installer ISO Boot

### Root Cause Analysis

**A. `console=ttyS0,115200` forces Plymouth text mode (primary cause)**

The KIWI `.kiwi` file at `base/images/vm-iso-installer/vm-iso-installer.kiwi` sets:
```xml
kernelcmdline="console=ttyS0,115200 console=tty0 enforcing=0 audit=0 inst.text inst.lang=en_US.UTF-8 inst.nokill"
```

Plymouth reads `/sys/class/tty/console/active` at startup. With `console=ttyS0,115200 console=tty0`, both `ttyS0` and `tty0` are listed. Plymouth's device manager (`ply-device-manager.c`) runs:

```c
// ply-device-manager.c (create_devices_from_terminals)
has_serial_consoles = add_consoles_from_file(manager, "/sys/class/tty/console/active");

if (has_serial_consoles) {
    ply_trace("serial consoles detected, managing them with details forced");
    manager->serial_consoles_detected = true;
    ply_hashtable_foreach(manager->terminals,
                          create_devices_for_terminal, manager);
    return true;   // ← EARLY RETURN: no DRM/udev setup happens
}
```

`add_consoles_from_file` marks `has_serial_consoles = true` for any console that is not `local_console_terminal` (tty0). Finding `ttyS0` → `serial_consoles_detected = true` → function returns `true` → `ply_device_manager_watch_devices()` returns immediately after calling `create_devices_from_terminals()` without ever scanning DRM/framebuffer devices. The graphical theme is never loaded.

**Citation:** `gitlab.freedesktop.org/plymouth/plymouth/-/raw/main/src/libply-splash-core/ply-device-manager.c` (offset ~46000: `create_devices_from_terminals`)

**B. Initramfs built in generic (non-hostonly) mode — no custom theme**

KIWI's dracut invocation for ISO images uses `--no-hostonly` (generic) mode. In this mode, dracut's `50plymouth/plymouth-populate-initrd.sh` only bundles `text` and `details` themes:

```bash
# dracutdevs/dracut modules.d/50plymouth/plymouth-populate-initrd.sh
if [[ $hostonly ]]; then
    # hostonly: install the configured theme
    inst_multiple "/usr/share/plymouth/themes/details/details.plymouth" \
                  "/usr/share/plymouth/themes/text/text.plymouth"
    if [[ -d $dracutsysrootdir/usr/share/plymouth/themes/${PLYMOUTH_THEME} ]]; then
        for x in "/usr/share/plymouth/themes/${PLYMOUTH_THEME}"/*; do
            inst "$x"
        done
    fi
    ...
else
    # generic: ONLY text + details
    for x in "$dracutsysrootdir"/usr/share/plymouth/themes/{text,details}/*; do
        inst_multiple "${x#"$dracutsysrootdir"}"
    done
    (cd "${initdir}"/usr/share/plymouth/themes || exit
     ln -s text/text.plymouth default.plymouth 2>&1)
fi
```

**Citation:** `dracutdevs/dracut:modules.d/50plymouth/plymouth-populate-initrd.sh`

The runtime squashfs (`/etc/plymouth/plymouthd.conf` showing `Theme=azurelinux`) is NOT the initramfs — Plymouth runs from the initrd during the initramfs phase, before the squashfs is mounted. Even if the runtime root has the azurelinux theme, the initramfs Plymouth process never sees it.

**C. `inst.text` alone does NOT suppress Plymouth**

`inst.text` instructs Anaconda to use the text-mode TUI. It does not set `rd.plymouth=0` and does not directly affect Plymouth. Plymouth's graphical splash could theoretically run during initramfs even with `inst.text`. The serial console detection above is what actually suppresses it.

**Citation:** `rhinstaller/anaconda:dracut/parse-anaconda-options.sh` (reviewed — no Plymouth manipulation for `inst.text`)

### Remediation Options

**Option A — Disable Plymouth on installer boot (simplest, appropriate for TUI installer)**

In `vm-iso-installer.kiwi`, change:
```xml
kernelcmdline="console=ttyS0,115200 console=tty0 enforcing=0 audit=0 inst.text inst.lang=en_US.UTF-8 inst.nokill"
```
to:
```xml
kernelcmdline="console=ttyS0,115200 console=tty0 enforcing=0 audit=0 inst.text inst.lang=en_US.UTF-8 inst.nokill rd.plymouth=0"
```

`rd.plymouth=0` disables Plymouth entirely during installer boot (checked by dracut's `plymouth-pretrigger.sh`). The `details` fallback text mode then does not appear either. This is correct for a headless TUI installer.

**Citation:** `dracutdevs/dracut:modules.d/50plymouth/plymouth-pretrigger.sh`:
```bash
if type plymouthd > /dev/null 2>&1 && [ -z "$DRACUT_SYSTEMD" ]; then
    if getargbool 1 plymouth.enable && getargbool 1 rd.plymouth -d -n rd_NO_PLYMOUTH; then
```

**Option B — Graphical Plymouth on installer (if live-ISO-style splash is wanted)**

1. Add the `azurelinux` Plymouth theme files into the installer kiwi image during `config.sh`. Since `$ASSETS` is only available in the Anaconda `%post --nochroot` environment and not during the KIWI build, the theme files need to be sourced separately in `config.sh`. Add a theme tarball as a KIWI overlay or download it:

```bash
# In config.sh, after dnf5 download step:
mkdir -p /usr/share/plymouth/themes/azurelinux
# Stage theme files here (from a source available at build time)
cp /path/to/azurelinux.plymouth /usr/share/plymouth/themes/azurelinux/
cp /path/to/azurelinux.script   /usr/share/plymouth/themes/azurelinux/
cp /path/to/azurelinuxlogo.png  /usr/share/plymouth/themes/azurelinux/
cp /path/to/dot.png             /usr/share/plymouth/themes/azurelinux/
cp /path/to/dot-glow.png        /usr/share/plymouth/themes/azurelinux/
# Set as default and regenerate initramfs
plymouth-set-default-theme azurelinux
dracut --force  # Regenerates with hostonly=no, but will now find the theme
```

2. Remove `console=ttyS0,115200` from `kernelcmdline` in the KIWI installer image type OR add `plymouth.ignore-serial-consoles` (if this option exists in the installed version — see Note below):
```xml
kernelcmdline="console=tty0 enforcing=0 audit=0 inst.lang=en_US.UTF-8 inst.nokill quiet rhgb"
```

> **Note on `plymouth.ignore-serial-consoles`**: The C flag `PLY_DEVICE_MANAGER_FLAGS_IGNORE_SERIAL_CONSOLES` is set by `plymouthd`'s own command-line argument `--ignore-serial-consoles`, not by a kernel parameter. To activate it via systemd/dracut without modifying `plymouth-pretrigger.sh`, create a dracut module overlay that adds `--ignore-serial-consoles` to the `plymouthd` invocation. Alternatively, the `plymouthd.defaults` approach via a custom `plymouthd.conf` does not have this option — patching `plymouth-pretrigger.sh` is required:
```bash
plymouthd --attach-to-session --ignore-serial-consoles --pid-file /run/plymouth/pid
```

---

## Issue 3 — No Plymouth on First Boot of Installed System

### Root Cause Analysis

**A. `console=ttyS0,115200` in installed BLS entry (primary cause)**

The kickstart at `installer-ci-2026.07.20-run29738789973/azurelinux-desktop-install-kickstart/final-kickstart.ks` contains:
```
bootloader --location=mbr --append="console=ttyS0,115200 console=tty0"
```

Anaconda writes this directly into the installed system's BLS entry. The same Plymouth serial console detection logic as Issue 2 applies: on every boot of the installed system, `/sys/class/tty/console/active` contains `ttyS0`, `has_serial_consoles = true`, graphical renderer setup is skipped, and Plymouth shows the text `details` theme regardless of what's in the initramfs.

This is why the user sees no Plymouth even though the initramfs correctly contains the `azurelinux` theme (placed there by `dracut --regenerate-all --force` in the kickstart `%post`).

**B. `virtio_gpu`-only `early-kms.conf` — incomplete for all VM types**

The kickstart `%post` adds:
```bash
cat > /etc/dracut.conf.d/early-kms.conf << 'EOF'
add_drivers+=" virtio_gpu "
EOF
```

For QEMU std VGA (`[1234:1111]`, confirmed from `standard-install-attempt.serial.log`), `virtio_gpu` is not the correct driver. The standard QEMU VGA presents as `bochs-drm` (if enabled) or falls back to `simpledrm` via the EFI GOP framebuffer. For Hyper-V, the correct driver is `hyperv_drm`.

However: even with the correct DRM driver, the Plymouth serial-console short-circuit means the graphical path is never attempted (Issue A is dominant).

**C. AZL plymouth spec already provides `UseSimpledrmNoLuks=1`**

From `specs/p/plymouth/plymouth.spec`:
```bash
%prep
%autosetup -p1 -a 1
sed -i -e 's/spinner/bgrt/g' src/plymouthd.defaults
echo UseSimpledrmNoLuks=1 >> src/plymouthd.defaults
```

**Citation:** `/home/fedora/azl-work/azurelinux/specs/p/plymouth/plymouth.spec:347-352`

This means Plymouth will use the simpledrm EFI framebuffer (`simple-framebuffer.0/drm/card0`) automatically on non-LUKS systems — confirmed by `main.c:load_settings()` which reads this key:
```c
state->use_simpledrm = ply_key_file_get_ulong(key_file, "Daemon", "UseSimpledrmNoLuks", -1);
```
**Citation:** `gitlab.freedesktop.org/plymouth/plymouth/-/raw/main/src/main.c` (offset ~11000)

So the simpledrm path IS already enabled by AZL's `plymouthd.defaults`. After fixing Root cause A, Plymouth will find and use the simpledrm EFI framebuffer on VMs without a native DRM driver.

### Remediation

**Step 1 — Remove serial console from installed BLS entry**

Change the kickstart:
```diff
-bootloader --location=mbr --append="console=ttyS0,115200 console=tty0"
+bootloader --location=mbr
```

A desktop system does not need `console=ttyS0` in the kernel cmdline. Serial `agetty` still runs on `ttyS0` via `serial-getty@ttyS0.service` (already configured in the installer `config.sh`) — that does NOT require `console=ttyS0` in the kernel cmdline. The serial `agetty` autologin in `config.sh` is for the installer live environment; the installed system uses standard systemd getty.

If you need serial console on the installed system for debugging purposes, use the kernel parameter `console=tty0 console=ttyS0,115200` (reversed order, tty0 first) AND pass `--ignore-serial-consoles` to `plymouthd`. The reversed order does not help Plymouth (it still detects ttyS0 in the active list), but the `--ignore-serial-consoles` patch below will:

**`/etc/dracut.conf.d/plymouth-no-serial.conf`** (drop into installed system in kickstart `%post`):
```bash
# Tell Plymouth to not switch to text/details mode when a serial console
# is detected. Requires patching plymouth-pretrigger.sh in the initramfs.
install_items+=" /usr/lib/dracut/modules.d/50plymouth/plymouth-pretrigger.sh "
```

A cleaner approach: patch `plymouth-pretrigger.sh` via a dracut drop-in. Drop this file into the image and reference it in dracut config:

```bash
# /etc/dracut.conf.d/plymouth-ignore-serial.conf
install_optional_items+=" /etc/plymouth/ignore-serial-consoles "
```

Then create `/etc/plymouth/ignore-serial-consoles` (empty file), and add a dracut hook that adds `--ignore-serial-consoles` to plymouthd if this file exists. **However**, the simplest approach for a desktop system is to just remove `console=ttyS0,115200` from the bootloader entry — which is the correct fix.

**Step 2 — Expand early-kms.conf for VM coverage**

Replace the kickstart's `early-kms.conf` snippet:
```bash
cat > /etc/dracut.conf.d/early-kms.conf << 'EOF'
# Early KMS: load GPU drivers in initramfs so Plymouth gets a real DRM device.
# virtio_gpu  — QEMU/KVM with virtio-gpu device
# hyperv_drm  — Hyper-V (Generation 2 VMs)
# bochs-drm   — QEMU std VGA (Bochs-compatible) - note underscores in module
# simpledrm fallback via UseSimpledrmNoLuks=1 in plymouthd.defaults
add_drivers+=" virtio_gpu hyperv_drm bochs_drm "
EOF
```

> For bare-metal, add the appropriate GPU driver (e.g., `i915`, `amdgpu`, `nouveau`).

**Step 3 — Verify theme activation after dracut regeneration**

The kickstart already does:
```bash
if [ -x /usr/sbin/plymouth-set-default-theme ]; then
    plymouth-set-default-theme azurelinux || true
fi
dracut --regenerate-all --force
```

This is correct. `plymouth-set-default-theme azurelinux` writes `Theme=azurelinux` to `/etc/plymouth/plymouthd.conf` and creates the `/usr/share/plymouth/themes/default.plymouth → azurelinux/azurelinux.plymouth` symlink. `dracut --regenerate-all --force` then runs in hostonly mode (the default when called from inside the system), which includes the active theme (per `plymouth-populate-initrd.sh`'s `if [[ $hostonly ]]` branch).

**Verification** — After the fix, confirm in the installed system:
```bash
# Should show the azurelinux theme directory with all assets
lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'plymouth|azurelinux'

# Should return "azurelinux"
plymouth-get-default-plugin  # or: cat /etc/plymouth/plymouthd.conf

# Runtime check (after boot): confirms Plymouth showed the graphical theme
journalctl -b | grep -i plymouth
```

---

## Issue 4 — Plymouth Logo Oversized/Cropped

### Root Cause

The current `azurelinux.script` (referenced via kickstart asset copy, `$ASSETS/plymouth/azurelinux/azurelinux.script`) uses raw centering without bounds checking:
```javascript
// CURRENT (broken for large logos or low-res displays)
logo.sprite.SetX(Window.GetX() + Window.GetWidth()/2 - logo.image.GetWidth()/2);
logo.sprite.SetY(Window.GetY() + Window.GetHeight()/2 - logo.image.GetHeight()/2);
```

When `logo.image.GetWidth() > Window.GetWidth()` (e.g., a 400×400 PNG on an 800×600 EFI framebuffer, or simpledrm running at 1024×768 with a large PNG), the sprite coordinate is negative and the image is cropped.

The `AzureLinuxLogo.png` (20,348 bytes) is likely rendered at its native pixel dimensions. Plymouth script coordinates map 1:1 to screen pixels — there is no automatic downscaling.

### Remediation

Replace the positioning block in `azurelinux.script` with a proportional-scale version. Plymouth's script API provides `Image.Scale(width, height)` which returns a new scaled `Image` object.

**Citation (API examples):** `gitlab.freedesktop.org/plymouth/plymouth/-/raw/main/themes/script/script.script` (uses `progress_bar.original_image.Scale(w, h)` for progress bar scaling)

```javascript
# ── Logo loading and proportional scaling ──────────────────────────────────────

logo.original_image = Image("azurelinuxlogo.png");

# Scale logo to fit within MAX_LOGO_FRACTION of the screen, preserving
# aspect ratio and never upscaling.
MAX_LOGO_FRACTION = 0.30;   # Occupy at most 30% of screen width or height

fun ScaleLogoToFit(img)
{
    local.screen_w = Window.GetWidth();
    local.screen_h = Window.GetHeight();
    local.img_w    = img.GetWidth();
    local.img_h    = img.GetHeight();

    local.max_w = Math.Int(screen_w * MAX_LOGO_FRACTION);
    local.max_h = Math.Int(screen_h * MAX_LOGO_FRACTION);

    # Only scale DOWN, never up.
    if (img_w <= max_w && img_h <= max_h) {
        return img;
    }

    # Uniform scale factor = min(max_w/img_w, max_h/img_h)
    local.scale_w = max_w / img_w;
    local.scale_h = max_h / img_h;
    local.scale   = Math.Min(scale_w, scale_h);

    local.new_w = Math.Int(img_w * scale);
    local.new_h = Math.Int(img_h * scale);

    return img.Scale(new_w, new_h);
}

logo.image = ScaleLogoToFit(logo.original_image);
logo.sprite = Sprite(logo.image);

# ── Refresh callback: re-center after every frame ──────────────────────────────
fun refresh_callback ()
{
    logo.sprite.SetX(Window.GetX() + Math.Int((Window.GetWidth()  - logo.image.GetWidth())  / 2));
    logo.sprite.SetY(Window.GetY() + Math.Int((Window.GetHeight() - logo.image.GetHeight()) / 2));
}
Plymouth.SetRefreshFunction(refresh_callback);
```

**Notes:**
- `Math.Int()` is required — Plymouth script uses floating-point for all arithmetic; sprite positions must be integer.
- `Math.Min()` is available in Plymouth's built-in math library (confirmed in `themes/script/script.script` usage of `Math.Cos`, same library).
- Adjust `MAX_LOGO_FRACTION` to taste. `0.30` (30% of screen) gives a balanced result on 1024×768 EFI framebuffer (≈307×307 px max logo display) and scales gracefully on higher-res displays.
- If the logo has a progress ring or other overlay elements that must be positioned relative to the logo, recalculate their offsets using `logo.image.GetWidth()`/`logo.image.GetHeight()` after scaling (not `logo.original_image.GetWidth()`).
- The script is copied at installer `%post` time via `cp -v "$ASSETS/plymouth/azurelinux/azurelinux.script"`. For live ISO builds, the same asset source applies. The fix belongs in the asset file; no KIWI/kickstart changes needed beyond redeploying the updated `.script`.

---

## Cross-Cutting: How Fedora/livecd-tools/lorax Include Plymouth Themes in Initramfs

This project uses KIWI, not lorax, but the mechanisms are instructive for comparison.

**Lorax (Fedora installer ISO):**
Lorax's `runtime-install.tmpl` explicitly installs `plymouth` as a package (`installpkg plymouth`) into the runtime squashfs. The initramfs is generated by dracut with the runtime squashfs as the chroot root, in **generic** (non-hostonly) mode. This means only `text`/`details` themes go in the initramfs. Fedora resolves this by NOT using a custom theme in the installer — the installer squashfs uses the `bgrt` default, and since the installer is graphical (Anaconda GUI), Plymouth splash is less critical.

**Citation:** `weldr/lorax:share/templates.d/99-generic/runtime-install.tmpl` (line `installpkg plymouth`)
**Citation:** `weldr/lorax:share/templates.d/99-generic/runtime-postinstall.tmpl` (dracut regeneration logic)

**Dracut hostonly vs. generic theme selection:**

| Mode | What themes are bundled |
|------|------------------------|
| Generic (`--no-hostonly`) | `text` + `details` only; `default.plymouth → text/text.plymouth` |
| Hostonly (default from installed system) | `text` + `details` + **active theme** (from `$(plymouth-set-default-theme)`) + its plugin `.so` |

**Key conclusion:** To get a custom theme in an initramfs, dracut MUST run in hostonly mode against a root that already has `plymouth-set-default-theme` set correctly. KIWI's live-image initramfs is generic. To override: explicitly run `dracut --hostonly --force` in `config.sh` after staging the theme files and calling `plymouth-set-default-theme`.

---

## Issue 2 vs. Issue 3: `inst.text` Does NOT Suppress Plymouth

To be explicit: `inst.text` sets `ANACONDA_TEXT=1` inside Anaconda's Python runtime and causes Anaconda to launch the TUI interface rather than the Wayland GUI. It is processed by Anaconda after the switchroot to the runtime squashfs. It does not call `plymouth quit`, does not set `rd.plymouth=0`, and does not otherwise interact with Plymouth during the dracut initramfs phase.

**Citation:** `rhinstaller/anaconda:dracut/parse-anaconda-options.sh` — `inst.text` is not processed here.

---

## Consolidated Fix Checklist

| # | File to change | Change |
|---|---------------|--------|
| 1 | `base/images/vm-iso-installer/grub_template.cfg` | Replace `terminal_output console serial` with `insmod all_video; set gfxmode=auto; set gfxpayload=keep; terminal_output gfxterm; clear`; keep `terminal_input serial console` |
| 2a | `vm-iso-installer.kiwi` `kernelcmdline` | Add `rd.plymouth=0` to disable Plymouth on installer boot (cleanest for TUI installer) |
| 2b *(alt)* | `config.sh` | Stage `azurelinux` theme files; call `plymouth-set-default-theme azurelinux; dracut --hostonly --force` if graphical splash is wanted on installer |
| 3 | `final-kickstart.ks` `bootloader --append` | Remove `console=ttyS0,115200 console=tty0` from the append string for the installed system |
| 3 | `final-kickstart.ks` `%post` dracut | Expand `early-kms.conf` to add `hyperv_drm bochs_drm` alongside `virtio_gpu` |
| 4 | `$ASSETS/plymouth/azurelinux/azurelinux.script` | Replace raw centering with `ScaleLogoToFit()` + `Math.Int()` coordinate clamping |

---

## Relevant Upstream References

- `dracutdevs/dracut:modules.d/50plymouth/module-setup.sh` — Plymouth dracut module; `depends() { echo drm; }` means dracut's `drm` module must be present for Plymouth to include DRM renderers.
- `dracutdevs/dracut:modules.d/50plymouth/plymouth-populate-initrd.sh` — Exact logic for which theme files enter the initramfs.
- `dracutdevs/dracut:modules.d/50plymouth/plymouth-pretrigger.sh` — `plymouthd` startup invocation; the place to add `--ignore-serial-consoles` if needed.
- `gitlab.freedesktop.org/plymouth/plymouth/-/raw/main/src/main.c` — `plymouth_should_show_default_splash()`: returns `true` for `rhgb` or `splash` kernel params; returns `false` for `single 1 s S -S splash=verbose`.
- `gitlab.freedesktop.org/plymouth/plymouth/-/raw/main/src/libply-splash-core/ply-device-manager.c` — `create_devices_from_terminals()`: the serial-console short-circuit; `verify_drm_device()`: simpledrm skip unless `PLY_DEVICE_MANAGER_FLAGS_USE_SIMPLEDRM`.
- `/home/fedora/azl-work/azurelinux/specs/p/plymouth/plymouth.spec:347–352` — AZL sets `UseSimpledrmNoLuks=1` in `plymouthd.defaults`; simpledrm EFI framebuffer enabled by default for non-LUKS systems.
- `/home/fedora/azl-work/azurelinux/specs/p/plymouth/plymouth-24.004.60-use_simpledrm-config.patch` — Backport that adds `UseSimpledrm`/`UseSimpledrmNoLuks` config-file keys; already applied in AZL.
- `microsoft/azurelinux:base/comps/azurelinux-logos/azurelinux-logos.spec` — Installs logo PNGs to `charge/` and `spinner/` Plymouth theme dirs only; does NOT create a standalone `azurelinux` theme. The `azurelinux` theme originates entirely from the `$ASSETS` directory in the CI build pipeline.
- `microsoft/azurelinux:base/comps/plymouth/plymouth.comp.toml` — Disables `plymouth-theme-charge` subpackage (requires `fedora-logos-classic`, absent on AZL).
## Issue: Plymouth logo scale and position

**Observed:** The Azure logo is oversized and cropped at the lower-right
edge of the screen instead of appearing as a centered, proportionate splash.

**On-disk evidence:** The Azure script is byte-identical in the live root,
installer runtime root, and installed target. It already calculates centered
X/Y positions from `Window.GetWidth()` and `Window.GetHeight()`, but uses
the logo's native dimensions without any bounded scaling. The 20,348-byte
`azurelinuxlogo.png` is also identical in all three roots. The screenshot
therefore rules out an artifact mismatch or fixed coordinates, but shows that
the current script is not robust for the display mode used at boot.

**Tried:** The Azure script theme and its current logo asset are included in
the live root. They are not in the live initramfs, so early-boot theme
inclusion remains separately broken.

**Next fix:** Retain the dynamic centering in
`assets/plymouth/azurelinux/azurelinux.script`, add a bounded scale that
preserves the logo aspect ratio, and test small QEMU displays plus normal
hardware. Rebuild, inspect the generated initramfs, then boot at more than
one resolution.



**Research cross-reference:** The full upstream Plymouth boot-splash remediation research, including the corrected proportional-scale script, GRUB/firmware text analysis, and installer/installed initramfs findings, is appended immediately before this section under "Issue: boot-time text before Plymouth".
## Research findings: Azure Linux Desktop — Custom Wallpaper Remediation

### Summary

Every build target (live ISO, KIWI installer kickstart, encrypted-install variant) hard-codes Adwaita as the wallpaper via `/etc/dconf/db/local.d/`. There is no project-owned background asset. The fix is a single new RPM (`azurelinux-desktop-backgrounds`) that owns the image files, the GNOME picker registration XML, and a gschema override; all four build targets then drop their in-line `picture-uri` overrides and `Require:` the RPM instead. The entire Fedora 43 backgrounds packaging chain is already inside `microsoft/azurelinux` and is the right template.

### 1. Where the Problem Lives (All Four Targets)

| Target | File | Lines | Current setting |
|--------|------|--------|-----------------|
| Live ISO | `kickstart/azurelinux-desktop-live.ks` | 706–708 | `adwaita-l.jxl` / `adwaita-d.jxl` via `/etc/dconf/db/local.d/00-dark-mode` |
| Installer (plain) | `kiwi/azl-install.ks.in` | 241–243 | same, `00-azl-desktop-defaults` |
| Installer (encrypted) | `kiwi/azl-install-encrypted.ks.in` | 248–250 | same, `00-azl-desktop-defaults` |
| KIWI installer env | `kiwi/config.sh` | 94 | installs `gnome-backgrounds` but no AZL background, no override |

**Citations:**
- `azurelinux-desktop-iso:kickstart/azurelinux-desktop-live.ks:693-708`
- `azurelinux-desktop-iso:kiwi/azl-install.ks.in:230-254`
- `azurelinux-desktop-iso:kiwi/azl-install-encrypted.ks.in:237-261`
- `azurelinux-desktop-iso:kiwi/config.sh:85-94`

### 2. How Fedora Packages Custom Wallpapers (Canonical Pattern)

The exact model to follow is `desktop-backgrounds` + `f43-backgrounds` as packaged in `microsoft/azurelinux`. The dual-package split is intentional:

#### Package 1 — image files (`NAME-backgrounds-base`)
```
/usr/share/backgrounds/f43/default/f43-01-day.jxl       ← light variant
/usr/share/backgrounds/f43/default/f43-01-night.jxl     ← dark variant
/usr/share/backgrounds/f43/default/f43.xml               ← time-of-day animation (optional)
```
RPM requirement for the JXL loader (soft dep pattern):
```spec
Requires: (jxl-pixbuf-loader if gdk-pixbuf2)
```
**Citation:** `microsoft/azurelinux:specs/f/f43-backgrounds/f43-backgrounds.spec` (f43-backgrounds spec, lines for `%files base` and `Requires:`)

#### Package 2 — GNOME registration (`NAME-backgrounds-gnome`)
Installs to `/usr/share/gnome-background-properties/NAME.xml` — this is the XML that makes the wallpaper appear in GNOME Settings → Background:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">
<wallpapers>
    <wallpaper deleted="false">
        <name>Fedora 43 Default</name>
        <filename>/usr/share/backgrounds/f43/default/f43-01-day.jxl</filename>
        <filename-dark>/usr/share/backgrounds/f43/default/f43-01-night.jxl</filename-dark>
        <options>zoom</options>
        <shade_type>solid</shade_type>
        <pcolor>#51a2da</pcolor>
        <scolor>#294172</scolor>
    </wallpaper>
</wallpapers>
```
**Citation:** `https://raw.githubusercontent.com/fedoradesign/backgrounds/main/default/gnome-backgrounds-f43.xml`

#### Package 3 — gschema override (`desktop-backgrounds-gnome`)
This is what actually sets the *system default* — the override is compiled by `glib-compile-schemas` (triggered by glib2 RPM scriptlet triggers, not by `dconf update`):
```
/usr/share/glib-2.0/schemas/10_org.gnome.desktop.background.fedora.gschema.override
```
Content:
```ini
[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/f43/default/f43-01-day.jxl'
picture-uri-dark='file:///usr/share/backgrounds/f43/default/f43-01-night.jxl'

[org.gnome.desktop.screensaver]
picture-uri='file:///usr/share/backgrounds/f43/default/f43-01-day.jxl'
picture-uri-dark='file:///usr/share/backgrounds/f43/default/f43-01-night.jxl'
```
**Citation:** `microsoft/azurelinux:specs/d/desktop-backgrounds/desktop-backgrounds.spec:150-185` (install section generating the `.gschema.override` files)

The `10_` prefix is significant: it means any higher-numbered override wins (e.g., `30_budgie_…` overrides the base GNOME one). Use a priority number that beats anything upstream but leaves room above for user-specific packages.

### 3. File Paths Convention

| Path | Purpose |
|------|---------|
| `/usr/share/backgrounds/azurelinux/default/azurelinux-l.jxl` | Light wallpaper |
| `/usr/share/backgrounds/azurelinux/default/azurelinux-d.jxl` | Dark wallpaper |
| `/usr/share/gnome-background-properties/azurelinux.xml` | GNOME picker registration |
| `/usr/share/glib-2.0/schemas/10_org.gnome.desktop.background.azurelinux.gschema.override` | System-wide dconf default |
| `/usr/share/backgrounds/default.jxl` → (symlink) | Compat for DEs that use this path (optional) |

The `default.jxl` / `default-dark.jxl` symlinks at `/usr/share/backgrounds/` root are used by LXDE, XFCE, and compat paths. `desktop-backgrounds-compat` already creates them pointing at the Fedora release; AZL can skip those or redirect them.
**Citation:** `microsoft/azurelinux:specs/d/desktop-backgrounds/desktop-backgrounds.spec` (`%files compat` section and the JXL symlink block)

### 4. Image Format: Use JXL (Not WebP or PNG)

The stack has definitively moved to JPEG XL:
- `gnome-backgrounds` 49.0 (the GNOME Adwaita package already installed) ships `.jxl` files. Citation: `microsoft/azurelinux:specs/g/gnome-backgrounds/gnome-backgrounds.spec:37` (`%{_datadir}/backgrounds/gnome/*.{jxl,png,svg}`)
- `f43-backgrounds` ships `.jxl` exclusively with `%global picture_ext jxl`. Citation: `microsoft/azurelinux:specs/d/desktop-backgrounds/desktop-backgrounds.spec:14`
- `sddm` was updated in Feb 2025 specifically to handle JXL. Citation: `microsoft/azurelinux:specs/s/sddm/sddm.spec` (changelog entry "Adapt to backgrounds in JPEG-XL format")
- WebP was dropped from `gnome-backgrounds` at GNOME 45; the spec's own changelog confirms: "Remove webp-pixbuf-loader dep as webp images are no longer installed" (gnome-backgrounds 45~rc-2)
- The JXL loader soft-dep `(jxl-pixbuf-loader if gdk-pixbuf2)` is already pulled in transitively via `gnome-backgrounds`. No additional loader work is needed.

**Recommendation: author the wallpaper as JXL.** PNG is an acceptable fallback if JXL tooling is unavailable, but ship JXL for production. Do not use WebP — it's orphaned upstream.

### 5. Existing Azure Linux Branding Assets

| Asset | Location | Notes |
|-------|----------|-------|
| `AzureLinuxLogo.png` | `azurelinux-desktop-iso/assets/branding/AzureLinuxLogo.png` | Full-resolution logo, used for Plymouth boot splash |
| `azurelinux-logo-48.png` | `azl-work/azurelinux/assets/azurelinux-logo-48.png` | 48×48 icon |

No wallpaper asset exists yet. The Plymouth theme (`assets/plymouth/`) has `dot.png` and `dot-glow.png` which suggest an abstract dot/circle motif — potentially usable as a design seed for a wallpaper.

**Citation:**
- `azurelinux-desktop-iso:assets/branding/` (directory listing)
- `azl-work/azurelinux/assets/NOTICE.md:1-5`

### 6. License Requirements

#### For the wallpaper image file

**Acceptable licenses for a Fedora-derived distro:**
- `CC-BY-SA-4.0` — used by all Fedora-cycle wallpapers (`f43-backgrounds`). Requires attribution + ShareAlike. Correct for a project where artwork comes from a designer who retains copyright.
- `CC0-1.0` — used for some Fedora extras. No restrictions. Ideal if Microsoft wants maximum freedom for others to remix.
- `CC-BY-4.0` — used in Fedora extras. Attribution required but no ShareAlike constraint.

**Avoid:** `CC-BY-NC-*`, proprietary, or anything from the Fedora not-allowed list. Citation: `https://docs.fedoraproject.org/en-US/legal/license-approval/`

**GNOME backgrounds upstream** license: `CC-BY-SA-3.0`. Citation: `https://gitlab.gnome.org/GNOME/gnome-backgrounds/-/raw/main/COPYING`

#### For use of the Azure Linux mark/logo

The `NOTICE.md` in the repo is clear:
> "Microsoft permits the use of the Azure Linux trademark and Azure Linux icon **only in accordance with its trademark and brand guidelines** here: https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks"

Microsoft's Trademark Guidelines state:
> "**Many uses, including our logos, app and product icons, and other designs, will require a license first**."

**Practical implication:** A wallpaper that *incorporates the Azure Linux logotype or penguin icon* as part of the image is risky without an internal Microsoft trademark clearance. The safer engineering path — also what Fedora does — is **abstract/geometric art inspired by the brand color palette** without embedding any trademarked logo directly in the image file. The Plymouth theme already follows this pattern (dot motif, no logo lockup in the script). If the intent is to incorporate the actual `AzureLinuxLogo.png` into the wallpaper artwork, get a written OK from the brand/legal team first.

### 7. Remediation Options

#### Option A — Minimal: Update kickstart/kiwi inline dconf overrides (no new RPM)

**Effort:** ~2 hours. **Scope:** All four targets.

1. Commission or author two JXL images (light + dark). Stage them in `assets/backgrounds/azurelinux-l.jxl` and `azurelinux-d.jxl` in the repo.
2. In the live ISO kickstart, KIWI `config.sh`, and both installer ks.in files, add a step that copies the images from the staged assets into the target root:
   ```bash
   install -d -m 0755 /usr/share/backgrounds/azurelinux
   install -m 0644 $ASSETS/backgrounds/azurelinux-l.jxl /usr/share/backgrounds/azurelinux/
   install -m 0644 $ASSETS/backgrounds/azurelinux-d.jxl /usr/share/backgrounds/azurelinux/
   ```
3. Change the three `picture-uri` lines in all three dconf `local.d` blocks:
   ```ini
   picture-uri='file:///usr/share/backgrounds/azurelinux/azurelinux-l.jxl'
   picture-uri-dark='file:///usr/share/backgrounds/azurelinux/azurelinux-d.jxl'
   ```
**Pros:** No new RPM, no spec, works immediately.  
**Cons:** Images duplicated in the repo, not updatable via `dnf update`, no GNOME Settings picker registration, no gschema default (relies entirely on the `local.d` override which can get clobbered if the dconf profile/db file is deleted or not present).

#### Option B — Correct: New `azurelinux-desktop-backgrounds` RPM (recommended)

**Effort:** ~1 day of spec + artwork. **Scope:** All four targets plus any future AZL desktop spins.

**Spec skeleton** (`specs/a/azurelinux-desktop-backgrounds/azurelinux-desktop-backgrounds.spec`):

```spec
Name:           azurelinux-desktop-backgrounds
Version:        4.0.0
Release:        %autorelease
Summary:        Azure Linux Desktop default wallpaper
License:        CC-BY-SA-4.0
URL:            https://github.com/microsoft/azurelinux
Source0:        %{name}-%{version}.tar.xz
BuildArch:      noarch

Requires:       (jxl-pixbuf-loader if gdk-pixbuf2)
Provides:       system-backgrounds-gnome = %{version}-%{release}

%description
Default desktop wallpaper for the Azure Linux Desktop distribution.
Provides light and dark JPEG XL variants and registers them with GNOME,
KDE Plasma, and common desktop environments.

%prep
%autosetup

%install
install -d %{buildroot}%{_datadir}/backgrounds/azurelinux/default
install -m 644 azurelinux-l.jxl %{buildroot}%{_datadir}/backgrounds/azurelinux/default/
install -m 644 azurelinux-d.jxl %{buildroot}%{_datadir}/backgrounds/azurelinux/default/

# GNOME picker registration
install -d %{buildroot}%{_datadir}/gnome-background-properties
install -m 644 azurelinux.xml %{buildroot}%{_datadir}/gnome-background-properties/azurelinux.xml

# gschema override — sets the system-wide default for all users
install -d %{buildroot}%{_datadir}/glib-2.0/schemas
cat > %{buildroot}%{_datadir}/glib-2.0/schemas/10_org.gnome.desktop.background.azurelinux.gschema.override << 'EOF'
[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/azurelinux/default/azurelinux-l.jxl'
picture-uri-dark='file:///usr/share/backgrounds/azurelinux/default/azurelinux-d.jxl'

[org.gnome.desktop.screensaver]
picture-uri='file:///usr/share/backgrounds/azurelinux/default/azurelinux-l.jxl'
picture-uri-dark='file:///usr/share/backgrounds/azurelinux/default/azurelinux-d.jxl'
EOF

%files
%license LICENSE
%dir %{_datadir}/backgrounds/azurelinux
%dir %{_datadir}/backgrounds/azurelinux/default
%{_datadir}/backgrounds/azurelinux/default/azurelinux-*.jxl
%dir %{_datadir}/gnome-background-properties
%{_datadir}/gnome-background-properties/azurelinux.xml
%{_datadir}/glib-2.0/schemas/10_org.gnome.desktop.background.azurelinux.gschema.override

%changelog
%autochangelog
```

**GNOME properties XML** (`azurelinux.xml`):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">
<wallpapers>
    <wallpaper deleted="false">
        <name>Azure Linux Desktop</name>
        <filename>/usr/share/backgrounds/azurelinux/default/azurelinux-l.jxl</filename>
        <filename-dark>/usr/share/backgrounds/azurelinux/default/azurelinux-d.jxl</filename-dark>
        <options>zoom</options>
        <shade_type>solid</shade_type>
        <pcolor>#0078d4</pcolor>   <!-- Azure blue -->
        <scolor>#003a6c</scolor>
    </wallpaper>
</wallpapers>
```
**Citation for XML format:** `https://raw.githubusercontent.com/fedoradesign/backgrounds/main/default/gnome-backgrounds-f43.xml`

**Integration changes required:**

1. Add `azurelinux-desktop-backgrounds` to the `%packages` block in `kickstart/azurelinux-desktop-live.ks` (currently near line 237 where `gnome-backgrounds` is listed).
2. Add the same package to the `kiwi/config.sh` package list (near line 94 where `gnome-backgrounds` is listed).
3. In all three `local.d` dconf blocks, update the two `picture-uri` lines to the new paths (or drop them entirely and rely on the gschema override, which is cleaner).
4. The installer kickstart (`azl-install.ks.in`, `azl-install-encrypted.ks.in`) already installs the package set from the live system; as long as the RPM is in the repo, the installed target will have it.

**Why gschema override is better than dconf local.d alone:** The gschema override is applied at schema compilation time (triggered by RPM scriptlets via `%posttrans` in glib2 calling `glib-compile-schemas /usr/share/glib-2.0/schemas`). It is persistent, doesn't need `dconf update`, and is the upstream-recommended mechanism. The `local.d` approach requires `dconf update` to run at build time and the compiled binary database to survive into the final image, which is fragile across `switch-root` in live ISOs. **Keep the `local.d` block for `color-scheme` and `gtk-theme` (dark mode), but let the gschema override handle the wallpaper path.**

**Citation for gschema pattern:** `microsoft/azurelinux:specs/d/desktop-backgrounds/desktop-backgrounds.spec:155-185`  
**Citation for `picture-options='zoom'` note:** `azurelinux-desktop-iso:kiwi/azl-install.ks.in:244`

### 8. Artwork Guidance

Since no wallpaper asset exists yet, here are practical options in order of effort:

1. **Commission or internally author JXL artwork.** Azure brand blue `#0078d4`, dark navy `#003a6c`. Release as `CC0-1.0` (simplest — no attribution chain) or `CC-BY-SA-4.0` (matches Fedora ecosystem norm). Do **not** embed the Azure Linux logotype in the image unless trademark legal has signed off; use abstract geometric art instead (matching Plymouth's dot motif).

2. **Derive from an existing CC0 or CC-BY source.** Sites like Unsplash (Unsplash License, permissive but not SPDX), or use CC0 art from the Open Clip Art Library. Apply brand color grading. The derivative work can then be released CC0 or CC-BY-SA-4.0.

3. **Generative art (e.g., `cjxl` + ImageMagick gradient).** A pure-code gradient or noise wallpaper in brand colors can be generated programmatically at build time (the Makefile can call `convert`/`magick` just as the Fedora Makefiles do). This requires zero external licensing and is trivially verifiable.

For the light/dark pair: the two images don't need to be categorically different — Fedora's convention is a warm/cool tone shift (F43 uses the same composition with different color keys). GNOME's `<filename-dark>` is set independently, so they can also be distinct designs.

**Recommended minimum resolution:** 3840×2160 (4K). GNOME's `zoom` mode scales down to any screen. One image file per variant.

### 9. Gaps and Uncertainties

- **No wallpaper artwork exists yet.** The RPM spec can be written today; the image files are the blocker. The NOTICE.md + trademark guidelines create a real constraint on logo usage — get brand/legal alignment before embedding the penguin or wordmark.
- **Installer runtime (KIWI build env) wallpaper:** The KIWI build environment (`config.sh`) installs `gnome-backgrounds` but runs in a containerized chroot during ISO assembly — it doesn't present a GNOME desktop to a user, so the installer environment's background is set by Anaconda's own theming (not GNOME dconf). No wallpaper change is needed for the installer *UI* itself; what matters is the *installed target*, which the kickstart ks.in files handle.
- **SDDM / GDM login screen:** `desktop-backgrounds.spec` also sets `[org.gnome.desktop.screensaver]` via a second gschema override. The `local.d` approach in the AZL kickstarts already sets screensaver separately if needed. Audit whether GDM greeter reads from the same gschema key (it does on GDM 44+).
- **AZL spec repo (microsoft/azurelinux):** The `specs/a/` directory doesn't exist yet. The new spec will need to be submitted there as a new package, with `azldev` tooling picking it up; check the `azldev.toml` and `CONTRIBUTING.md` for the new-package onboarding flow.
- **Lock file:** AZL uses deterministic lock files for all specs. A `locks/azurelinux-desktop-backgrounds.lock` will be auto-generated on first upstream fetch.

### Appendix: Key Source Citations

| Finding | Source |
|---------|--------|
| JXL format in f43-backgrounds | `microsoft/azurelinux:specs/f/f43-backgrounds/f43-backgrounds.spec` (`%global picture_ext jxl`) |
| gschema override generation | `microsoft/azurelinux:specs/d/desktop-backgrounds/desktop-backgrounds.spec:155-185` |
| GNOME XML format | `https://raw.githubusercontent.com/fedoradesign/backgrounds/main/default/gnome-backgrounds-f43.xml` |
| Time-of-day animation XML | `https://raw.githubusercontent.com/fedoradesign/backgrounds/main/default/f43.xml` |
| f43-backgrounds spec (Fedora upstream) | `https://src.fedoraproject.org/rpms/f43-backgrounds/raw/rawhide/f/f43-backgrounds.spec` |
| GNOME backgrounds license | `https://gitlab.gnome.org/GNOME/gnome-backgrounds/-/raw/main/COPYING` (CC-BY-SA-3.0) |
| Fedora license approval | `https://docs.fedoraproject.org/en-US/legal/license-approval/` |
| AZL trademark notice | `azl-work/azurelinux/assets/NOTICE.md:1-5` |
| Microsoft trademark guidelines | `https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks` |
| Live ISO current adwaita pin | `azurelinux-desktop-iso:kickstart/azurelinux-desktop-live.ks:706-708` |
| Installer adwaita pin (plain) | `azurelinux-desktop-iso:kiwi/azl-install.ks.in:241-243` |
| Installer adwaita pin (encrypted) | `azurelinux-desktop-iso:kiwi/azl-install-encrypted.ks.in:248-250` |
| JXL loader soft dep pattern | `microsoft/azurelinux:specs/f/f43-backgrounds/f43-backgrounds.spec` (`Requires: (jxl-pixbuf-loader if gdk-pixbuf2)`) |
| Existing branding asset (logo PNG) | `azurelinux-desktop-iso:assets/branding/AzureLinuxLogo.png` |

## Issue: default desktop background

**Observed:** The desktop is a plain blue Adwaita field. Dark mode is applied,
but the result still looks generic rather than like an Azure Linux Desktop
default.

**Cause:** This is configuration-correct but visually insufficient. The
image uses the host-selected GNOME default:
`/usr/share/backgrounds/gnome/adwaita-d.jxl`. The corresponding light URI is
also set, and the files are present in the published QCOW2.

**Tried:** The background URI was initially missing, then was added across
the live ISO, disk image, installer target, and hybrid canary. A switch to a
different shipped GNOME background was considered, then reverted to match
the host default.

**Next fix:** Select a non-generic project default deliberately. The durable
solution is a project-owned, properly licensed Azure Linux Desktop wallpaper
installed in all artifact paths, with matching light and dark variants if
needed. Changing only the dconf URI to another stock GNOME image would alter
the color but not establish a distinct product background.



## Research findings: GNOME Shell Application Identity & Dock Remediation

### Executive Summary

Six root causes are identified across three desktop entry issues and one dconf policy issue. All have concrete fixes. The PowerShell dock problem is a **D-Bus activation race condition**, not a wrong `StartupWMClass`. The `edit` entry is most likely missing from `XDG_DATA_DIRS` or is missing `Categories=`. The `.NET` entry uses shell-reserved characters that the Desktop Entry spec forbids in bare `Exec=` values. The `favorite-apps` system default is not enforced on pre-existing user sessions because user-db always wins over system-db without a dconf lock.

### 1. GNOME Terminal `--app-id`, Wayland app_id, and Dock Grouping

#### How the identity chain works (source-verified)

**On Wayland (native GTK4 gnome-terminal, standard in Fedora 43):**

When `gnome-terminal-server --app-id org.azurelinux.PowerShell` launches, GTK4 calls `xdg_toplevel.set_app_id("org.azurelinux.PowerShell")` over the Wayland protocol. In Mutter, this maps directly to:

```c
// GNOME/mutter: src/wayland/meta-wayland-xdg-shell.c
static void
xdg_toplevel_set_app_id (struct wl_client *client,
                          struct wl_resource *resource, const char *app_id)
{
  ...
  meta_window_set_wm_class (window, app_id, app_id);  // ← sets both instance and class
}
```

So for a Wayland gnome-terminal window: `wm_class_instance = wm_class = "org.azurelinux.PowerShell"`.

**GNOME Shell's window-to-app matching priority** (`GNOME/gnome-shell: src/shell-window-tracker.c`, `get_app_for_window()`):

1. `get_app_from_window_wmclass()` — checks WM_CLASS **first**
   - Tries `shell_app_system_lookup_startup_wmclass(appsys, wm_class_instance)` → scans every installed `.desktop` file's `StartupWMClass` key
   - Then tries matching wm_class to desktop-file basename
2. `get_app_from_sandboxed_app_id()` — Flatpak/Snap only
3. `get_app_from_gapplication_id()` — reads `_GTK_APPLICATION_ID` X11 property (X11 only, not Wayland)
4. PID lookup, startup-notification, window group
5. Creates a "window-backed" (anonymous) app

Because `xdg_toplevel.set_app_id` feeds directly into WM_CLASS (step 1), **a `.desktop` file with `StartupWMClass=org.azurelinux.PowerShell` will be matched on step 1** — IF the window is actually owned by the server running with that app-id.

**The StartupWMClass table** (`GNOME/gnome-shell: src/shell-app-system.c`):

```c
// startup_wm_class_to_id hash built in scan_startup_wm_class_to_id()
// Key = StartupWMClass value from .desktop file
// Value = desktop file ID (e.g. "org.azurelinux.PowerShell.desktop")
id = g_hash_table_lookup (system->startup_wm_class_to_id, wmclass);
```

This hash is rebuilt whenever any `.desktop` file changes (inotify). The design is correct — `StartupWMClass=org.azurelinux.PowerShell` is the right approach.

#### Root cause: D-Bus activation race condition

The helper script has a race condition:

```bash
/usr/libexec/gnome-terminal-server --app-id org.azurelinux.PowerShell &  # ← background
exec gnome-terminal --app-id org.azurelinux.PowerShell --title=PowerShell -- /usr/bin/pwsh
```

`gnome-terminal` (the thin client) immediately tries to contact D-Bus service `org.azurelinux.PowerShell`. If the background server hasn't registered yet and **no `/usr/share/dbus-1/services/org.azurelinux.PowerShell.service` file exists**, D-Bus service activation fails. The client can fall back to the already-running default `org.gnome.Terminal` server. The window is then owned by that server, so `xdg_toplevel.app_id = "org.gnome.Terminal"`, Mutter sets `wm_class = "org.gnome.Terminal"`, and GNOME Shell groups it under `org.gnome.Terminal.desktop`.

This is exactly the observed symptom: the indicator appears under the ordinary Terminal icon.

#### Remediation — Option A (Recommended): D-Bus service activation file

Create `/usr/share/dbus-1/services/org.azurelinux.PowerShell.service`:

```ini
[D-BUS Service]
Name=org.azurelinux.PowerShell
Exec=/usr/libexec/gnome-terminal-server --app-id org.azurelinux.PowerShell
```

Then simplify the wrapper script — no manual server launch needed:

```bash
#!/bin/sh
# /usr/local/bin/azl-powershell-terminal
exec gnome-terminal --app-id org.azurelinux.PowerShell --title=PowerShell -- /usr/bin/pwsh
```

D-Bus auto-activates the server on demand. `gnome-terminal` will reliably connect to the `org.azurelinux.PowerShell` instance on every invocation.

#### Remediation — Option B: Synchronous server readiness check

If a D-Bus service file is undesirable (e.g., packaging constraints):

```bash
#!/bin/sh
# /usr/local/bin/azl-powershell-terminal
/usr/libexec/gnome-terminal-server --app-id org.azurelinux.PowerShell &
# Wait for the server to register on the session bus (max 2 s)
for i in $(seq 1 20); do
    gdbus introspect --session \
        --dest org.azurelinux.PowerShell \
        --object-path /org/gnome/Terminal/Factory0 \
        >/dev/null 2>&1 && break
    sleep 0.1
done
exec gnome-terminal --app-id org.azurelinux.PowerShell \
    --title=PowerShell -- /usr/bin/pwsh
```

#### Corrected desktop file

```ini
[Desktop Entry]
Type=Application
Name=PowerShell
Comment=Azure Linux PowerShell terminal
Icon=org.azurelinux.PowerShell
Exec=/usr/local/bin/azl-powershell-terminal
StartupWMClass=org.azurelinux.PowerShell
StartupNotify=true
Categories=System;TerminalEmulator;
```

`StartupWMClass` must exactly match the value passed to `--app-id` (case-sensitive). The filename `org.azurelinux.PowerShell.desktop` and the `StartupWMClass` value must match for `startup_wm_class_is_exact_match()` (in `shell-app-system.c`) to give it priority over ambiguous matches.

### 2. Application Discovery: `update-desktop-database`, `mimeinfo.cache`, and Caches

#### How GNOME Shell discovers applications

GNOME Shell uses `ShellAppCache` → `GDesktopAppInfo` (GLib), which:

1. Scans `$XDG_DATA_DIRS/applications/` and `$XDG_DATA_HOME/applications/` for `.desktop` files at startup
2. **Monitors these directories with inotify** for changes — new files are picked up automatically within seconds, without a re-login

`update-desktop-database` generates `mimeinfo.cache` for MIME-type associations. It does **not** affect GNOME Shell's app listing directly, but it is required for `xdg-open` and file-manager integrations to work correctly.

**On Fedora 43:** RPM `%post` scriptlets call `update-desktop-database` automatically after installing packages. For non-RPM files, run manually:

```bash
update-desktop-database /usr/share/applications   # or /usr/local/share/applications
```

#### `XDG_DATA_DIRS` and `/usr/local/share`

On Fedora 43's GNOME Wayland session, the default `XDG_DATA_DIRS` is:

```
/usr/local/share:/usr/share:…
```

Files placed in `/usr/local/share/applications/` are fully visible to GNOME Shell. However, files placed in custom directories not on `XDG_DATA_DIRS` will never appear. **Desktop file IDs are derived from path relative to their `XDG_DATA_DIRS` component** — e.g., `/usr/local/share/applications/edit.desktop` → ID `edit.desktop`.

**Desktop file ID naming note** (freedesktop.org spec, §File Naming): The base filename before `.desktop` should be a valid D-Bus well-known name. Plain names like `edit` and `dotnet` are technically non-conforming but GLib still accepts them. Prefer `org.azurelinux.Edit.desktop` etc. for forward compatibility.

### 3. Why a Valid Desktop File May Not Appear in GNOME Overview

`g_app_info_should_show()` (called by `scan_startup_wm_class_to_id` in `shell-app-system.c`) returns `false` for any of these conditions:

| Key/Condition | Effect |
|---|---|
| `Hidden=true` | Treated as deleted; never shown |
| `NoDisplay=true` | Hidden from launchers (still launchable by apps that bypass this check); **note: still shown in GNOME favorites bar if listed in `favorite-apps`** |
| `OnlyShowIn=KDE` (without GNOME) | Hidden in GNOME (`$XDG_CURRENT_DESKTOP` must contain `GNOME`) |
| `NotShowIn=GNOME` | Hidden in GNOME |
| `TryExec=/path/that/does/not/exist` | Entry suppressed (spec: "may be ignored if not executable") |
| `Categories=` absent | Entry appears but may be uncategorized; some launchers require at least one category |
| Wrong `Icon=` | Entry shows with broken icon; does not prevent display |
| File not in `XDG_DATA_DIRS/applications/` | Not indexed; never appears |
| Database stale after first login | Re-login or touch the file to trigger inotify rescan |

For the `edit` entry specifically, verify:

```bash
desktop-file-validate /usr/share/applications/edit.desktop
# Already passes per the problem statement, so check:

grep -E '^(Hidden|NoDisplay|OnlyShowIn|NotShowIn|TryExec|Categories)' \
    /usr/share/applications/edit.desktop

# Confirm it's under an XDG_DATA_DIRS component:
echo $XDG_DATA_DIRS | tr : '\n'
# Confirm update-desktop-database was run:
ls -la /usr/share/applications/mimeinfo.cache
```

A missing `Categories=` field is the most likely culprit for a launcher-invisible but otherwise valid file.

**Corrected `edit.desktop`:**

```ini
[Desktop Entry]
Type=Application
Name=Edit
Comment=Text editor launcher
Icon=accessories-text-editor
Exec=gnome-terminal --title=edit -- /usr/local/bin/edit %F
MimeType=text/plain;
Categories=Utility;TextEditor;
StartupNotify=false
```

> **Note on `Exec=gnome-terminal … %F`:** Using a field code like `%F` without `MimeType=` set means the field code is ignored (no file-manager integration). If `edit` is not a MIME handler, omit `%F`. If it is, add appropriate `MimeType=` entries and re-run `update-desktop-database`.

### 4. Correct `dotnet.desktop` — Exec Reserved Characters and Helper-Script Pattern

#### Why the original fails

Per Desktop Entry Spec §Exec (https://specifications.freedesktop.org/desktop-entry/latest/exec-variables.html):

> Reserved characters are: space, tab, newline, `"`, `'`, `\`, `>`, `<`, `~`, `|`, `&`, `;`, `$`, `*`, `?`, `#`, `(`, `)`, and `` ` ``. If an argument contains a reserved character the argument must be quoted [with double quotes, not single quotes]. Single quote is itself a reserved character and may not appear anywhere in a bare `Exec=` value.

The original `Exec=gnome-terminal --title=".NET" -- /bin/sh -c 'dotnet --info; exec $SHELL'` fails because:
1. `'` (single quote) — reserved, may not appear in `Exec=` at all
2. `;` (semicolon) — reserved, must be inside a double-quoted argument
3. `$SHELL` — `$` is reserved and is passed literally to the process (no shell expansion); it must be either escaped or put in a helper script

#### Option A: Helper script (recommended — zero escaping complexity)

```bash
#!/bin/sh
# /usr/local/bin/dotnet-info-shell
dotnet --info
exec "${SHELL:-/bin/bash}"
```

```ini
[Desktop Entry]
Type=Application
Name=.NET
Comment=Show .NET SDK info and drop into a shell
Icon=dotnet
Exec=gnome-terminal --title=".NET" -- /usr/local/bin/dotnet-info-shell
Categories=Development;
StartupNotify=false
```

#### Option B: Inline with proper spec-compliant escaping

Per the spec, within a double-quoted argument: `$` → `\$`, `\` → `\\`, `"` → `\"`, `` ` `` → `` \` ``. The semicolon is allowed inside a double-quoted argument.

```ini
Exec=gnome-terminal --title=".NET" -- /bin/sh -c "dotnet --info; exec \$SHELL"
```

Breaking this down:
- `--title=".NET"` — the double quotes here are spec quoting around `.NET`; since `.NET` contains no reserved chars, the quotes are optional but valid
- `/bin/sh -c` — unquoted, no reserved chars
- `"dotnet --info; exec \$SHELL"` — double-quoted argument; `;` is allowed inside quotes; `\$` is the spec-escaped `$`

Verify with `desktop-file-validate` before deploying. Prefer Option A for maintainability.

#### Complete corrected `dotnet.desktop`

```ini
[Desktop Entry]
Version=1.5
Type=Application
Name=.NET
GenericName=.NET SDK
Comment=Show .NET info and open a shell
Icon=dotnet
Exec=gnome-terminal --title=".NET" -- /usr/local/bin/dotnet-info-shell
Categories=Development;
Keywords=dotnet;sdk;csharp;
StartupNotify=false
```

If no `dotnet` icon exists in the theme, substitute an absolute path or a valid theme icon name (`utilities-terminal` always exists as a fallback).

### 5. System `favorite-apps` — Why It May Be Ignored and How to Force It

#### Schema and override mechanism

The `favorite-apps` key lives in schema `org.gnome.shell`, path `/org/gnome/shell/` (`GNOME/gnome-shell: data/org.gnome.shell.gschema.xml.in`):

```xml
<key name="favorite-apps" type="as">
  <default>@DASH_APPS@</default>  <!-- substituted at build time -->
  <summary>List of desktop file IDs for favorite applications</summary>
</key>
```

The compiled-in default (e.g., Nautilus, Firefox, GNOME Terminal) is baked into `/usr/share/glib-2.0/schemas/org.gnome.shell.gschema.xml`.

#### Priority order for dconf reads

From GNOME System Admin Guide (https://help.gnome.org/system-admin-guide/dconf-profiles.html):

```
# /etc/dconf/profile/user  (default on Fedora)
user-db:user          ← highest priority (written to ~/.config/dconf/user)
system-db:local       ← read-only system override (/etc/dconf/db/local)
```

**For new users** (no `~/.config/dconf/user`): system-db value is used as the effective value.

**For existing users** (post-first-login): GNOME Shell writes `favorite-apps` to the user database when the user modifies the dock (or sometimes on first GNOME startup). Once a value exists in `user-db:user`, **it permanently shadows any system-db value** unless a lock is in place.

#### gschema override vs. dconf db

| Mechanism | What it changes | New user | Existing user (unlocked) |
|---|---|---|---|
| `gschema.override` | Compiled schema default | ✓ used | ✗ user-db takes precedence |
| `/etc/dconf/db/local.d/` | System-db default | ✓ used | ✗ user-db takes precedence |
| `/etc/dconf/db/local.d/locks/` | Prevents user from changing key | ✓ forced | ✓ forced |

#### Reliable remediation: dconf system-db + lock

**Step 1:** Create the keyfile:

```ini
# /etc/dconf/db/local.d/01-azl-favorites
[org/gnome/shell]
favorite-apps=['org.gnome.Nautilus.desktop', 'org.azurelinux.PowerShell.desktop', 'firefox.desktop', 'org.gnome.Terminal.desktop']
```

**Step 2:** Create the lock (if you want to prevent user overrides):

```
# /etc/dconf/db/local.d/locks/01-azl-favorites
/org/gnome/shell/favorite-apps
```

**Step 3:** Ensure the profile includes the system-db (already default on Fedora):

```
# /etc/dconf/profile/user
user-db:user
system-db:local
```

**Step 4:** Rebuild the dconf database:

```bash
dconf update
```

Without the lock, existing users who have ever customized their dash will not see the change until they manually reset: `gsettings reset org.gnome.shell favorite-apps`. With the lock, they also cannot override it.

#### Alternative: gschema override only (new users or reinstalls)

```ini
# /usr/share/glib-2.0/schemas/50-azurelinux.gschema.override
[org.gnome.shell]
favorite-apps=['org.gnome.Nautilus.desktop', 'org.azurelinux.PowerShell.desktop', 'firefox.desktop', 'org.gnome.Terminal.desktop']
```

```bash
glib-compile-schemas /usr/share/glib-2.0/schemas/
```

This sets the schema default. **It does NOT override existing user preferences or system-db.** Use this only if you are certain no user-db value exists (e.g., image builds where user home directories are created fresh).

### Summary Checklist

| Issue | Root Cause | Fix |
|---|---|---|
| PowerShell indicator under Terminal icon | Race condition: gnome-terminal falls back to default org.gnome.Terminal server when custom server isn't ready on D-Bus | Add `/usr/share/dbus-1/services/org.azurelinux.PowerShell.service`; remove manual `&` server launch from helper script |
| `edit` absent from overview | Most likely: missing `Categories=`; possibly wrong install path or stale database | Add `Categories=Utility;TextEditor;`; verify `XDG_DATA_DIRS`; run `update-desktop-database` |
| `.NET` desktop file rejected | Single quotes, bare semicolon, and `$SHELL` are all reserved characters in `Exec=` | Use helper script, OR use spec-compliant double-quote escaping: `"dotnet --info; exec \$SHELL"` |
| `favorite-apps` not applied to existing users | user-db always shadows system-db without a lock | Use `/etc/dconf/db/local.d/locks/` + `dconf update` |

### Key Citations

- **Mutter Wayland xdg_toplevel_set_app_id → meta_window_set_wm_class:** `GNOME/mutter: src/wayland/meta-wayland-xdg-shell.c` (confirmed in live source at `gitlab.gnome.org/GNOME/mutter/-/raw/main/src/wayland/meta-wayland-xdg-shell.c`)
- **GNOME Shell window-to-app matching priority:** `GNOME/gnome-shell: src/shell-window-tracker.c` (`get_app_for_window()`, lines 380–480; SHA `bfff29ae`)
- **StartupWMClass hash building and lookup:** `GNOME/gnome-shell: src/shell-app-system.c` (`scan_startup_wm_class_to_id()`, `shell_app_system_lookup_startup_wmclass()`; SHA `b886b797`)
- **gnome-terminal `--app-id` option parsing:** `GNOME/gnome-terminal: src/terminal-options.cc` (`option_app_id_callback()`; gitlab.gnome.org/GNOME/gnome-terminal)
- **gnome-terminal GApplication ID constant:** `GNOME/gnome-terminal: src/terminal-defines.hh` (`TERMINAL_APPLICATION_ID = "org.gnome.Terminal"`)
- **Desktop Entry spec — Exec reserved characters and quoting rules:** https://specifications.freedesktop.org/desktop-entry/latest/exec-variables.html
- **Desktop Entry spec — file naming / D-Bus well-known name requirement:** https://specifications.freedesktop.org/desktop-entry/latest/file-naming.html
- **Desktop Entry spec — OnlyShowIn/NotShowIn behavior:** https://specifications.freedesktop.org/desktop-entry/latest/recognized-keys.html
- **dconf profiles (user-db priority over system-db):** https://help.gnome.org/system-admin-guide/dconf-profiles.html
- **dconf lockdown:** https://help.gnome.org/system-admin-guide/dconf-lockdown.html
- **org.gnome.shell gschema — favorite-apps key definition:** `GNOME/gnome-shell: data/org.gnome.shell.gschema.xml.in` (SHA `9a55ee71`)

## Issue: PowerShell dock identity

**Implemented fix (2026-07-22):** Switched the PowerShell launcher path to D-Bus activation for `org.azurelinux.PowerShell` and staged a dedicated session-bus service file into both live and installer targets. This removes the previous race where the client could fall back to `org.gnome.Terminal` before the custom server registered.

**Changed files:**
- `assets/dbus/org.azurelinux.PowerShell.service` (new)
- `assets/bin/azl-powershell-terminal`
- `kickstart/azurelinux-desktop-live.ks`
- `kiwi/azl-install.ks.in`

**Status:** The root-cause race condition fix is now in source for the next artifact build. Runtime GNOME Shell indicator behavior still needs verification in a fresh live and installed session from rebuilt artifacts.


**Observed:** PowerShell opens in a terminal window titled `PowerShell`, but
the live-session screenshot shows the active indicator under the ordinary
Terminal icon rather than under the PowerShell favorite. It still looks like
GNOME Terminal spawned PowerShell instead of PowerShell owning its own dock
identity.

**Current implementation:** The desktop entry and favorites use
`org.azurelinux.PowerShell.desktop`. The launcher now relies on a dedicated
session-bus activation file (`org.azurelinux.PowerShell.service`) so the
matching GNOME Terminal server is started by D-Bus before client invocation.

```ini
# /usr/share/applications/org.azurelinux.PowerShell.desktop
Exec=/usr/local/bin/azl-powershell-terminal
StartupWMClass=org.azurelinux.PowerShell
```

```ini
# /usr/share/dbus-1/services/org.azurelinux.PowerShell.service
[D-BUS Service]
Name=org.azurelinux.PowerShell
Exec=/usr/libexec/gnome-terminal-server --app-id org.azurelinux.PowerShell
```

```sh
# /usr/local/bin/azl-powershell-terminal
exec gnome-terminal --app-id org.azurelinux.PowerShell --title=PowerShell -- /usr/bin/pwsh
```

**What the static checks prove:** The helper, matching desktop entry, and
hidden GNOME Terminal `--app-id` option are present. They do not prove that
the server remained separate or that Mutter/GNOME Shell assigned the window
the requested application identity.

**Next investigation:** In a running Wayland session, record the D-Bus owner
for `org.azurelinux.PowerShell`, the server process command line, and the
window's application ID from GNOME Shell tooling. Test whether the existing
Terminal server is being reused despite the custom ID. Do not call this fixed
until the active dock indicator moves to the PowerShell icon. Do not replace
GNOME Terminal or add a separate terminal emulator.

## Issue: Flatpak live-session space

**Observed:** A small Flatpak installation still fails after downloading most
of its runtime. Flatpak reports a 1.0 GiB delta requirement with only about
495 MiB free. This was reproduced with 8 GiB RAM.

**Likely cause:** The normal LiveOS writable overlay remains too small for
Flatpak's visible-root free-space check. `--live-rootfs-size 4` was added to
the Lorax invocation, but this result shows that it did not produce the
needed writable capacity at runtime, or that Flatpak is checking a different
overlay-backed filesystem than the enlarged rootfs image.

**On-disk evidence:** The published live root is a read-only squashfs with
no available blocks when mounted. Its Flatpak configuration, like the
installed target's, reserves `min-free-space-size=500MB`. The installed LVM
root had about 15.4 GiB free during the audit, which explains why Flatpak
works there. Static inspection cannot expose the live boot's tmpfs or overlay
allocation, so the approximately 495 MiB seen in the guest must be measured
from a running live session rather than inferred from the squashfs.

**Tried:** More QEMU RAM, an attempted hand-created persistent overlay disk,
and the larger Lorax live rootfs setting. More RAM made the session more
usable but did not satisfy Flatpak. The hand-created overlay did not match
dracut's supported persistent layout and must not be shipped.

**Next investigation and fix:**

1. Capture `findmnt`, `df -h`, `df -i`, and the relevant
   `/proc/cmdline` values from the failing live session. Identify exactly
   which mount Flatpak sees as having about 495 MiB free.
2. Inspect the published ISO's `LiveOS/rootfs.img` size and the boot
   initramfs/live-overlay configuration to confirm whether
   `--live-rootfs-size 4` reached the artifact.
3. If the visible writable layer is still the limiting tmpfs overlay, set a
   supported live-overlay size in the live boot configuration and validate
   it at 8 GiB RAM. If it cannot fit within the live-media model, document
   Flatpak installation as requiring Fedora-style persistent USB deployment
   with `livecd-iso-to-disk --overlay-size-mb` rather than claiming normal
   ISO sessions support it.



# Findings Report: Flatpak Installation Failure in Fedora 43 / Azure Linux Live ISO Session

## Summary

The ~495 MiB free space reported by Flatpak is not a RAM limitation — it is the free space inside a fixed-size **ext4 `rootfs.img`** that was created by `--live-rootfs-size 4` and packed inside `squashfs.img`. With 8 GiB of RAM and a 32 GiB default DM snapshot COW overlay, the physical writes are not the bottleneck: the **apparent free space in the ext4 container** is. Flatpak calls `statvfs("/var/lib/flatpak")`, which returns the ext4's free blocks, not the size of the RAM-backed COW overlay. The squashfs itself (mounted read-only) correctly reports zero available blocks. The installed LVM root has none of this constraint because it is a real ext4/xfs volume with genuine free space. Three concrete remediation paths exist, rated by invasiveness.

## 1. Overlay Architecture: What `--live-rootfs-size 4` Actually Controls

### 1.1 The squashfs-ext4 Stack

Fedora/Lorax live ISOs use a two-level container by default:

```
squashfs.img  (ISO: /LiveOS/squashfs.img)
  └── LiveOS/rootfs.img   ← ext4, fixed size set at build time
        └── /bin /etc /var /home …  ← live root filesystem
```

**Source: `dracut-ng/dracut` `modules.d/70dmsquash-live/dmsquash-live-root.sh:L174-L179`** (commit `3702a91`):
```sh
if [ -d /run/initramfs/squashfs/LiveOS ]; then
    if [ -f /run/initramfs/squashfs/LiveOS/rootfs.img ]; then
        FSIMG="/run/initramfs/squashfs/LiveOS/rootfs.img"
    fi
```
The squashfs is loop-mounted read-only at `/run/initramfs/squashfs`. The `rootfs.img` inside it is exposed as a block device, and a DM snapshot is stacked on top to form `/dev/mapper/live-rw`, which becomes the writable `/` of the live session.

### 1.2 What `--live-rootfs-size` (livemedia-creator) does

**Source: `weldr/lorax` `src/pylorax/creator.py:L275-L281`** and **`src/pylorax/imgutils.py:L157-L169`**:
```python
# creator.py
size = opts.live_rootfs_size or None
mkrootfsimg(img_mount.mount_dir, rootfs_img, "LiveOS", size=size, sysroot=sys_root)

# imgutils.py
def mkrootfsimg(rootdir, outfile, label, size=2, sysroot=""):
    if size:
        fssize = size * (1024*1024*1024)  # 4 GiB with size=4
    else:
        fssize = None   # auto-size: minimum needed
    mkext4img(rootdir, outfile, label=label, size=fssize)
```

`--live-rootfs-size 4` → `rootfs.img` is a **4 GiB ext4**. After installing the OS (~3.5 GiB for a typical desktop spin), the ext4 has roughly **~500 MiB free**. That free space is exactly what `df` and `statvfs` report on the `/` of the live session.

The Lorax (standalone) equivalent is `--rootfs-size` (default: 2 GiB):
```
--rootfs-size  Size of root filesystem in GiB. Defaults to 2.
```
**Source: https://weldr.io/lorax/lorax.html**

### 1.3 Why the DM snapshot COW overlay does NOT help

**Source: `dmsquash-live-root.sh:L198-L203`**:
```sh
dd if=/dev/null of=/overlay bs=1024 count=1 seek=$((overlay_size * 1024)) 2>/dev/null
OVERLAY_LOOPDEV=$(losetup -f --show /overlay)
over=$OVERLAY_LOOPDEV
# …
echo 0 "$sz" snapshot "$base" "$over" PO 8 | dmsetup create live-rw
```

The DM snapshot creates a 32 GiB sparse COW file (default `rd.live.overlay.size=32768`) **in the initramfs tmpfs**. However, when `/dev/mapper/live-rw` is mounted, the kernel reports `statvfs` statistics of the **underlying ext4 filesystem** — specifically its allocated block count and free blocks. The DM snapshot COW sectors only record which ext4 blocks were written-to; they do not expand the ext4's `f_bavail`. Enlarging the COW file does nothing for the apparent free space.

```
live-rw mount  →  statvfs returns ext4 free blocks (~495 MiB)
               ≠  COW file size (32 GiB default, sparse)
               ≠  RAM (8 GiB)
```

---

## 2. The Three Overlay Modes in dracut `dmsquash-live`

| Mode | Kernel cmdline | `/var/lib/flatpak` statvfs sees | When used |
|------|---------------|----------------------------------|-----------|
| **DM snapshot** (legacy) | `rd.live.overlay.size=N` (DM COW sparse file, default 32768 MiB) | **ext4 free blocks** from `rootfs.img` | squashfs contains `LiveOS/rootfs.img` |
| **OverlayFS on /run tmpfs** | `rd.overlay=1` or `rd.overlay=tmpfs:size=Xg` | **/run tmpfs** free space (default ≈ 50% RAM) | squashfs directly has `/usr /bin …` |
| **Persistent OverlayFS** | `rd.overlay=UUID=…` or `rd.overlay=LABEL=…` | ext4/btrfs/xfs on USB partition | USB with extra partition |

**Source: dracut.cmdline(7), Arch Linux mirror: https://man.archlinux.org/man/dracut.cmdline.7, section "Booting live images"**:

> "For non-persistent OverlayFS overlays, the /run/overlayfs directory in the /run tmpfs is used for temporary storage. This filesystem is typically sized to one half of the RAM total in the system. The command: `mount -o remount,size=<nbytes> /run` will resize this virtual filesystem after booting."

> "`rd.live.overlay.size=<size_MiB>` — Specifies a non-persistent Device-mapper overlay size in MiB. The default is 32768."

**Key distinction**: `rd.live.overlay.size` only governs the DM-snapshot COW sparse file. For OverlayFS mode, it has no effect.

### Detecting which mode is active at runtime

```bash
# On the booted live system:
dmsetup status        # "live-rw: 0 N snapshot …" → DM snapshot mode
mount | grep overlay  # "overlay on / …" → OverlayFS mode
cat /proc/mounts | grep squash  # always present (the base)
```

---

## 3. Why Flatpak Sees ~495 MiB Despite 8 GiB RAM

### 3.1 statvfs path walk

Flatpak (system install) calls `statvfs("/var/lib/flatpak")` before checking `min-free-space-size`. That path resolves to:
- **DM snapshot mode**: the ext4 inside `live-rw` → free blocks = ~495 MiB (4 GiB ext4 minus ~3.5 GiB installed content)
- **OverlayFS mode**: `/run/overlayfs` upper directory in `/run` tmpfs → free = ~50% RAM minus current /run usage

**Source: Flatpak GitHub issue discussion**: https://github.com/flatpak/flatpak/issues/3187 and https://github.com/flatpak/flatpak/issues/3188

The check logic (approximate from upstream C code):
```c
struct statvfs stat;
statvfs(flatpak_install_path, &stat);
available = stat.f_bavail * stat.f_bsize;
// available ≈ 495 MiB (from ext4 free blocks)
// required  = delta_size (1.0 GiB) + min_free_space (500 MB) = 1.5 GiB
// → FAIL
```

### 3.2 The squashfs "zero blocks" is not the issue

`df` output on a live session typically shows both:
```
/dev/mapper/live-rw   4.0G  3.5G  495M  88% /         ← ext4 via DM snapshot
/dev/loop0             1.4G  1.4G     0  100% /run/initramfs/squashfs  ← read-only squashfs
```
The squashfs loop mount is always 100% full (it is a compressed read-only image). Flatpak is not checking that mount. It's checking `/var/lib/flatpak`, which is on `live-rw`, and seeing 495 MiB.

### 3.3 Why the LVM root works fine

The LVM root has a real ext4/xfs filesystem with 15.4 GiB free. Same `statvfs` call returns 15.4 GiB. `min-free-space-size=500MB` + 1.0 GiB delta = 1.5 GiB needed → 15.4 GiB available → pass.

---

## 4. Overlay Sizing: `live-rootfs-size` vs Runtime Options

| Parameter | Where set | What it controls | ISO size impact |
|-----------|-----------|-----------------|-----------------|
| `lorax --rootfs-size N` | Build time | ext4 size for the **build-time** rootfs (not live rootfs.img directly) | None (temp only) |
| `livemedia-creator --live-rootfs-size N` | Build time | **`rootfs.img` ext4 size** inside the live squashfs | ~zero (zeros compress in squashfs) |
| `rd.live.overlay.size=N` | Kernel cmdline | DM snapshot COW sparse file size (MiB); default 32768 | None (RAM-only) |
| `rd.live.ram=1` | Kernel cmdline | Copies squashfs.img to RAM before boot | Requires N GiB free RAM |
| `rd.overlay=tmpfs:size=Xg` | Kernel cmdline | OverlayFS upper dir tmpfs size | None (RAM-only) |
| `rd.overlay=LABEL=persist` | Kernel cmdline | Persistent overlayfs on labeled USB partition | None |
| `livecd-iso-to-disk --overlay-size-mb N` | USB install time | Creates a persistent overlay file on USB stick | Disk space on USB |
| `mount -o remount,size=Xg /run` | Runtime (post-boot) | Resize /run tmpfs (OverlayFS mode only) | None |

**Source: dracut.cmdline(7)** — https://man7.org/linux/man-pages/man7/dracut.cmdline.7.html  
**Source: Fedora LiveOS wiki** — https://fedoraproject.org/wiki/LiveOS_image  
**Source: weldr/lorax livemedia-creator docs** — https://weldr.io/lorax/livemedia-creator.html

---

## 5. Remediation Options (Ranked by Recommendation)

### Option A: Increase `--live-rootfs-size` (Quick Fix, squashfs-ext4 mode)

**Change**: `--live-rootfs-size 4` → `--live-rootfs-size 8` (or higher)

**Effect**: rootfs.img ext4 grows to 8 GiB. With ~3.5 GiB installed, ~4.5 GiB is free in the ext4. Flatpak sees 4.5 GiB, which clears the 1.5 GiB threshold.

**ISO size impact**: The ext4 free blocks are zeroed out by `fsck.ext4 -E discard` before squashfs compression. Zeros compress at ~1000:1 in XZ, so a 4 GiB increase in ext4 adds only ~5–15 MiB to the compressed ISO.

**Source: `weldr/lorax` `src/pylorax/creator.py:L291-L295`**:
```python
# Fsck zeros out free blocks before squashfs compression
rc = execWithRedirect(ext4path, ["-y", "-f", "-E", "discard", rootfs_img])
```

```bash
# Lorax invocation change:
lorax ... --rootfs-size 8
# or livemedia-creator:
livemedia-creator --make-iso ... --live-rootfs-size 8
```

**Downside**: Does not solve the structural issue — Flatpak installs consume ext4 free blocks permanently during a session (no reclaim after session ends), so with heavy Flatpak usage, the ext4 will eventually fill up anyway. This is a sizing improvement, not an architectural fix.

---

### Option B: Switch to OverlayFS Mode (Modern, Recommended for New Builds)

**Change**: Use `--rootfs-type squashfs` (pure squashfs, no `rootfs.img`) so dracut uses OverlayFS with the `/run` tmpfs as the upper layer.

In this mode: `statvfs("/var/lib/flatpak")` returns the free space of `/run` tmpfs, which defaults to 50% of RAM = **4 GiB with 8 GiB RAM**. This easily accommodates Flatpak installs.

**Build change**:
```bash
lorax ... --rootfs-type squashfs   # default in newer Lorax versions
# or livemedia-creator:
livemedia-creator --make-iso ... --rootfs-type squashfs
```

**Runtime kernel cmdline additions** (to ensure OverlayFS mode and size):
```
rd.overlay=1 rd.overlay=tmpfs:size=4G
```

To override `/run` tmpfs size at boot in grub:
```
linux /boot/vmlinuz ... rd.overlay rd.overlay=tmpfs:size=4G
```

Or post-boot (requires root):
```bash
mount -o remount,size=4G /run
```

**Flatpak-specific check** after switch:
```bash
df -h /var/lib/flatpak   # should show 4G tmpfs, not ext4 495M
flatpak install --system flathub <app>   # should now work
```

**Source: dracut.cmdline(7), OverlayFS section**:
```
rd.overlay=tmpfs:[size=<size>][,nr_blocks=<n>][,nr_inodes=<n>]
    Mounts a dedicated tmpfs with the specified options for the OverlayFS 
    upper directory...
    Examples:
      rd.overlay=tmpfs:size=4G
      rd.overlay=tmpfs:size=25%
```
URL: https://man.archlinux.org/man/dracut.cmdline.7 (OverlayFS section)

**Caution**: OverlayFS mode (pure squashfs) requires dracut ≥ 049 (available since Fedora 30). The initramfs must include the `overlayfs` module. Lorax's default dracut args for live builds include `dmsquash-live`, which handles this.

---

### Option C: Pre-Install Flatpaks in the Live Root (Best UX, Highest Build Cost)

If specific Flatpaks are known at build time (e.g., for a curated demo or enterprise live desktop), install them into the squashfs during image build. They will be available immediately on boot with zero install step.

**Kickstart `%post` approach** (livemedia-creator/lorax):
```bash
%post --nochroot
# Mount flatpak remotes and install into chroot
flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --system --noninteractive flathub org.gnome.Gedit
%end
```

**Azure Linux Image Customizer approach** — embed via `scripts.postCustomization`:
```yaml
# config.yaml
os:
  packages:
    install:
      - flatpak
  scripts:
    postCustomization:
      - content: |
          set -e
          flatpak remote-add --if-not-exists --system flathub \
            https://dl.flathub.org/repo/flathub.flatpakrepo
          flatpak install --system --noninteractive flathub \
            org.gnome.Gedit org.gnome.Calculator
```

**Source: Azure Linux Image Customizer docs** — https://microsoft.github.io/azure-linux-image-tools/imagecustomizer/how-to/live-iso.html

**Tradeoffs**:
- ISO size grows by the size of the Flatpak apps + runtime (e.g., GNOME Platform ≈ 800 MiB compressed)
- Apps are read-only in the squashfs; updates in the live session still need overlay space
- User cannot add arbitrary Flatpaks at runtime (still hits the 495 MiB wall for additional installs)

---

### Option D: Persistent USB Overlay (For USB Deployments Only)

If the live ISO is deployed to USB via `livecd-iso-to-disk`:
```bash
livecd-iso-to-disk --overlayfs --overlay-size-mb 4096 \
    Fedora-Live.iso /dev/sdX1
```

Or at boot time (if USB has free space for an auto-created overlay):
```
rd.overlay=LABEL=LIVE        # uses auto-created overlay partition
rd.overlay=UUID=<uuid>       # explicit partition
```

This creates a persistent OverlayFS upper on the USB stick. `statvfs` returns USB disk free space. Flatpak installs survive reboots.

**Source: Fedora LiveOS wiki** — https://fedoraproject.org/wiki/LiveOS_image (section "OverlayFS based overlay"):
> "When installation of large software packages is expected or long-term usage of a LiveOS image is anticipated, an alternate overlay strategy is advised."

---

### Option E: Lower `min-free-space-size` (Workaround, Not Recommended)

Edit `/etc/flatpak/installations.d/default.conf` or `/var/lib/flatpak/repo/config`:
```ini
[core]
min-free-space-size=50MB   # or even 0
```

This lets Flatpak proceed despite low apparent free space, but it risks a mid-install failure when the ext4 actually fills up. Writes to a full DM-snapshot ext4 cause the snapshot to overflow into "Overflow" state (kernel ≥ 4.3, Fedora ≥ 24), making `/` read-only.

**Source: Fedora LiveOS wiki**:
> "With Fedora 24 (kernel 4.3+), if the overlay storage space is filled, the overlay will enter a 'Overflow' state and the root file system will continue to operate in a read-only mode."

Only useful as a last-resort with careful size arithmetic (delta < available_ext4_free - 50 MB margin).

---

### Option F: `rd.writable.fsimg=1` (Full RAM Extraction)

```
linux /boot/vmlinuz ... rd.writable.fsimg=1 rd.minmem=1024
```

Unpacks `rootfs.img` fully into `/run/initramfs/fsimg/` tmpfs at boot, then mounts it as a writable linear DM target. No COW needed. `statvfs` sees the tmpfs (free = RAM - image_size). With 8 GiB RAM and ~1.4 GiB compressed squashfs (decompresses to ~3.5 GiB uncompressed), ~3 GiB RAM remains, giving ~3 GiB free. This works but significantly increases boot time and requires sufficient RAM.

**Source: dracut.cmdline(7)**:
> "`rd.writable.fsimg=1` — Enables writable filesystem support. The system will boot with a fully writable (but non-persistent) filesystem without snapshots. **This implies that the whole image is copied to RAM before the boot continues.**"

Kernel cmdline example:
```
root=live:CDLABEL=AzureLinux rd.live.image rd.writable.fsimg=1 rd.minmem=2048 quiet
```

---

## 6. Inspection Commands in Live Session

```bash
# Identify overlay mode
dmsetup status                            # DM snapshot: "live-rw: 0 N snapshot X/Y"
mount | grep -E 'overlay|squash|live-rw'  # shows overlay upper, lower, merged

# Check actual free space (what Flatpak sees)
df -h /var/lib/flatpak   # or df -h / 
statvfs_check() { python3 -c "import os; s=os.statvfs('$1'); print(s.f_bavail*s.f_bsize//1024//1024,'MiB free')"; }
statvfs_check /var/lib/flatpak

# DM snapshot COW status (how full is the COW file)
dmsetup status live-rw
# Output: "live-rw: 0 8388608 snapshot 42296/1048576 176"
# numerator/denominator = used/total 512-byte sectors in COW

# Show initramfs dracut args
lsinitrd /run/initramfs/initrd usr/lib/dracut/build-parameter.txt
# or for ISO initramfs:
lsinitrd /path/to/initrd.img usr/lib/dracut/build-parameter.txt

# Check rootfs.img size (DM snapshot mode)
ls -lh /run/initramfs/squashfs/LiveOS/rootfs.img

# Resize /run for OverlayFS mode (if applicable)
mount -o remount,size=5G /run
df -h /run   # verify new size
```

---

## 7. Azure Linux Image Customizer Notes

Azure Linux uses the Image Customizer tool (`imagecustomizer`) to produce LiveOS ISOs from VHDX base images. The output ISO format is ISO 9660 with a squashfs-backed LiveOS root.

**Source: https://microsoft.github.io/azure-linux-image-tools/imagecustomizer/concepts/iso.html**:
> "The Image Customizer tool can customize an input image and package the output as a Live OS iso image. A Live OS iso image is a bootable image that boots into a root file system included on the iso media without the need to have anything pre-installed on the target machine."

The Image Customizer does not expose `--live-rootfs-size` or rootfs type as a user-level parameter (as of current docs). The rootfs size is inherited from the base VHDX partition size. To control it:
1. Start from a base VHDX with a larger root partition, or
2. Use `scripts.postCustomization` to pre-install Flatpaks so fewer bytes are "new" installs in the live session, or
3. Add `kernelCommandLine.extraCommandLine` entries for overlay sizing:

```yaml
# config.yaml
os:
  kernelCommandLine:
    extraCommandLine:
      - "rd.overlay rd.overlay=tmpfs:size=4G"   # OverlayFS mode with 4G tmpfs
```

**Source: https://microsoft.github.io/azure-linux-image-tools/imagecustomizer/concepts/iso.html** (cloud-init examples show extraCommandLine pattern).

---

## 8. Known Bug Reports and References

- **Flatpak issue #3187** — "min-free-space-size 500MB would be exceeded": https://github.com/flatpak/flatpak/issues/3187 — upstream discussion of how Flatpak evaluates available space; no special casing for live sessions.
- **Flatpak issue #3188** — "flatpak install left 0B of free space": https://github.com/flatpak/flatpak/issues/3188 — reported with squashfs; statvfs returning 0.
- **Fedora LiveOS wiki** (canonical reference): https://fedoraproject.org/wiki/LiveOS_image — covers DM snapshot, OverlayFS, overlay sizing, and the "apparent vs actual" free space problem.
- **Fedora Discussion: LiveOS root system and available RAM**: https://discussion.fedoraproject.org/t/fedora-liveos-root-system-and-available-ram/82531 — confirms 32 GiB default overlay, 50% RAM for OverlayFS /run.
- **dracut.cmdline(7)**: https://man7.org/linux/man-pages/man7/dracut.cmdline.7.html — authoritative on `rd.live.overlay.size`, `rd.overlay`, `rd.writable.fsimg`.
- **dracut-ng source** (`dmsquash-live-root.sh`): https://github.com/dracut-ng/dracut/blob/main/modules.d/70dmsquash-live/dmsquash-live-root.sh — `overlay_size=32768` default, COW file creation, OverlayFS detection logic.
- **Lorax imgutils.py** (`mkrootfsimg`): https://raw.githubusercontent.com/weldr/lorax/master/src/pylorax/imgutils.py — ext4 sizing logic.
- **Lorax creator.py** (live image flow): https://raw.githubusercontent.com/weldr/lorax/master/src/pylorax/creator.py — `live_rootfs_size` handling, fsck discard before squashfs.
- **Azure Linux Image Customizer ISO docs**: https://microsoft.github.io/azure-linux-image-tools/imagecustomizer/concepts/iso.html

---

## 9. Recommended Action Matrix

| Goal | Action | Cmdline / Config change |
|------|--------|------------------------|
| **Quick fix, same stack** | Increase rootfs.img size | `--live-rootfs-size 8` in livemedia-creator |
| **Architectural fix** | Switch to OverlayFS mode | `--rootfs-type squashfs` at build; `rd.overlay rd.overlay=tmpfs:size=4G` at boot |
| **Best UX for known apps** | Pre-bake Flatpaks in squashfs | `scripts.postCustomization` in Image Customizer config |
| **USB-based persistent use** | Persistent overlay on USB | `livecd-iso-to-disk --overlayfs --overlay-size-mb 4096` |
| **Runtime rescue** | Resize /run tmpfs (OverlayFS only) | `mount -o remount,size=5G /run` |
| **Workaround only** | Lower min-free-space-size | `/var/lib/flatpak/repo/config: min-free-space-size=50MB` |
| **Document limitation** | Update live session README | Note: Flatpak installs >495 MiB unsupported in DM-snapshot live session without overlay resize |

---

## 10. Gaps and Uncertainties

- **Exact rootfs_type in the Azure Linux Lorax build**: Not confirmed whether it uses `squashfs-ext4` (legacy, likely given 495 MiB symptom) or pure `squashfs`. Run `ls /run/initramfs/squashfs/LiveOS/rootfs.img` in the live session to confirm.
- **Azure Linux Image Customizer rootfs sizing API**: The current Image Customizer docs do not expose an explicit rootfs size knob. Confirmed via https://microsoft.github.io/azure-linux-image-tools/imagecustomizer/concepts/iso.html — size comes from the base VHDX.
- **Whether dracut in the Fedora 43 / Azure Linux 3/4 initramfs supports `rd.overlay=tmpfs:size=Xg`**: The `rd.overlay=tmpfs:...` syntax was added in dracut-ng. Older dracut (pre-110) uses `rd.live.overlay.overlayfs` (now deprecated). Verify with `lsinitrd … usr/lib/dracut/modules.d/` and check if `overlayfs` module is present.
- **No upstream Fedora Bugzilla entry specifically for Flatpak + live session overlay sizing** was found. The issue is treated as a known architectural limitation ("NOTABUG") across distributions.
## Confirmed in this session

- Dark mode, `liveuser` autologin, and USB pointer input work.
- Copilot GUI and CLI, GitHub Desktop and CLI, `edit`, PowerShell, Edge
  Canary, and Code all launch and work.
- The PowerShell launcher starts and opens `pwsh`, but its distinct GNOME
  dock identity is not verified.

The next build should address the Plymouth layout and capture the actual
live-overlay layout before making another Flatpak-size change. The wallpaper
needs a product-design decision rather than another blind stock-background
swap.

## Installer ISO issues

### Issue: EFI messages before installer startup

**Observed:** The installer ISO shows the same UEFI `BdsDxe` boot-manager
messages before the graphical hand-off as the live ISO.

**Likely cause and next step:** This is the same OVMF framebuffer behavior
recorded for the live ISO. Confirm whether text continues after the kernel
has control before changing GRUB or Plymouth settings; firmware output that
precedes the kernel cannot be hidden by the image.

**Research cross-reference:** See the full Plymouth boot-splash remediation research appended under the live ISO "Issue: boot-time text before Plymouth" section for the upstream GRUB/firmware-text analysis.
### Issue: no Plymouth during installer-ISO boot

**Observed:** The installer ISO does not display Plymouth on its own boot
path. Plymouth must appear both while booting the installer ISO and on the
first boot of the system it installs.

**Cause supported by the artifact:** The installer runtime root selects
`Theme=azurelinux`, but its initramfs has only the stock commented
`plymouthd.conf` and stock `details` theme. It lacks
`azurelinux.plymouth`, `azurelinux.script`, and the Azure logo. The installer
GRUB entry does include `rhgb quiet`, but also explicitly uses
`console=ttyS0,115200 console=tty0 inst.text enforcing=0 audit=0`. The
serial/text installer configuration is intentional for the installer
runtime, but it makes visible text more likely; it does not explain away the
missing early Azure theme.

**Next fix:** Rebuild the installer initramfs with the selected Azure theme,
its script renderer payload, and its explicit Plymouth configuration.
Preserve the deliberately text-mode Anaconda path unless installer UX is
being redesigned. Verify the installer boot separately from the installed
target's first graphical boot.

**Research cross-reference:** See the full Plymouth boot-splash remediation research appended under the live ISO "Issue: boot-time text before Plymouth" section for upstream dracut/Plymouth theme-inclusion analysis and remediation options.
### Verified: installer administrator account flow

The standard installer asks for one administrator username and a confirmed
password before Anaconda begins. The supplied account is injected as a
hashed wheel-user directive and root remains locked. The administrator
credential prompt worked in the `2026.07.22` installer QA run.

## Installed-system issues

### Issue: no Plymouth on the installed system and visible SELinux relabel

**Observed:** The first installed-system boot showed systemd text rather than
Plymouth. SELinux then reported that a relabel was required, ran
`/sbin/fixfiles -T 0 restore`, and the VM needed a forced reboot before
reaching the desktop.

**Cause:** A full first-boot SELinux relabel can be expected after Anaconda
creates a new target. It is not by itself proof of a policy failure. The
problem is that Plymouth did not cover the relabel and boot path, so the user
sees the low-level operation and is left without clear graphical progress.

**On-disk evidence:** Unlike either ISO initramfs, the installed target's
initramfs contains the Azure theme files and an explicit
`Theme=azurelinux` configuration. Its BLS entry also contains `rhgb quiet`;
the root configuration selects the same theme. The installed image has
matching `plymouth`, `plymouth-plugin-script`, and label-plugin packages.
Missing visible Plymouth is therefore a runtime activation/graphics-path
problem, not an omitted asset, theme selection, or boot argument.

**Next fix:** Capture Plymouth and kernel logs from a fresh installed first
boot and check the early DRM/framebuffer path before changing configuration.
Re-run the first boot without manual intervention; the relabel may remain
necessary once, but it must be covered by graphical progress and complete
cleanly.

**Research cross-reference:** See the full Plymouth boot-splash remediation research appended under the live ISO "Issue: boot-time text before Plymouth" section for upstream serial-console/simpledrm analysis and remediation options.
### Issue: installed default background is still generic

**Observed:** The installed target has the same plain blue Adwaita
background as the live ISO.

**Cause, tried, and next fix:** This is the same product-design issue as the
live ISO default background above. The installer writes the same Adwaita
dconf URIs successfully, but matching a stock host default is not a
distinctive Azure Linux Desktop background. Ship a project-owned, licensed
default across live, disk, and installer artifacts.

**Research cross-reference:** The full wallpaper/branding remediation research is appended immediately before the live ISO "Issue: PowerShell dock identity" section under "Issue: default desktop background".
### Issue: installed dock does not include PowerShell

**Observed:** The first installed GNOME session dock contains Edge Canary,
Code, GitHub Desktop, and Files, but not PowerShell. PowerShell is installed
and works when launched manually.

**On-disk evidence:** The installed `local.d/00-azl-desktop-defaults` source
and compiled `/etc/dconf/db/local` both contain
`org.azurelinux.PowerShell.desktop` in `favorite-apps`; no per-user dconf
override was found. The desktop entry and helper are byte-identical to the
live image. This rules out missing staged assets, a missing system favorite,
and the audited per-user override. It does not prove GNOME applied the
system default during the first session.

**Next fix:** Inspect the installed target's
`/etc/dconf/db/local`, `/etc/dconf/profile/user`, and
`/usr/share/applications/org.azurelinux.PowerShell.desktop`. Confirm the
system dconf database contains `org.azurelinux.PowerShell.desktop` and that
the administrator has no overriding per-user favorites. Then test first
login from a fresh installed account.

**Research cross-reference:** The full GNOME application-identity and dock remediation research is appended immediately before the live ISO "Issue: Flatpak live-session space" section under "Issue: PowerShell dock identity".
### Issue: `edit` is installed but absent from GNOME

**Observed:** `edit` is installed, but no Edit icon appears in GNOME's
application overview or dock.

**On-disk evidence:** `/usr/share/applications/edit.desktop` is present,
root-owned, mode 0644, and passes `desktop-file-validate`. Its
`/usr/local/bin/edit` target is also present; neither is RPM-owned. This
rules out package absence and a malformed entry, leaving desktop database or
GNOME session discovery state.

**Next fix:** Inspect the installed target's
`/usr/share/applications/edit.desktop`, its executable path, and
`update-desktop-database` result. Add Edit to the intended default favorites
only after its application entry is discoverable in GNOME.

**Research cross-reference:** The full GNOME application-discovery remediation research is appended under the live ISO "Issue: PowerShell dock identity" section.
### Issue: installed administrator defaults to Bash

**Implemented fix (2026-07-22):** The installer launcher now injects the administrator account with `--shell=/usr/bin/pwsh` in the generated kickstart user directive. This keeps the single-admin interactive flow intact while making the installed administrator default to PowerShell.

**Changed files:**
- `kiwi/anaconda-launcher.sh`

**Status:** The original `2026.07.22` artifact still exhibited Bash for the dynamically created administrator account. The source fix is now in place for the next artifact build.

**On-disk effect expected in next artifact:** The generated `/run/install/ks.cfg` user line now includes `--shell=/usr/bin/pwsh`, so Anaconda calls `useradd -s /usr/bin/pwsh ...` for the installer-created administrator account.

**Research cross-reference:** The full Anaconda kickstart shell and .NET remediation research is appended immediately before the installed target "Confirmed on the installed target" section under "Issue: .NET launcher is absent and CLI first run reports an error".


### Issue: .NET launcher is absent and CLI first run reports an error

**Implemented fix (2026-07-22):** Replaced the invalid inline shell `Exec=` in `dotnet.desktop` with a dedicated helper script. This removes Desktop Entry reserved-character violations and makes the `.NET` launcher discoverable by GNOME.

**Changed files:**
- `assets/desktop/dotnet.desktop`
- `assets/bin/azl-dotnet-terminal` (new)
- `kickstart/azurelinux-desktop-live.ks`
- `kiwi/azl-install.ks.in`

**Validation:** `desktop-file-validate assets/desktop/dotnet.desktop` passes after the update.

**Status:** The original `2026.07.22` artifact showed no GNOME `.NET` icon and reported first-run CLI workload noise. The launcher-format root cause is fixed in source for the next artifact build. The separate CLI first-run/workload behavior still needs runtime capture in the rebuilt artifact.

**On-disk effect expected in next artifact:**
- `/usr/share/applications/dotnet.desktop` uses `Exec=/usr/local/bin/azl-dotnet-terminal`
- `/usr/local/bin/azl-dotnet-terminal` exists in both live and installed targets and launches `gnome-terminal -- /usr/bin/dotnet --info`
- GNOME should enumerate the desktop entry once the rebuilt artifact is booted and session caches are fresh



## Findings Report: Shell Default and .NET First-Run Remediation

### Summary

Both issues are confirmed and root-caused from the source code and project files. Issue 1 (shell) has a one-line fix in `anaconda-launcher.sh` and is safe because Anaconda's `useradd` doesn't check `/etc/shells`, and the `%post` section in `azl-install.ks.in` already adds `/usr/bin/pwsh` to `/etc/shells`. Issue 2 splits into two independent sub-problems: (a) the `.NET` desktop icon is absent because `dotnet.desktop`'s `Exec` field violates the Desktop Entry spec, and (b) the CLI first-run noise is a combination of the workload integrity checker finding a mismatch between the installed preview.6 SDK and the stale preview.1 workload-manifest tree, plus the fact that the right suppression environment variables are not set system-wide.

---

## Issue 1 — Default shell for installer-created administrator

### Root cause

`anaconda-launcher.sh:kiwi/anaconda-launcher.sh:65-77` — the `write_kickstart_with_admin_user` function generates:

```bash
printf 'user --name=%s --groups=wheel --password=%s --iscrypted\n' \
    "$ADMIN_USER" "$ADMIN_PASSWORD_HASH" > "$account_directive"
```

No `--shell=` option. Anaconda therefore calls `useradd` without `-s`, which picks up the system default (`/bin/bash` from `/etc/default/useradd`).

### Kickstart `user --shell` syntax — verified in source

From `pykickstart/pykickstart:pykickstart/commands/user.py` (SHA `4d09a47`):

```python
# FC6_User._getParser() — available since Fedora Core 6
op.add_argument("--shell", version=FC6, help="""
    The user's login shell. If not provided, this defaults
    to the system default.""")
```

The test suite confirms the exact syntax (`pykickstart/pykickstart:tests/commands/user.py`):

```
user --groups=grp1,grp2 --homedir=/home/user --name=user --password --iscrypted \
  --shell=/bin/bash --uid=1000
```

### How Anaconda applies the shell — verified in source

`rhinstaller/anaconda:pyanaconda/core/users.py` (confirmed `create_user` function):

```python
if shell:
    args.extend(["-s", shell])
# ...
status = util.execWithRedirect("useradd", args)
```

**Key fact:** `useradd` does NOT check `/etc/shells`. It accepts any absolute path. No validation failure risk.

### `/etc/shells` and PAM considerations

- `/etc/shells` is consulted by `chsh(1)` and `pam_shells(8)` — **not by `useradd` itself** (`man7.org/linux/man-pages/man5/shells.5.html`).
- GDM/GNOME does not invoke `pam_shells`. It uses the `gdm-password` / `gdm-autologin` PAM stacks, which do not include `pam_shells`. The login shell in `/etc/passwd` is never checked during a GDM graphical session.
- `pam_shells` is present in `/etc/pam.d/login` (TTY logins). If `/usr/bin/pwsh` is NOT in `/etc/shells`, a TTY `login` would fail for this user.
- **The `azl-install.ks.in` `%post` already handles this.** It adds `/usr/bin/pwsh` to `/etc/shells` before `useradd` completes (the `%post` runs after the `user` directive is applied, so the timing is correct):

```bash
# azurelinux-desktop-iso/kiwi/azl-install.ks.in — existing %post block
if [ -x /usr/bin/pwsh ]; then
    if ! grep -q '^/usr/bin/pwsh$' /etc/shells; then
        echo /usr/bin/pwsh >> /etc/shells
    fi
    usermod --shell /usr/bin/pwsh root 2>/dev/null || true
fi
```

This already covers `/etc/shells` and root. The admin user just needs `--shell=` added to its directive.

### PowerShell as a login shell — official documentation

From `PowerShell/PowerShell:assets/manpage/pwsh.1.ronn` (SHA `98320cc`):

```
To set up `pwsh` as the login shell:

- Verify that the full absolute path to `pwsh` is listed under `/etc/shells`
  - This path is usually something like `/opt/microsoft/powershell/7/pwsh` on Linux
  - If `pwsh` isn't present in `/etc/shells`, use an editor to append the path...
- Use the `chsh` utility to set your current user's shell to `pwsh`:
    chsh -s /usr/bin/pwsh

On Linux and macOS, starts PowerShell as a login shell, using `/bin/sh` to
execute login profiles such as `/etc/profile` and `~/.profile`.
```

PowerShell 7.0+ supports `-Login` / `-l` flag for login-shell semantics (sources `/etc/profile` and `~/.profile`). Installed version: `7.6.4-1.rh.x86_64` at `/usr/bin/pwsh`.

### GNOME/GDM behavior with non-bash login shell

- **GDM graphical session:** Unaffected. GDM starts the session via `gdm-wayland-session` / `gdm-x-session`, not via the user's login shell. The shell in `/etc/passwd` is irrelevant to GNOME session launch.
- **`gnome-terminal` (default mode):** Launches an interactive non-login shell using whatever is in `/etc/passwd` — so `pwsh` will be the terminal's shell. This is the intended behavior.
- **TTY (Ctrl+Alt+F2):** Uses `login` → `pam_shells` check → `/etc/shells` must include `/usr/bin/pwsh`. Already guaranteed by the `%post` block above.
- **Recovery/emergency shell:** Systemd's emergency/rescue targets spawn `/bin/bash` or `/bin/sh` directly, regardless of user shell — unaffected.
- **SSH:** Uses the shell from `/etc/passwd` — will launch `pwsh`. Consistent with intent.

### Remediation — Option A (recommended, single-line change)

In `kiwi/anaconda-launcher.sh`, in `write_kickstart_with_admin_user()`:

```bash
# Before (line 72):
printf 'user --name=%s --groups=wheel --password=%s --iscrypted\n' \
    "$ADMIN_USER" "$ADMIN_PASSWORD_HASH" > "$account_directive"

# After:
printf 'user --name=%s --groups=wheel --password=%s --iscrypted --shell=/usr/bin/pwsh\n' \
    "$ADMIN_USER" "$ADMIN_PASSWORD_HASH" > "$account_directive"
```

This generates:
```
user --name=alice --groups=wheel --password=$6$<hash> --iscrypted --shell=/usr/bin/pwsh
```

Anaconda → pykickstart parses `--shell=/usr/bin/pwsh` → passes `shell="/usr/bin/pwsh"` → `useradd -s /usr/bin/pwsh alice`. The `%post` block that follows already ensures `/usr/bin/pwsh` is in `/etc/shells`.

### Remediation — Option B (belt-and-suspenders, in `post-install.sh`)

If you prefer to keep account creation in the kickstart directive as-is and post-process:

```bash
# kiwi/post-install.sh — add after the root shell block
if [ -x /usr/bin/pwsh ]; then
    # Change shell for all non-system users in the wheel group
    for user in $(getent group wheel | cut -d: -f4 | tr ',' '\n'); do
        id "$user" 2>/dev/null || continue
        uid=$(id -u "$user")
        [ "$uid" -ge 1000 ] && usermod --shell /usr/bin/pwsh "$user" || true
    done
fi
```

Option A is cleaner. Option B is a fallback if multiple admin accounts need the same treatment.

---

## Issue 2 — .NET CLI first-run error and missing icon

### 2a — Missing .NET icon (root-caused and confirmed)

**Confirmed in:** `azurelinux-desktop-iso/findings/final_polish.md:421-448`

The current `assets/desktop/dotnet.desktop` `Exec` line:

```ini
Exec=gnome-terminal --title=".NET" -- /bin/sh -c 'dotnet --info; exec $SHELL'
```

**Spec violations in `Exec` field** (Desktop Entry Specification §6.6):
- Single quotes (`'...'`) — not legal quoting; only double quotes allowed
- Semicolon (`;`) — reserved separator for multiple `Exec` values in some contexts
- `$SHELL` — environment variable expansion is not performed in `Exec` values

`desktop-file-validate` rejects this entry. GNOME Shell omits any `.desktop` file that fails validation from application discovery. The icon never appears.

The fix pattern is established by `org.azurelinux.PowerShell.desktop` (which is valid): introduce a helper script.

**Remediation:**

Create `assets/bin/azl-dotnet-terminal` (new file, analogous to `azl-powershell-terminal`):

```sh
#!/bin/sh
# /usr/local/bin/azl-dotnet-terminal
exec gnome-terminal --title=".NET" -- dotnet --info
```

Update `assets/desktop/dotnet.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=.NET
Comment=Check the installed .NET SDK/runtime versions
Exec=/usr/local/bin/azl-dotnet-terminal
Icon=/usr/share/pixmaps/dotnet.svg
Terminal=false
Categories=Development;
StartupNotify=true
```

Add the new helper to `kiwi/azl-install.ks.in`'s `%post --nochroot` block (it already copies `azl-powershell-terminal`; add the analogous line):

```bash
cp -v "$ASSETS/bin/azl-dotnet-terminal" /mnt/sysroot/usr/local/bin/azl-dotnet-terminal
chmod 0755 /mnt/sysroot/usr/local/bin/azl-dotnet-terminal
```

And in the live kickstart (`azurelinux-desktop-live-disk.ks`), add the analogous `cp` and `chmod` alongside the existing lines at ~line 432.

> **Note on `dotnet --info` as the first-run trigger:** Using `dotnet --info` in the launcher will trigger the first-run experience on the administrator's first launch. See section 2b for how to suppress that.

### 2b — .NET CLI first-run noise and workload verification error

#### What the first-run sequence actually does

From `dotnet/sdk:src/Cli/dotnet/FirstRunExperience.cs` (SHA `25044b7`) and `DotnetFirstTimeUseConfigurer.cs` (SHA `a364b41`):

1. Checks `FirstTimeUseNoticeSentinel` in `~/.dotnet/`. If absent → first run.
2. Prints welcome banner and telemetry notice (suppressed by `DOTNET_NOLOGO=true`).
3. Runs NuGet state migration.
4. Generates ASP.NET dev cert via `AspNetCore.DeveloperCertificates.XPlat.CertificateGenerator.GenerateAspNetHttpsCertificate()` (in-process BCL crypto, no subprocess) — suppressed by `DOTNET_GENERATE_ASPNET_CERTIFICATE=false`.
5. Adds global tools to `$PATH` sentinel — suppressed by `DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=false`.
6. Runs `WorkloadIntegrityChecker.RunFirstUseCheck()` — suppressed by `DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=true`.

The "workload verification had a problem" message is `CliStrings.WorkloadIntegrityCheckError` (confirmed in 14 xlf translation files), which reads:

> **"An issue was encountered verifying workloads. For more information, run 'dotnet workload update'."**

This is printed in yellow and the exception is fully swallowed:

```csharp
// dotnet/sdk:src/Cli/dotnet/FirstRunExperience.cs:~line 120
try
{
    WorkloadIntegrityChecker.RunFirstUseCheck(reporter);
}
catch (Exception)
{
    // If the workload check fails for any reason, we want to eat the failure
    // and continue running the command.
    reporter.WriteLine(CliStrings.WorkloadIntegrityCheckError.Yellow());
}
```

#### What `WorkloadIntegrityChecker` does and why it fails

`dotnet/sdk:src/Cli/dotnet/Commands/Workload/WorkloadIntegrityChecker.cs` (SHA `7002d4c`):

```csharp
public static void RunFirstUseCheck(IReporter reporter)
{
    var creationResult = new WorkloadResolverFactory().Create();
    var sdkFeatureBand = new SdkFeatureBand(creationResult.SdkVersion);
    // ...
    var repository = installer.GetWorkloadInstallationRecordRepository();
    var installedWorkloads = repository.GetInstalledWorkloads(sdkFeatureBand);

    if (installedWorkloads.Any())
    {
        reporter.WriteLine(CliCommandStrings.WorkloadIntegrityCheck);
        CliTransaction.RunNew(context => installer.InstallWorkloads(...));
    }
}
```

`SdkFeatureBand` for SDK `11.0.100-0.1.preview.6.26359.118` resolves to band `11.0.100-preview.6`. The file-based record repository checks `{dotnet_root}/metadata/workloads/11.0.100-preview.6/InstalledWorkloads/`.

**The preview.1 + preview.6 mismatch:** Both `11.0.100-preview.1.*` and `11.0.100-preview.6.*` manifest trees are installed under `/usr/share/dotnet/sdk-manifests/`. Install records from the RPM installation may exist for one or both bands. If records exist under the preview.6 band, the integrity checker tries to reinstall them via NuGet — but the preview NuGet packages may not be on the configured feeds (the offline repo bundled by KIWI or the `ms-prod` RHEL9 repo). This triggers the caught exception → yellow warning.

From `dotnet/sdk:src/Cli/dotnet/Commands/Workload/WorkloadInstallDetector.cs` (SHA `e57ba55`):

```csharp
var metadataDir = Path.Combine(workloadRootDir, "metadata", "workloads");
return new FileBasedInstallationRecordRepository(metadataDir)
    .GetInstalledWorkloads(sdkFeatureBand)
    .Any();
```

On Linux, `ShouldVerifySignatures()` always returns `false` (compile-time `#if !TARGET_WINDOWS`), so no signature issue — it's purely a NuGet package resolution failure for the preview workload packs.

#### "Specified command or file was not found"

This error appears **after** the first-run block completes (the workload exception is swallowed). The `dotnet` host driver resolves CLI commands to DLLs in `/usr/share/dotnet/sdk/<version>/`. The most likely explanation:

The `dotnet.desktop`'s `Exec` launches `/bin/sh -c 'dotnet --info; exec $SHELL'`. Even if GNOME ignores the invalid entry, if the command is run manually or via a terminal, `dotnet --info` completes its first-run banner/cert/workload steps and then invokes `dotnet-info.dll` (or `Microsoft.DotNet.Cli.dll` with the `info` subcommand). With two preview-band manifest trees, the workload resolver may return a path to a workload pack that doesn't exist on disk (because the pack was registered in the preview.1 manifest but installed under the preview.6 path, or vice versa), producing a `FileNotFoundException` whose message becomes "a specified command or file was not found."

**Diagnostics to capture the exact error:**

```bash
DOTNET_HOST_TRACE=1 DOTNET_HOST_TRACEFILE=/tmp/host_trace.txt dotnet --info 2>&1 | tee /tmp/dotnet-info.txt
dotnet workload list 2>&1 | tee /tmp/dotnet-workload-list.txt
ls /usr/share/dotnet/sdk-manifests/
ls /usr/share/dotnet/metadata/workloads/ 2>/dev/null || echo "(no workload metadata dir)"
```

This will show exactly which DLL failed to load and which workload bands have install records.

#### Environment variables — current status in .NET 11 preview

| Variable | Effect | Status |
|---|---|---|
| `DOTNET_NOLOGO` | Suppresses welcome banner + telemetry notice | **Current; replaces the deprecated `DOTNET_SKIP_FIRST_TIME_EXPERIENCE`** |
| `DOTNET_SKIP_FIRST_TIME_EXPERIENCE` | Deprecated since .NET Core 3.0; only suppressed `NuGetFallbackFolder` expansion | **Do not use** — has no effect in .NET 11 |
| `DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK` | Skips `WorkloadIntegrityChecker.RunFirstUseCheck()` | **Current** (defaults to `true` in CI) |
| `DOTNET_GENERATE_ASPNET_CERTIFICATE` | Controls dev-cert generation | **Current** (default `true`) |
| `DOTNET_CLI_TELEMETRY_OPTOUT` | Opt out of telemetry | Current |
| `DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE` | Disable background workload manifest downloads | Current |
| `SuppressNETCoreSdkPreviewMessage` | Suppress "You are using a preview version" banner | Current |
| `DOTNET_CLI_ENABLEAOT` | NativeAOT fast path (Preview 7+ only, Linux disabled by default) | Not applicable on preview.6 Linux |

Sources: `learn.microsoft.com/en-us/dotnet/core/tools/dotnet-environment-variables` and `dotnet/sdk:src/Common/EnvironmentVariableNames.cs` (SHA `7d57ecd`).

#### Remediation options

**Fix 2b-1: Set suppression environment variables system-wide** (add to `kiwi/post-install.sh` or the `%post` block):

```bash
# Suppress .NET 11 preview first-run experience for all users
cat > /etc/profile.d/dotnet-firstrun.sh << 'EOF'
# Suppress .NET CLI first-run banners, dev-cert generation, and workload
# integrity repair for a pre-configured installed image.
export DOTNET_NOLOGO=true
export DOTNET_CLI_TELEMETRY_OPTOUT=true
export DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=true
export DOTNET_GENERATE_ASPNET_CERTIFICATE=false
export DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE=true
export SuppressNETCoreSdkPreviewMessage=true
EOF
```

`/etc/profile.d/` is sourced by every login and interactive shell session. This prevents all first-run triggers for any user (including the dynamically-created administrator).

**Fix 2b-2: Remove stale preview.1 workload-manifest trees** (add to `%post` in `azl-install.ks.in`):

```bash
# Remove workload manifest trees that don't match the installed SDK feature band.
# The installed SDK is preview.6; preview.1 manifests are stale.
for stale_band_dir in /usr/share/dotnet/sdk-manifests/11.0.100-preview.1*; do
    [ -d "$stale_band_dir" ] && rm -rf "$stale_band_dir" && \
        echo "Removed stale workload manifest: $stale_band_dir"
done
# Remove workload install records for the stale band too
rm -rf /usr/share/dotnet/metadata/workloads/11.0.100-preview.1* 2>/dev/null || true
```

**Fix 2b-3: Pre-create first-run sentinels for the installer-created user** (if you want first-run to never trigger even once):

The sentinel files live in `~/.dotnet/`. The approach is to pre-create them in `/etc/skel/.dotnet/` so every new user inherits them:

```bash
# kiwi/post-install.sh — pre-seed first-run sentinels
SDK_VERSION=$(dotnet --version 2>/dev/null || echo "11.0.100-preview.6.26359.118")
mkdir -p /etc/skel/.dotnet
# Suppress first-use notice for new accounts
touch "/etc/skel/.dotnet/${SDK_VERSION}.dotnetFirstUseSentinel"
# Suppress asp.net cert for new accounts
touch "/etc/skel/.dotnet/aspNetHttpsCertificate.sentinel"
```

> **Note:** The sentinel filenames include the full SDK version string. Pre-creating them in `/etc/skel` means any user created *after* this runs (including the dynamically injected admin user) gets them via `useradd --create-home` skeleton copy. For the `DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=true` env var, the `profile.d` approach (Fix 2b-1) is more robust since it doesn't depend on knowing the exact SDK version string at image-build time.

**Fix 2b-4: Run `dotnet workload update` in `%post`** (normalizes workload state before first user login):

```bash
# Normalize workload state during install so no user sees the repair on first use
DOTNET_CLI_TELEMETRY_OPTOUT=true \
DOTNET_NOLOGO=true \
DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=true \
    dotnet workload update --source "file:///opt/azl-offline-repo" 2>/dev/null || \
    echo "WARNING: dotnet workload update failed (non-fatal for pre-built image)" >&2
```

This is optional and may fail in the offline install environment if the workload packages aren't in the offline repo. The environment variable approach (Fix 2b-1) is the pragmatic choice.

---

## Cross-references and key source citations

| Topic | Source | Location |
|---|---|---|
| `user --shell` option, syntax since FC6 | `pykickstart/pykickstart:pykickstart/commands/user.py` | `op.add_argument("--shell", version=FC6, ...)` |
| Anaconda `useradd -s <shell>` call | `rhinstaller/anaconda:pyanaconda/core/users.py` | `if shell: args.extend(["-s", shell])` |
| `/etc/shells` consulted by `chsh`, not `useradd` | `man7.org/linux/man-pages/man5/shells.5.html` | "This file is consulted by `chsh(1)`" |
| `pwsh -Login` login-shell semantics | `PowerShell/PowerShell:assets/manpage/pwsh.1.ronn` | SHA `98320cc`, Login section |
| .NET first-run flow source | `dotnet/sdk:src/Cli/dotnet/FirstRunExperience.cs` | SHA `25044b7` |
| `DotnetFirstTimeUseConfigurer.Configure()` | `dotnet/sdk:src/Cli/Microsoft.DotNet.Configurer/DotnetFirstTimeUseConfigurer.cs` | SHA `a364b41` |
| `WorkloadIntegrityChecker` source | `dotnet/sdk:src/Cli/dotnet/Commands/Workload/WorkloadIntegrityChecker.cs` | SHA `7002d4c` |
| `WorkloadIntegrityCheckError` exact message | `dotnet/sdk:src/Cli/dotnet/xlf/CliStrings.tr.xlf` (and 13 other translations) | "An issue was encountered verifying workloads…" |
| `DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK` | `dotnet/sdk:src/Common/EnvironmentVariableNames.cs` | SHA `7d57ecd` |
| All .NET env vars | `learn.microsoft.com/en-us/dotnet/core/tools/dotnet-environment-variables` | `DOTNET_NOLOGO`, `DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK`, etc. |
| `WorkloadInstallDetector` filesystem check | `dotnet/sdk:src/Cli/dotnet/Commands/Workload/WorkloadInstallDetector.cs` | SHA `e57ba55` |
| Workload signing — Linux always `false` | `dotnet/sdk:src/Cli/dotnet/Commands/Workload/SIGNING-VERIFICATION.md` | "Linux and macOS — not enforced … `#if !TARGET_WINDOWS`" |
| Invalid `dotnet.desktop` Exec | `azurelinux-desktop-iso/findings/final_polish.md:441-449` | Single quotes/semicolon/`$SHELL` in Exec field |
| Missing admin `--shell=` root cause | `azurelinux-desktop-iso/findings/final_polish.md:302-311` | Confirmed on installed target |
| Current `%post` shell block | `azurelinux-desktop-iso/kiwi/azl-install.ks.in` | `if [ -x /usr/bin/pwsh ]; then … usermod --shell /usr/bin/pwsh root` |
| Launcher script user directive | `azurelinux-desktop-iso/kiwi/anaconda-launcher.sh:65-77` | `printf 'user --name=%s … --iscrypted\n'` — no `--shell=` |

---

## Gaps and uncertainties

1. **Exact "specified command or file was not found" source not confirmed.** The finding in `final_polish.md` reports it was observed but the exact stderr/stdout transcript wasn't captured. Before fixing, run the diagnostics in Fix 2b (the `DOTNET_HOST_TRACE` commands) against a live installed system to confirm whether it's the workload manifest resolver or the command DLL lookup.

2. **Whether `dotnet --version` truly triggers first-run in preview.6.** The source (`FirstRunExperience.cs:50-53`) shows `Terminating: true` actions skip first-run. In NativeAOT paths (Preview 7+, Linux disabled by default), the check differs. If the user ran `dotnet --info` (not `--version`) via the invalid desktop file's shell command, that would trigger first-run normally. Confirm by checking whether `FirstTimeUseNoticeSentinel` exists at `~/.dotnet/<version>.dotnetFirstUseSentinel` before and after running `dotnet --version`.

3. **Exact workload metadata directory structure on the installed target not inspected.** `ls /usr/share/dotnet/metadata/workloads/` needed to confirm whether preview.1 band records are actually present. The preview.1 + preview.6 manifest co-installation is confirmed from the findings file, but whether install records exist for preview.1 is not.

4. **PowerShell RPM does not add `/usr/bin/pwsh` to `/etc/shells` on Linux.** The macOS package does (PowerShell/PowerShell CHANGELOG/7.0.md: "Add to `/etc/shells` on macOS"). For Linux, this is a manual step — already handled by the existing `%post` block in `azl-install.ks.in`.

5. **`pwsh` as login shell + GNOME Keyring:** GNOME Keyring's PAM module (`pam_gnome_keyring`) is in the session stack. It interacts with the login shell during session startup. Since GDM autologin is configured and the `pam_gnome_keyring.so auto_start` PAM line is already added in the `%post` block, this should be unaffected by the shell change — but it should be tested in a fresh installed session.
### Confirmed on the installed target

- Copilot CLI and GUI, Edge Canary, GitHub Desktop, GitHub CLI, PowerShell,
  and Flatpak work.
- The administrator username/password flow completed successfully.

## Read-only artifact audit

The completed installer QCOW2 and the published live ISO root were mounted
read-only after GUI QA. This section records the files and package state
behind the observations above. It contains no account names or host details.

### Boot, Plymouth, and SELinux

The installed target uses an automatic UEFI/LVM layout:

```text
EFI system partition: 600 MiB
/boot:                2 GiB ext4
root:                 27.4 GiB ext4 on anaconda_azurelinux-desktop LVM
```

Its BLS entry has:

```text
options root=/dev/mapper/anaconda_azurelinux--desktop-root ro \
  console=ttyS0,115200 rd.lvm.lv=anaconda_azurelinux-desktop/root \
  console=tty0 rhgb quiet
```

The installed `/boot/initramfs-6.18.31-1.6.azl4.x86_64.img` contains
`plymouthd`, `azurelinux.plymouth`, `azurelinux.script`, and
`azurelinuxlogo.png`; its embedded `plymouthd.conf` explicitly selects
`Theme=azurelinux`. The root configuration makes the same selection, while
the distribution default remains `bgrt`. This means the missing visible
Plymouth is not explained by an absent boot argument, theme selection, or
absent theme files. The next investigation must trace runtime Plymouth
activation rather than adding duplicate assets.

In contrast, both published ISO initramfs images contain the Plymouth DRM and
framebuffer renderers plus the stock `details` theme, but neither contains
the Azure theme files. Their embedded `plymouthd.conf` is the untouched
commented template, even though their mounted runtime roots select
`Theme=azurelinux`. The live and installed images use
`plymouth-24.004.60-24`; the installer runtime uses
`plymouth-24.004.60-20`. All include the script and label plugins. This
separates the ISO early-boot asset/configuration defect from the installed
system's runtime activation defect.

SELinux is configured as `SELINUX=enforcing` with
`SELINUXTYPE=targeted`. The installed root has no `.autorelabel` file after
the observed first boot, while
`selinux-autorelabel-mark.service` remains enabled in
`sysinit.target.wants`. The screenshot therefore captured the expected
first-boot relabel path completing without a graphical splash, not a
persisting relabel request.

### Background, favorites, and desktop files

Both the installed target and live root compile these system dconf background
values:

```text
picture-uri=file:///usr/share/backgrounds/gnome/adwaita-l.jxl
picture-uri-dark=file:///usr/share/backgrounds/gnome/adwaita-d.jxl
picture-options=zoom
```

The corresponding light and dark image files are present and byte-identical
between the two roots. The installed target additionally compiles this
system default:

```text
favorite-apps=[
  microsoft-edge-canary.desktop,
  code-insiders.desktop,
  org.azurelinux.PowerShell.desktop,
  GitHub Copilot.desktop,
  org.gnome.Nautilus.desktop
]
```

The live root deliberately does not ship that favorite list in `/etc/dconf`;
its `livesys-gnome` session setup writes the same list as a GNOME Shell schema
override and recompiles schemas during live boot. The installed administrator
has no per-user dconf database under `~/.config/dconf` overriding the system
favorite. This proves the generic background is not a missing URI and narrows
the missing installed PowerShell icon to first-session application, timing,
or cache behavior. The live dock still needs runtime inspection because the
favorite is applied by `livesys`, not the root dconf database.

The installed target contains these root-owned, mode-0644 post-install
desktop entries in `/usr/share/applications`; none is owned by an RPM:

| File | Validation | Relevant command |
| --- | --- | --- |
| `org.azurelinux.PowerShell.desktop` | valid | `Exec=/usr/local/bin/azl-powershell-terminal` |
| `edit.desktop` | valid | `Exec=gnome-terminal --title=edit -- /usr/local/bin/edit %F` |
| `dotnet.desktop` | invalid | see below |

`edit` is a project-staged executable at `/usr/local/bin/edit`, not an RPM
payload. Its valid desktop file and executable are present despite its
absence from GNOME. The next diagnosis is GNOME desktop discovery/cache
state, not package installation: run `update-desktop-database` in the target
post-install path and verify discovery from a newly created GNOME session.

The .NET desktop entry is invalid. `desktop-file-validate` rejects its
current `Exec` value:

```ini
Exec=gnome-terminal --title=".NET" -- /bin/sh -c 'dotnet --info; exec $SHELL'
```

The single quotes, semicolon, and `$SHELL` are reserved Desktop Entry
characters in that field. GNOME may omit this invalid entry, which explains
the missing .NET icon. The launcher needs a project helper script, like
PowerShell, and a simple valid `Exec=/usr/local/bin/...` desktop value.

### Shell, .NET, and Flatpak packages

The dynamically generated administrator account has `/bin/bash` as its
shell. This is directly explained by the generated Anaconda `user` directive
having no `--shell=/usr/bin/pwsh`; it is not a missing PowerShell package.

Installed package versions:

```text
powershell                    7.6.4-1.rh.x86_64
dotnet-sdk-11.0               11.0.100-0.1.preview.6.26359.118.x86_64
dotnet-runtime-11.0           11.0.0-0.1.preview.6.26359.118.x86_64
flatpak                       1.16.6-1.fc43.x86_64
gnome-backgrounds             49.0-1.fc43.noarch
gnome-terminal                3.56.3-1.fc43.x86_64
azurelinux-desktop-policy     6.18.31-1.6.azl4.x86_64
```

`/usr/bin/dotnet` belongs to `dotnet-host-11.0`; the SDK and both preview.1
and preview.6 workload-manifest trees are installed. The CLI failure is
therefore not a missing SDK/runtime binary. Capture a fresh exact
`dotnet --info`, `dotnet --version`, and `dotnet workload list` transcript
before changing packages.

The installed Flatpak repository is configured for Flathub and has
`min-free-space-size=500MB`. Flatpak works on the installed target because
the LVM root had about 15.4 GiB free at audit time. The same 500 MiB safety
reserve is a direct contributor to the live ISO failure when its visible
writable layer reports about 495 MiB free. The mounted live root itself is a
read-only squashfs with zero available blocks; its boot-time writable overlay
must be measured in a running guest.

### Live ISO versus installed QCOW2 package diff

The normalized installed RPM inventories contain 1,175 package names in the
live root and 1,029 in the installed target. They share 1,028 names. The
installed target has only `glibc-minimal-langpack` that is absent from the
live root. The live-only set has 147 names:

```text
anaconda-core
anaconda-live
anaconda-tui
anaconda-webui
augeas-libs
blivet-data
clevis
clevis-luks
clevis-pin-tpm2
cloud-utils-growpart
cmake-filesystem
cockpit-bridge
cockpit-storaged
cockpit-system
cockpit-ws
cockpit-ws-selinux
dbus-daemon
dbus-tools
device-mapper-multipath
device-mapper-multipath-libs
dnf4-plugin-notify-PackageKit
dnf-data
double-conversion
dracut-config-generic
dracut-live
dracut-network
fuse
glibc-all-langpacks
glx-utils
google-noto-sans-mono-vf-fonts
google-noto-serif-vf-fonts
grub2-efi-x64-cdboot
gstreamer1-plugins-good-qt6
hunspell-en
ima-evm-utils-libs
iscsi-initiator-utils
iscsi-initiator-utils-iscsiuio
isns-utils-libs
jose
langpacks-core-en
langpacks-en
langpacks-fonts-en
langtable
libb2
libblockdev-btrfs
libblockdev-dm
libblockdev-lvm
libblockdev-mpath
libcomps
libdnf5-plugin-expired-pgp-keys
libdnf5-plugin-notify-PackageKit
libfsverity
libglvnd-opengl
libjose
libluksmeta
libnl3-cli
libreport
libreport-anaconda
libreport-cli
libreport-plugin-bugzilla
libreport-plugin-reportuploader
libreport-web
libteam
libxkbcommon-x11
livesys-scripts
lsof
luksmeta
minizip-ng-compat
NetworkManager-team
papers-nautilus
parted
pcre2-utf16
python3-blivet
python3-blockdev
python3-bytesize
python3-cffi
python3-charset-normalizer
python3-crypt-r
python3-dasbus
python3-dbus-next
python3-dnf
python3-hawkey
python3-idna
python3-iso639
python3-kickstart
python3-langtable
python3-libcomps
python3-libdnf
python3-libdnf5
python3-libmount
python3-libreport
python3-meh
python3-pid
python3-ply
python3-productmd
python3-pwquality
python3-pycparser
python3-pyparted
python3-pysocks
python3-requests
python3-requests-file
python3-requests-ftp
python3-rpm
python3-satyr
python3-simpleline
python3-systemd
python3-unbound
python3-urllib3
python3-urllib3+socks
python3-xkbregistry
qt6-filesystem
qt6-qtbase
qt6-qtbase-common
qt6-qtbase-gui
qt6-qtdeclarative
qt6-qtpdf
qt6-qtpositioning
qt6-qtserialport
qt6-qtsvg
qt6-qttranslations
qt6-qtwayland
qt6-qtwayland-adwaita-decoration
qt6-qtwebchannel
qt6-qtwebengine
qt6-qtwebview
re2
rpm-build-libs
rpm-plugin-systemd-inhibit
rpm-sign-libs
satyr
slitherer
sscg
teamd
tslib
udisks2-btrfs
udisks2-iscsi
udisks2-lvm2
xcb-util-cursor
xcb-util-image
xcb-util-keysyms
xcb-util-renderutil
xcb-util-wm
xdriinfo
xmlrpc-c
xmlrpc-c-client
zenity
```

This is largely expected lifecycle separation: the live root contains
Anaconda, LiveOS, live dracut, Cockpit, storage-discovery, report, and
installer GUI dependencies. It is not evidence that the installed desktop
lost the core desktop/tool packages listed above. The one installed-only
minimal language package reflects the installed target's language baseline.
