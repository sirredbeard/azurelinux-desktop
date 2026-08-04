# Plymouth boot animation

## Context

Plymouth provides the graphical boot splash (Azure Linux penguin logo + animated glowing-dot ring) across all three deliverables: live ISO, qcow2 disk image, and installer ISO. Each has a different initramfs build path and a different set of failure modes. The theme is `azurelinux`, using the `script` plugin.

## Known issues and root causes

### Serial console suppresses graphical splash (installed system, installer ISO)

**Status:** Resolved

Azure Linux inherits `console=ttyS0,115200 console=tty0` from its cloud origin.
Plymouth's device manager (`ply-device-manager.c`, `create_devices_from_terminals`)
reads `/sys/class/tty/console/active`. Any non-local console (for example `ttyS0`)
sets `has_serial_consoles = true`, forces the details/text path, and **returns
early** without DRM/udev setup. The graphical theme never loads, even when
`rhgb quiet` is present and the theme files are inside the initramfs.

```c
// ply-device-manager.c (create_devices_from_terminals)
has_serial_consoles = add_consoles_from_file(manager, "/sys/class/tty/console/active");
if (has_serial_consoles) {
    manager->serial_consoles_detected = true;
    // early return: no DRM/framebuffer watch
    return true;
}
```

**Installer ISO:** `kiwi/azl-desktop-installer.kiwi` previously had
`console=ttyS0,115200` and `inst.text`. Decision 2026-07-22: Option B
(graphical Plymouth), not `rd.plymouth=0`. Shipped cmdline:

```xml
kernelcmdline="console=tty0 rhgb quiet enforcing=0 audit=0 inst.lang=en_US.UTF-8 inst.nokill"
```

**Installed system:** Anaconda/`post-bootloader.sh` must not write
`console=ttyS0` into the normal BLS entry. Serial `agetty` does not need
`console=ttyS0` on the kernel cmdline. Confirmed fix: Azure Linux splash
(penguin + animated dots) visible at about 6 s in QEMU.

**Note:** `inst.text` alone does **not** suppress Plymouth. It only selects
Anaconda TUI. Reviewed in `rhinstaller/anaconda` `parse-anaconda-options.sh`.
The serial-console short-circuit is the real suppressor.

`plymouth.ignore-serial-consoles` is **not** a kernel parameter. The C flag is
set only via `plymouthd --ignore-serial-consoles`. Prefer removing serial from
the desktop cmdline over patching plymouth-pretrigger.

### Installer initramfs theme bundling (generic dracut)

KIWI ISO dracut often runs `--no-hostonly` (generic). In that mode
`50plymouth/plymouth-populate-initrd.sh` only bundles `text` and `details`
unless the custom theme is already on the build root when dracut runs. Runtime
squashfs `/etc/plymouth/plymouthd.conf` is **not** visible during initramfs
Plymouth. Stage theme files in `kiwi/config.sh` **before**
`plymouth-set-default-theme azurelinux`, then regenerate initramfs.

### qcow2 initramfs lacks theme assets (disk-image build path)

The live ISO boots `images/pxeboot/initrd.img` (Lorax post-`%post`). The qcow2
boots `/boot/initramfs-*` from the installed root. `plymouth-set-default-theme
azurelinux` alone is insufficient: bare `dracut -f` uses the build container's
`uname -r`, not the Azure kernel under `/usr/lib/modules`. Fix: after theme
selection, run `dracut --force --kver <kver>` for every directory under
`/usr/lib/modules`. Skipping this leaves `script.so` and theme assets out of
the boot initramfs even when they exist on the rootfs.

### Plymouth asset staging order in KIWI config.sh

`plymouth-set-default-theme azurelinux` fails with
`azurelinux.plymouth does not exist` if theme files are not already under
`/usr/share/plymouth/themes/azurelinux/`. Copy `.plymouth`, `.script`, logo
PNG, and dot PNGs first. Failure signature: `azurelinux.plymouth does not exist` from `config.sh`.

