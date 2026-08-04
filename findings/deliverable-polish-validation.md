# Deliverable polish validation and AQ notes

**Status:** Historical working set from the 2026-07-22 through 2026-07-25
polish batch. Per-issue detail now lives in individual `findings/*.md`
files. This file keeps the validation checklist, preflight closure, and AQ
session notes so they are not lost.

## Preflight closure (2026-07-22)

- `scripts/test-container-repos.sh` → pass
- `scripts/podman-test-azl4-fedora.sh` → pass (`azl4=643 fc43=513 total=1171`)
- `scripts/test-installer-runtime-resolve.sh` → pass (`426/426`)
- `scripts/test-canary-container-local.sh` → pass
- Evidence (preflight 2026-07-22): `test-container-repos` PASS; `podman-test-azl4-fedora` PASS azl4=643 fc43=513 total=1171; installer runtime resolve 426/426 Complete; canary local PASS after flatpak hardening; local kiwi bind-mount blocker expected.
- Workflow: `.github/workflows/release.yml (canary jobs; historical note)`

## Squash merge and nightly

- Branch `deliverable-polish-batch` squash-merged to `main` as `b085d15`
  (2026-07-24).
- Nightly run `29993641061` published installer ISO (~2.9 GB), live ISO
  (~2.75 GB), live qcow2 (~3.1 GB).

Post-nightly workflow fixes:

- `8333016`: `release.yml` (was nightly-release.yml) - disabled vmdk/vhdx/vdi download when
  those formats were not built.
- `ab4deca`: `release.yml` canary jobs - removed racing `prepare-kernel-modules`
  step that cancelled canary container builds.

## Fix tracker summary (all resolved in this batch)

Local / overlay-verifiable:

| Fix | Result | Detail file |
| --- | --- | --- |
| .NET launcher desktop validity | Pass | `dotnet-cli-first-run.md` |
| Admin default shell pwsh | Pass | `admin-default-shell-pwsh.md` |
| PowerShell D-Bus activation | Pass (cosmetic grouping remainder) | `powershell-dock-identity.md` |
| Repo policy preflight | Pass | `fedora-azl-repo-mixing.md`, `test-suite.md` |
| GRUB graphical console | Pass | `uefi-bdsdxe-text-before-plymouth.md` |
| Installed Plymouth serial console | Pass | `plymouth-boot-animation.md` |
| early-kms.conf VM drivers | Pass | `plymouth-boot-animation.md` |
| Plymouth logo scale | Pass | `plymouth-boot-animation.md` |

Full rebuild / runtime:

| Fix | Example runs | Detail file |
| --- | --- | --- |
| GRUB gfxterm installer + installed | `29973179297`, `29984008922`, `29987725267` | `uefi-bdsdxe-text-before-plymouth.md` |
| Installer Plymouth no ttyS0 | `29973179297` | `plymouth-boot-animation.md` |
| Installed Plymouth splash | `29973179297`, `29987725267` | `plymouth-boot-animation.md` |
| Asset `install -m 0644/0755` | `29984033898`, `29984008922` | `anaconda-kickstart-patterns.md` |
| Wallpaper staging live paths | `29990996437` | `gnome-desktop-defaults.md` |
| EFI vendor path copy | `29984033898` | `efi-vendor-path-azurelinux.md` |
| Flatpak live space squashfs-ext4 | nightly `b085d15` | `flatpak-live-session-space.md` |
| Installer storage TUI-only | current branch | `anaconda-kickstart-patterns.md` |

## Post-build filesystem checklist (condensed)

Download with `scripts/Get-AzureLinuxDesktop.ps1 -Live` / `-Install`.

Live ISO / qcow2 mount checks:

- Nested live layout: `LiveOS/squashfs.img` → `LiveOS/rootfs.img` (ext4)
  after the Flatpak fix.
- `grep ScaleLogoToFit` on
  `/usr/share/plymouth/themes/azurelinux/azurelinux.script`
- `azl-dotnet-terminal`, `azl-powershell-terminal`, desktop files mode 644
- D-Bus `org.azurelinux.PowerShell.service`
- dconf dark mode + wallpaper URIs; files under
  `/usr/share/backgrounds/azurelinux/`
- `early-kms.conf` contains `virtio_gpu hyperv_drm bochs_drm`

Installer ISO:

- GRUB: `gfxterm`, `gfxpayload=keep`, no `console=ttyS0`
- Kickstart: bare `bootloader`, no `clearpart`/`autopart`, `install -m`
  asset staging
- `post-bootloader.sh`: no serial console on normal BLS; gfxterm; EFI
  fedora→azurelinux copy

Installed target after QEMU install:

- BLS without `console=ttyS0`
- Plymouth theme in initramfs
- Admin shell `/usr/bin/pwsh`
- Five dock favorites readable by the user

## AQ testing: 2026-07-24 release (commit `c661bdd`)

Artifacts downloaded via `Get-AzureLinuxDesktop.ps1`, checksum-verified.

Validator bug fixed in `c661bdd`: scripts were inspecting the outer
squashfs (only `LiveOS/rootfs.img`) instead of the mounted inner rootfs.
Both live and installer use the two-layer layout.

`early-kms.conf` was missing from installer runtime (`kiwi/config.sh`
wrote Plymouth conf only). Fixed in `c661bdd`.

Live ISO and qcow2 QEMU boots: GNOME autologin, dark wallpaper
approx avg RGB (12,30,70) matching `adwaita-d.jpg`. QEMU monitor
`screendump` goes black after Wayland takes virtio-gpu; use a VNC client
capture instead (`qemu-gnome-interactive-testing.md`).

## AQ testing: 2026-07-24b (runs `30118396215` / `29990996437`)

Validators fixed; installer ISO QEMU boot exercised. See workflow artifacts
and per-issue files for itemized pass/fail.

Static verification highlights:

- Run `29984008922`: asset modes, no clearpart/autopart, bare bootloader,
  no ttyS0, Plymouth theme azurelinux. Caught installed GRUB still on
  `terminal_output console serial` → fixed in `b49ee12`, rebuild
  `29987725267`.
- Wallpaper staging gap on live kickstarts found on run `29988830449`,
  fixed in `8eb3e17`, confirmed on `29990996437`.

## Manual QA: 2026-07-25 nightly (run `30181902965`)

Live ISO in QEMU GTK via `scripts/qemu-test-live-iso.sh`.

| Check | Result |
|---|---|
| EFI/GRUB boot | Pass (brief BdsDxe under QEMU OVMF only) |
| Plymouth splash | Pass (short animation in QEMU; see open note) |
| GNOME autologin | Pass |
| Wallpaper | Pass |
| .NET, Edit, GitHub Desktop, Copilot GUI, gh | Pass |
| Flatpak install | Pass |
| PowerShell dock grouping | Known cosmetic remainder |

No new regressions. Release treated as shippable for this batch.

## Open items carried out of this batch

- `plymouth-animation-duration.md` - short animation in fast VMs
- PowerShell dock grouping cosmetic note under `powershell-dock-identity.md`
- Cockpit / selinux-policy dnf story: see final resolution in
  `fedora-azl-repo-mixing.md` (later correction removed the bad cockpit pin)

## References

- Individual issue files listed in `findings/README.md`
Wallpaper match (2026-07-22): winner `adwaita-d`, corr_mean≈0.048 vs light negative; still generic dark Adwaita that iteration.
Boot OCR: t8/t20/t40 = 0 chars; t80 only desktop UI text ("Type to search").
- `qemu-gnome-interactive-testing.md`
