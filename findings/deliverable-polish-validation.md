# Deliverable polish validation notes

**Status:** Historical working set from the 2026-07 polish batch.
Per-issue detail lives in individual `findings/*.md` files. This file
keeps the validation checklist and AQ session notes so they are not
lost.

## Preflight closure

Scripts that passed in that batch:

- `scripts/test-container-repos.sh`
- `scripts/podman-test-azl4-fedora.sh`
- `scripts/test-installer-runtime-resolve.sh`
- `scripts/test-canary-container-local.sh`

Local kiwi bind-mount blocker expected. Canary and package-policy checks
now live under `release.yml` and `scripts/`.

## Squash merge and nightly

Branch `deliverable-polish-batch` squash-merged to `main`. Nightly
published installer ISO, live ISO, and live qcow2.

Post-nightly workflow fixes of note:

- Download script stopped asking for VMDK/VHDX/VDI when those formats
  were not built.
- Canary no longer raced a separate `prepare-kernel-modules` step that
  cancelled container builds.

## Fix tracker summary (resolved in that batch)

Local / overlay-verifiable:

- .NET launcher desktop validity: `dotnet-cli-first-run.md`
- Admin default shell pwsh: `admin-default-shell-pwsh.md`
- PowerShell D-Bus activation: `powershell-dock-identity.md`
  (cosmetic grouping remainder)
- Repo policy preflight: `fedora-azl-repo-mixing.md`, `test-suite.md`
- GRUB graphical console: `uefi-bdsdxe-text-before-plymouth.md`
- Installed Plymouth serial console, early-kms.conf, logo scale:
  `plymouth-boot-animation.md`

Full rebuild / runtime:

- GRUB gfxterm installer + installed: `uefi-bdsdxe-text-before-plymouth.md`
- Installer and installed Plymouth: `plymouth-boot-animation.md`
- Asset `install -m 0644/0755`: `anaconda-kickstart-patterns.md`
- Wallpaper staging live paths: `gnome-desktop-defaults.md`
- EFI vendor path copy: `efi-vendor-path-azurelinux.md`
- Flatpak live space squashfs-ext4: `flatpak-live-session-space.md`
- Installer storage TUI-only: `anaconda-kickstart-patterns.md`

## Post-build filesystem checklist

Download with `scripts/Get-AzureLinuxDesktop.ps1 -Live` / `-Install`.

Live ISO / qcow2 mount checks:

- Nested live layout: `LiveOS/squashfs.img` to `LiveOS/rootfs.img`
  (ext4) after the Flatpak fix
- `grep ScaleLogoToFit` on
  `/usr/share/plymouth/themes/azurelinux/azurelinux.script`
- `azl-dotnet-terminal`, `azl-powershell-terminal`, desktop files mode
  644
- D-Bus `org.azurelinux.PowerShell.service`
- dconf dark mode + wallpaper URIs; files under
  `/usr/share/backgrounds/azurelinux/`
- `early-kms.conf` contains `virtio_gpu hyperv_drm bochs_drm`

Installer ISO:

- GRUB: `gfxterm`, `gfxpayload=keep`, no `console=ttyS0`
- Kickstart: bare `bootloader`, no `clearpart`/`autopart`, `install -m`
  asset staging
- `post-bootloader.sh`: no serial console on normal BLS; gfxterm; EFI
  fedora to azurelinux copy

Installed target after QEMU install:

- BLS without `console=ttyS0`
- Plymouth theme in initramfs
- Admin shell `/usr/bin/pwsh`
- Five dock favorites readable by the user

## AQ notes (condensed)

Validator bug: scripts were inspecting the outer squashfs (only
`LiveOS/rootfs.img`) instead of the mounted inner rootfs. Both live and
installer use the two-layer layout.

`early-kms.conf` was missing from installer runtime (`kiwi/config.sh`
wrote Plymouth conf only). Fixed.

Live ISO and qcow2 QEMU boots: GNOME autologin, dark wallpaper matching
`adwaita-d.jpg`. QEMU monitor `screendump` goes black after Wayland
takes virtio-gpu; use a VNC client capture instead
(`qemu-gnome-interactive-testing.md`).

Static verification highlights:

- Asset modes, no clearpart/autopart, bare bootloader, no ttyS0,
  Plymouth theme azurelinux
- Caught installed GRUB still on `terminal_output console serial`; fixed
- Wallpaper staging gap on live kickstarts; fixed

Manual QA on nightly: EFI/GRUB boot, Plymouth splash, GNOME autologin,
wallpaper, .NET/Edit/GitHub Desktop/Copilot GUI/gh, Flatpak install.
PowerShell dock grouping remains a known cosmetic remainder.

## Open items carried out of this batch

- `plymouth-animation-duration.md`: short animation in fast VMs
- PowerShell dock grouping under `powershell-dock-identity.md`
- Cockpit / selinux-policy dnf story: final resolution in
  `fedora-azl-repo-mixing.md`

## References

- Individual issue files under `findings/*.md`
- `qemu-gnome-interactive-testing.md`
