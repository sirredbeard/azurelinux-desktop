# Live ISO / installer / installed / canary parity

**Status:** active parity checklist

## Context

Four deliverables share package policy and custom tooling but have
different boot and install lifecycles:

- Live ISO (squashfs + livesys)
- qcow2 disk image (installed, persistent)
- Installer ISO (KIWI runtime + offline repo + Anaconda TUI)
- Canary container (repo/policy canary, not a desktop)

## Asset staging parity

- GDM login logo: live kickstart stages `azurelinux-gdm-logo.png` and
  sets the GDM dconf logo override, matching the installer path. Live
  autologin still hides the greeter most of the time.
- BT / PipeWire / udev on installed target: `kiwi/azl-install.ks.in`
  `%post --nochroot` installs recover units, PipeWire user preset, and
  BT udev rules into `/mnt/sysroot`. `kiwi/config.sh` stages the same
  into the installer ISO rootfs for the live installer environment.

Use `install -m 0644` / `install -m 0755` for assets in all kickstart
paths (not `cp -v`). Build umask 077 otherwise leaves mode 600 files
GNOME cannot read.

## What must stay in sync

Across live, qcow2, and installed target where lifecycle allows:

- Azure kernel + project desktop kmods / Pages repo / policy RPM
- GNOME/GTK stack, dark mode + wallpaper dconf, dock favorites
- Custom launchers and desktop files
- Edge Canary, GitHub tools, Flatpak + Flathub
- Microsoft Copilot GTK Flatpak + signed Pages remote
- Plymouth `azurelinux` theme + early-kms.conf
- Microsoft/GitHub/RPMFusion repos persisted with FEDORA_EXCLUDES
- Polkit DNF5 rule, PAM keyring where GDM applies
- Copilot CLI + Edit side-loads

Canary: same repo/priority/side-load/policy checks. No full GNOME/GDM
desktop stack.

## Intentional differences

### Live ISO vs qcow2

- Live boots with `rd.live.image`; livesys services run. qcow2 does not.
- Live: `liveuser` from livesys-scripts at first boot. qcow2: pre-created
  at build time.
- Live root is read-only squashfs + writable layer. qcow2 grows root on
  first boot via `azl-growroot.service`.
- Disk path may carry extra boot tooling not needed on pure live media.

### Installed target from installer ISO

Installed target is smaller than live/qcow2 on purpose:

- Absent: Anaconda and deps, livesys-scripts, live-dracut bits, some
  block provisioning tools, full langpacks, etc.
- Present only on installed target: persistent LVM/EFI layout choices,
  installer-created admin account with `pwsh` as default shell.
- Installer runtime itself is Anaconda + offline repo, not a desktop
  session.

### EFI vendor path

Kickstart excludes Azure Linux shim/grub. Fedora Secure Boot-signed
RPMs install to `EFI/fedora/`, but Anaconda NVRAM points at
`EFI/azurelinux/shimx64.efi`. `kiwi/post-bootloader.sh` copies Fedora
EFI binaries to `EFI/azurelinux/` when absent. Do not reintroduce Azure
Linux unsigned shim/grub just to avoid the copy.

### Azure kernel desktop input gaps

AZL x86_64 config leaves `CONFIG_USB_HID` and `CONFIG_INPUT_MOUSE` off.
No stock `usbhid.ko` or `psmouse.ko`. Virtio input is modular. Product
fix is OOT kmods on the Pages repo (usbhid, psmouse, and related). See
`azure-kernel-usbhid-kmod.md`, `hypervisor-mouse-ps2-boxes.md`.

### Flatpak

- `flatpak-selinux` from Fedora is compatible with the AZL policy base
  in practice. Keep Fedora Flatpak boundary explicit; no AZL-native
  Flatpak packaging in public repos.
- Live free space: see `flatpak-live-session-space.md`
  (`--rootfs-type squashfs-ext4`).

### os-prober on disk builds

Anaconda on a privileged runner can scan host disks and add foreign GRUB
entries. Disable os-prober in the disk-image workflow and brand BLS
entries as Azure Linux Desktop.

### Installed GRUB must use gfxterm

`kiwi/post-bootloader.sh` writes installed `/boot/grub2/grub.cfg` with
efi_gop/efi_uga/all_video, `gfxmode=auto`, `gfxpayload=keep`,
`terminal_output gfxterm`. Do not use `terminal_output console serial`.
Also stage modules under `/boot/grub2/x86_64-efi/`. See
`installed-grub-missing-efi-modules.md`.

### Root partition growth

qcow2 is resized after install; kickstart partition size is smaller.
`azl-growroot.service` runs once with growpart + filesystem grow.
Device-name agnostic. Disk-image variant only.

### Disk image format conversions

- qcow2 is canonical from livemedia-creator
- VHDX/VDI/VMDK convert from the already-resized qcow2 only
- Convert jobs are independent; they do not re-run Anaconda

## Verification approach

1. Static filesystem check first (two-layer live/installer layout).
2. Runtime check second (QEMU boot, autologin, dock, wallpaper,
   Plymouth, apps).
3. Installed target: real install + reboot without ISO.
4. Validators: `scripts/validate-live-iso-filesystem.sh`,
   `scripts/validate-live-qcow2.sh`, `scripts/validate-installer-iso.sh`.

Both ISOs use: `LiveOS/squashfs.img` (outer) → `LiveOS/rootfs.img`
(inner ext4). Validators must mount both layers.

## What did not work

- `qemu-nbd` + `unsquashfs` for files inside ext4 rootfs.img (use
  loop-mount or debugfs)
- Converting VHDX/VDI/VMDK from the pre-resize raw image
- Treating canary as a full desktop test suite

## Related

- `azure-kernel-usbhid-kmod.md`
- `anaconda-kickstart-patterns.md`
- `gnome-desktop-defaults.md`
- `fedora-azl-repo-mixing.md`
- `deliverable-polish-validation.md`
- `flatpak-live-session-space.md`
- `github-actions-build.md`
