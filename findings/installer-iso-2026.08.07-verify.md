# Installer ISO / release 2026.08.07 verify

## Status

**Downloader + checksums: PASS** (`Get-AzureLinuxDesktop.ps1` on tag `2026.08.07`).  
**Mount feature parity (live ISO + installer runtime + live qcow): PASS 104 / FAIL 0.**  
**Live qcow behavioral (GDM/GNOME, dark theme, kmods, Copilot, BBR, Plymouth strings): PASS.**  
**Installer `reqpart` + first-boot Plymouth text + post-bootloader GRUB harden: present on published installer ISO.**  
**Boxes Standard Partition ESP:** product fix is in this rebuild (`reqpart`); retest on this ISO.

## Artifacts

Downloaded with project script into `~/azl-work/2026.08.07-fresh/` (sha256 OK):

- `azurelinux-desktop-live.iso`
- `azurelinux-desktop-install.iso`
- `azurelinux-desktop-live.qcow2`

Note: `-Install` cannot combine with `-Kvm` in one invocation; run Live, Install, and Kvm as separate calls.

Installer also copied to:

- `~/Downloads/azurelinux-desktop-install-2026.08.07.iso`

Older local ISOs/qcow under `~/azl-work` and prior Downloads copies were deleted before download.

Tree commit behind this rebuild: **b43c09c** (squash of reqpart, Plymouth message, GRUB recordfail harden, verifier extras).

## Mount verify

```text
./scripts/verify-release-features.sh \
  --live-iso .../azurelinux-desktop-live.iso \
  --live-qcow .../azurelinux-desktop-live.qcow2 \
  --installer-iso .../azurelinux-desktop-install.iso
==== totals: PASS=104 FAIL=0 SKIP=1 ====
# SKIP = installed-qcow not provided this pass
```

Log: `~/azl-work/feature-verify-2026.08.07-fresh2/`.

Covered on live ISO and live qcow: performance sysctl/modules (BBR), journald, BFQ udev, all desktop kmod RPMs, dconf dark + backgrounds, emoji fonts, intel-media-driver + mediasdk + iHD link + LIBVA path, Plymouth azurelinux theme, Flathub appstream preseed, Copilot flatpak + gpg-verify remote, growroot unit/helper, GPG key, wheel sudoers, gnome-themes-extra.

Installer runtime: staged assets (dconf dark, growroot, iHD helper, LIBVA, polkit), offline repo with kmods + media + emoji, product ks stages `/root/assets`.

### Installer kickstart on ISO root

`/root/azl-install.ks` on installer rootfs:

```text
bootloader
# Platform-required partitions only ...
reqpart
```

No `clearpart` / `autopart`. Matches `kiwi/azl-install.ks.in` for Standard Partition ESP scheduling.

### First-boot Plymouth message

On live roots and installer staged assets:

```text
Finishing setup. System will reboot.
```

In `azl-growroot` and `azl-first-boot-prepare`. No "expanding disk" wording.

### GRUB (installed-system path)

Installer `post-bootloader.sh` on ISO includes:

- `GRUB_TIMEOUT=0` / `GRUB_TIMEOUT_STYLE=hidden`
- `GRUB_RECORDFAIL_TIMEOUT=0`
- `unset recordfail` in generated cfg
- `terminal_output gfxterm`
- `GRUB_DISABLE_OS_PROBER=true`

Live ISO bootloader uses hidden timeout (ISO `grub.cfg` `timeout_style=hidden`).

## Behavioral live qcow (headless QEMU)

Stock live image has **`sshd` disabled** by kickstart (`services --disabled=sshd`). For this pass only, overlay was patched to enable sshd + liveuser auth. Product image itself is unchanged.

Observed over SSH as `liveuser` after GDM up:

- Kernel `6.18.31-1.12.azl4.x86_64`; Azure Linux 4.0 Four Beta
- `gdm`, `NetworkManager` **active**; `gnome-shell` running
- Only failed unit seen: `systemd-networkd-wait-online` (QEMU/user-net noise; NM is the desktop path)
- `gsettings` color-scheme **prefer-dark**, gtk-theme **Adwaita-dark**
- dconf system defaults: prefer-dark + Adwaita light/dark wallpapers
- `tcp_congestion_control=bbr`, `default_qdisc=fq`, `swappiness=10`; `tcp_bbr` + `sch_fq` loaded
- All eight desktop kmod RPMs installed (performance, bluetooth, storage, intel, surface, sensors, psmouse, sound)
- intel-media-driver, intel-mediasdk, gnome-themes-extra; `iHD_drv_video.so` present; LIBVA dri-nonfree path
- Copilot Flatpak **0.1.17**; CLI **1.0.78**
- Plymouth first-boot strings as above; `azl-growroot.service` **enabled**
- Flatpak appstream dirs for flathub + copilot; RPM GPG key present
- Repos: azurelinux, microsoft, azl-desktop-kmods, fedora, rpmfusion, microsoft-github

## Canary

Focused rebuild `31172523807` ran with **canary=false** (manual product flags only). Local GHCR pull of canary was not re-verified this pass (403 / no fresh canary job). Canary remains a repo/tool canary, not a full GNOME stack. Treat next schedule or `canary=true` run as the container parity gate.

## Earlier clean-room install (pre-rebuild ISO)

Stock install before `reqpart` rebuild:

- LVM path completed; installed mount + SSH behavioral PASS (dark theme, kmods, Copilot 0.1.17, BBR, growroot.done, SELinux relabel once).
- Boxes **Standard Partition + use all free space** failed without ESP (`STORAGE_MUST_NOT_BE_ON_ROOT`). Fix is bare `reqpart` on **this** installer ISO — manual Boxes retest with `~/Downloads/azurelinux-desktop-install-2026.08.07.iso`.

## Growroot vs bare metal (unchanged)

Growroot is for resized prebuilt disk images. Full-disk installer installs usually only hit SELinux `/.autorelabel` + one first-boot reboot. Message is generic on purpose.

## Ops notes

- Host sudo: fedora/fedora. Guest admin on installed: azurelinux/azurelinux. Live disk user: liveuser (pwsh default shell → `bash -lc`).
- Stale NBD mounts from prior verify break live-qcow remount; umount verify paths and `qemu-nbd -d` before re-run. Do not loop on `findmnt | grep nbd` using SOURCE lines without unmounting TARGET paths.
- Prefer `replace_release=true` on full product rebuilds when dogfooding `Get-AzureLinuxDesktop.ps1` against a fresh dated release.

## Open

1. Manual Boxes: Standard Partition + use all free space on **this** installer ISO (expect ESP via `reqpart`).
2. Optional installed-qcow mount pass after a fresh install from this ISO.
3. Canary GHCR after next schedule/`canary=true`.
4. Optional: quiet `systemd-networkd-wait-online` on desktop if degraded status is confusing.
