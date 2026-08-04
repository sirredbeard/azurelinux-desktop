# Kickstart

## `azurelinux-desktop-live.ks`

Source of truth for the **live ISO** and the **disk-image** builds.

- Live ISO: `livemedia-creator --make-iso` with this file as-is
  (`.github/workflows/build-live-iso.yml (via release.yml)`).
- Disk images (qcow2, then VHDX/VDI/VMDK): the same workflow (and
  `scripts/build-qcow2-local.sh`) generates a temporary
  `azurelinux-desktop-live-disk.ks` with `sed` + a short extra `%post`:
  - `bootloader --location=none` → `bootloader`
  - `part / --size=16384` → `part / --fstype=xfs --size=16384 --grow`
  - `# AZL_GROWROOT_ENABLE_MARKER` → `systemctl enable azl-growroot.service`
  - append liveuser + dconf defaults (disk roots are not live media)

Do **not** commit `azurelinux-desktop-live-disk.ks`. It is a build product.

## Installer

Bare-metal installer media is not kickstart-driven from this directory.
See `kiwi/` and `findings/kiwi-ng-installer-build.md`.