### KIWI boot initramfs path

Installer ISOs store the boot initramfs at `/boot/x86_64/loader/initrd`, not
Lorax's `/images/pxeboot/initrd.img`. Validators that use the Lorax path miss
the installer's initramfs. Log:
`/images/pxeboot/initrd.img` (Lorax) is wrong; use `/boot/x86_64/loader/initrd`.

### early-kms.conf missing or incomplete

`kiwi/config.sh` once wrote `50-azurelinux-plymouth.conf` but not
`early-kms.conf` (fixed `c661bdd`). Live-disk kickstart also lagged with only
`virtio_gpu`. All three kickstarts and `config.sh` must write:

```bash
add_drivers+=" virtio_gpu hyperv_drm bochs_drm "
```

- `virtio_gpu` — QEMU virtio-gpu
- `hyperv_drm` — Hyper-V Gen2
- `bochs_drm` — QEMU std VGA (module name uses underscores)

AZL `plymouthd.defaults` already sets `UseSimpledrmNoLuks=1` for EFI
simpledrm fallback when no discrete DRM driver binds.

### Plymouth logo oversized/cropped

**Status:** Resolved

Original `azurelinux.script` centered the logo at native pixel size with no
bounds check. On small EFI framebuffers the sprite went negative and cropped.

Fix in `assets/plymouth/azurelinux/azurelinux.script`:

- Load `azurelinuxlogo.png` as `logo.original_image`
- `ScaleLogoToFit()` caps the logo at 30% of screen width/height, never
  upscales, uses `Image.Scale` and `Math.Min`
- `Math.Int()` on all sprite coordinates (Plymouth math is floating point)
- `refresh_callback` re-centers every frame via `Plymouth.SetRefreshFunction`

API pattern from upstream `themes/script/script.script` progress-bar scaling.

### First-boot SELinux relabel vs missing Plymouth

An installed first boot may run `fixfiles` relabel after Anaconda. That can
be expected. If Plymouth is suppressed (serial console), the user sees raw
systemd/SELinux text and may need a reboot. Fix Plymouth activation first;
do not treat relabel alone as a theme packaging failure. On-disk checks often
already showed `Theme=azurelinux` and theme files inside the installed
initramfs while the splash still failed at runtime.

Stock `selinux-autorelabel` also calls `plymouth --quit` even when the
graphical splash is healthy, then prints fixfiles to the console. Covered by
`assets/bin/azl-first-boot-prepare` and a systemd drop-in — see
`first-boot-plymouth-relabel.md`.

### Pre-Plymouth firmware/GRUB text

BdsDxe / GRUB text-mode issues are separate from Plymouth theme packing. See
`uefi-bdsdxe-text-before-plymouth.md`.

### dracut livenet hook ordering bug

`parse-livenet.sh` called `get_url_handler` before sourcing its definition
(`get_url_handler: command not found` on live boot). Cosmetic only. Upstream
dracut-ng issue 1240. Fix: `scripts/patch-dracut-livenet-hook.sh` before Lorax
builds the boot initramfs.

### virtio-gpu KMS mode-switch flicker

Plymouth can briefly drop to console text before GDM during virtio-gpu KMS
handoff. Early KMS mitigates; does not fully eliminate.

### Animation duration

Short animated phase in QEMU is usually fast boot reaching the "done" state.
Open tracking: `plymouth-animation-duration.md`.

## Verification commands

```bash
lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'plymouth|azurelinux'
cat /etc/plymouth/plymouthd.conf
journalctl -b | grep -i plymouth
# Installer ISO initrd path:
# /boot/x86_64/loader/initrd
```

## What didn't work

- `plymouth-set-default-theme azurelinux --rebuild-initrd` alone: the
  `--rebuild-initrd` flag runs `dracut -f` against the build container's
  running kernel, not the Azure kernel in `/usr/lib/modules`. Released qcow2
  still lacked `script.so` and theme assets after that "fix."
- Using `Image.Text("*")` for the dot throbber: replaced with real PNGs
  (`dot.png`, `dot-glow.png`) and `Math.Sin`-driven pulse animation.
- Relying on `inst.text` removal alone to restore graphical Plymouth.
- Leaving `console=ttyS0` for "debug" on a desktop BLS entry without
  `plymouthd --ignore-serial-consoles`.
- Option A for installer (`rd.plymouth=0`): rejected; product wants live-style
  splash on installer boot.

## Current state

**Live ISO:** Lorax handles initramfs build post-`%post`; theme selection via `plymouth-set-default-theme azurelinux` (no `-R`) in chrooted `%post` is sufficient. Animated dots + logo confirmed working.

**qcow2:** `dracut --force --kver` for each kernel in `/usr/lib/modules`. `rhgb quiet` written to BLS entries. Boot splash confirmed at ~6 s in QEMU KVM.

**Installer ISO:** `console=tty0 rhgb quiet` in `.kiwi` cmdline. Theme assets staged before `plymouth-set-default-theme`. `early-kms.conf` written by `config.sh`. KIWI initramfs at `/boot/x86_64/loader/initrd` verified. Plymouth graphical splash confirmed in QEMU boot tests.

**Installed system (from installer ISO):** `post-bootloader.sh` does not inject `console=ttyS0` into normal boot BLS entry. GRUB uses `gfxterm`, `gfxpayload=keep`, `insmod efi_gop/efi_uga/all_video`, `terminal_input console`. Boot splash confirmed.

**AZL plymouthd.defaults:** Contains `UseSimpledrmNoLuks=1` which enables the simpledrm fallback path — covers cases where neither virtio_gpu, hyperv_drm, nor bochs_drm is available.

## Animation timing notes

- QEMU fast-boot: animated glowing-dots phase is brief before Plymouth transitions to the static "done" state once boot targets are reached. Not a bug.
- Real hardware: animation duration longer (slower physical boot). Verify on real hardware or deliberately slowed VM before concluding animation is too short.
- Screendump during Plymouth (QEMU): ~98% dark pixels + 1–2% bright (animated dots). Useful as a boot-progress check; too low-contrast for reliable content verification.
- Screendump after Wayland takeover: all-black (QEMU screendump captures legacy VGA framebuffer; Mutter takes over virtio-gpu DRM). Use Python VNC client capture for post-Plymouth GNOME session. See `qemu-gnome-interactive-testing.md`.

## Per-deliverable status

| Deliverable | Theme in initramfs | Serial console suppressed | early-kms.conf | Verified |
|---|---|---|---|---|
| Live ISO | ✅ (Lorax) | N/A (no BLS on live) | ✅ | ✅ QEMU boot |
| qcow2 | ✅ (dracut --force --kver) | ✅ (no ttyS0 in BLS) | ✅ | ✅ QEMU boot |
| Installer ISO runtime | ✅ (KIWI dracut, `/boot/x86_64/loader/initrd`) | ✅ (console=tty0 only) | ✅ (c661bdd) | ✅ QEMU boot |
| Installed system | ✅ (Anaconda regenerates) | ✅ (post-bootloader.sh) | ✅ | ✅ QEMU boot |

## References

Theme-not-staged and wrong initrd path signatures are inlined above.
- `uefi-bdsdxe-text-before-plymouth.md` — GRUB gfxterm / pre-Plymouth firmware text
- `plymouth-animation-duration.md` — open note on short QEMU animation
- `deliverable-polish-validation.md` - AQ runs that confirmed splash
- dracut-ng issue 1240 (livenet hook ordering)
- Plymouth `ply-device-manager.c` serial-console early return
- dracut `modules.d/50plymouth/plymouth-populate-initrd.sh` hostonly vs generic
- AZL `specs/p/plymouth/plymouth.spec` (`UseSimpledrmNoLuks=1`)
