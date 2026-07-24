# Live ISO final-polish issues

Resolved issues are moved to `findings/final_polish_finished.md` after
filesystem + runtime/manual confirmation. This file keeps only active work,
brief summaries, and references to the finished archive.

## Fix execution tracker — deliverable-polish-batch (2026-07-22 through 2026-07-24)

All issues from this iteration are confirmed resolved. The full fix tracker
table, post-build validation guide, Plymouth root cause research, GNOME
identity research, Flatpak space research, wallpaper research, shell/dotnet
remediation research, installer interactive testing, static filesystem
verifications, and squash merge details are all in
`findings/final_polish_finished.md`.

**Preflight closure (2026-07-22):**
- `scripts/test-container-repos.sh` → pass
- `scripts/podman-test-azl4-fedora.sh` → pass (`azl4=643 fc43=513 total=1171`)
- `scripts/test-installer-runtime-resolve.sh` → pass (`426/426`, complete)
- `scripts/test-hybrid-container-local.sh` → pass
- Evidence: `findings/logs/preflight-iteration-2026-07-22.log`
- Preflight workflow: `.github/workflows/preflight-non-gui.yml`

**Squash merge:** `deliverable-polish-batch` → `main` as commit `b085d15`
(2026-07-24). Nightly release run `29993641061` published all three artifacts
(installer ISO 2.9 GB, live ISO 2.75 GB, live qcow2 3.1 GB).

**Workflow fixes applied post-nightly:**
- `8333016`: `nightly-release.yml` — disabled vmdk/vhdx/vdi (never built;
  release jobs were failing trying to download absent artifacts)
- `ab4deca`: `build-container.yml` — removed `prepare-kernel-modules` (was
  racing with live ISO kmod publish for the concurrency group, causing
  hybrid container builds to be cancelled)

### (a) Local container/overlay-verifiable fixes — all ✅ Pass

| Fix | Result | Archive reference |
| --- | --- | --- |
| `.NET` launcher desktop entry validity | ✅ `desktop-file-validate` passes; `.NET` confirmed in GNOME search | `final_polish_finished.md § Issue 2 — .NET CLI first-run error` |
| Installer-created admin default shell | ✅ `--shell=/usr/bin/pwsh` in generated kickstart directive | `final_polish_finished.md § Shell Default and .NET First-Run Remediation` |
| PowerShell D-Bus activation hardening | ✅ `shellcheck` pass; QEMU: window title = "PowerShell" | `final_polish_finished.md § Issue: PowerShell dock identity` |
| Repo policy / package-set integrity | ✅ all four preflight scripts pass | `final_polish_finished.md § Fix tracker (a) and preflight closure` |
| GRUB graphical console (Issue 1) | ✅ static filesystem verification confirmed | `final_polish_finished.md § Issue 1 — UEFI Firmware Text (BdsDxe)` |
| Installed-system Plymouth serial console (Issue 3a) | ✅ Azure Linux boot splash confirmed in QEMU | `final_polish_finished.md § Issue 3 — No Plymouth on First Boot` |
| early-kms.conf VM coverage (Issue 3b) | ✅ all kickstarts + `kiwi/config.sh` updated | `final_polish_finished.md § Issue 3 — No Plymouth on First Boot` |
| Plymouth logo proportional scale (Issue 4) | ✅ `ScaleLogoToFit` in filesystem; logo centered in QEMU boot | `final_polish_finished.md § Issue 4 — Plymouth Logo Oversized/Cropped` |

### (b) Full rebuild/runtime-verified fixes — all ✅ verified in artifact

| Fix | Build run | Status | Archive reference |
| --- | --- | --- | --- |
| GRUB gfxterm — installer ISO + installed system | `29973179297`, `29984008922`, `29987725267` | ✅ static verified | `final_polish_finished.md § Issue 1` |
| Plymouth — no serial console on installer boot | `29973179297` | ✅ graphical Plymouth confirmed | `final_polish_finished.md § Issue 2` |
| Plymouth — no serial console on installed system | `29973179297`, `29987725267` | ✅ boot splash confirmed | `final_polish_finished.md § Issue 3a` |
| early-kms.conf — all three drivers in kickstarts | `29973179297` | ✅ | `final_polish_finished.md § Issue 3b` |
| Plymouth logo proportional scale | `29973195111` | ✅ visual QEMU confirmation | `final_polish_finished.md § Issue 4` |
| Asset permissions — `install -m 0644/0755` | `29984033898`, `29984008922` | ✅ dock icons in installed desktop | `final_polish_finished.md § Installer interactive testing (2026-07-23)` |
| Installed GRUB gfxterm (`post-bootloader.sh`) | `29987725267` | ✅ static verified | `final_polish_finished.md § Static filesystem verification (run 29987725267)` |
| Wallpaper staging to live ISO / live-disk | `29990996437` | ✅ static verified; QEMU dark wallpaper confirmed | `final_polish_finished.md § Wallpaper staging bug (2026-07-24)` |
| EFI boot path mismatch (`post-bootloader.sh`) | `29984033898` | ✅ applied | `final_polish_finished.md § Installer interactive testing (2026-07-23)` |
| Flatpak live-session space (`squashfs-ext4`) | `b085d15` nightly | ✅ DM-snapshot mode; ~4 GiB apparent free | `final_polish_finished.md § Issue: Flatpak live-session space` |
| Installer storage — removed `clearpart`/`autopart` | current branch | ✅ confirmed in filesystem | `final_polish_finished.md § Installer interactive testing (2026-07-23)` |
| Wallpaper (adwaita-l/d JPEG staged) | `28dd697`, `8eb3e17` | ✅ QEMU boot confirmed avg=(12,30,70) blue/dark | `final_polish_finished.md § Wallpaper staging bug (2026-07-24)` |

### Resolved issue summaries

**Issue 1 — GRUB BdsDxe text before Plymouth:** `kiwi/grub_template.cfg`
and `kiwi/post-bootloader.sh` both updated to use `insmod efi_gop/efi_uga/all_video`,
`gfxpayload=keep`, `terminal_output gfxterm`, `clear`. Serial kept as input
only. Confirmed in static filesystem verification and QEMU boot. Full root
cause and GRUB config in `final_polish_finished.md § Issue 1`.

**Issue 2 — No Plymouth during installer boot:** Selected Option B (graphical
Plymouth). Removed `console=ttyS0,115200` and `inst.text` from
`kiwi/azl-desktop-installer.kiwi` cmdline; uses `console=tty0 rhgb quiet`.
Full root cause (Plymouth serial-console detection in `ply-device-manager.c`,
dracut generic-mode initramfs theme bundling) and remediation options in
`final_polish_finished.md § Issue 2 — No Plymouth During Installer ISO Boot`.

**Issue 3a — No Plymouth on installed system:** `kiwi/post-bootloader.sh` no
longer injects `console=ttyS0,115200` into the normal boot BLS entry. Azure
Linux boot splash (penguin + animated dots) confirmed at ~6s in QEMU. Full
serial-console short-circuit analysis in `final_polish_finished.md § Issue 3`.

**Issue 3b — early-kms.conf VM coverage:** `hyperv_drm bochs_drm` added
alongside `virtio_gpu` in all three kickstarts and `kiwi/config.sh`. Covers
Hyper-V Gen2 and QEMU std VGA; simpledrm fallback via `UseSimpledrmNoLuks=1`
in AZL's `plymouthd.defaults`. Full details in
`final_polish_finished.md § Issue 3`.

**Issue 4 — Plymouth logo oversized:** `ScaleLogoToFit()` bounding logo to
30% of screen added to `assets/plymouth/azurelinux/azurelinux.script`.
`Math.Int()` on all coordinates; logo re-centered each frame in
`refresh_callback`. Confirmed in filesystem and QEMU boot screenshot. Full
script in `final_polish_finished.md § Issue 4`.

**PowerShell dock identity:** D-Bus session service file
`assets/dbus/org.azurelinux.PowerShell.service` added; `azl-powershell-terminal`
simplified to rely on D-Bus activation for `org.azurelinux.PowerShell`.
Window title "PowerShell" confirmed in QEMU. Full GNOME shell tracker and
Wayland app_id research in `final_polish_finished.md § Issue: PowerShell dock
identity`.

**Flatpak live-session space:** Root cause: `--live-rootfs-size 8` was
silently ignored for `--make-iso`; lorax pure-squashfs OverlayFS mode put the
upper layer in tmpfs (~783 MiB at 4 GB RAM). Fix: switched to
`--rootfs-type squashfs-ext4`; dracut uses DM-snapshot and `statvfs` reports
ext4 virtual size (~4 GiB free). Full research (options A through F) in
`final_polish_finished.md § Issue: Flatpak live-session space`.

**Asset file permissions:** `cp -v` in kickstart `%post` preserved mode 600
from umask 077 in the Fedora 43 build container, causing GNOME Shell to
silently skip `.desktop` files it couldn't read as the user. Replaced all
`cp -v` with `install -m 0644` (data files) and `install -m 0755`
(executables) across all three kickstarts. Full root cause in
`final_polish_finished.md § Installer interactive testing (2026-07-23)`.

**Wallpaper:** `adwaita-l.jpg` / `adwaita-d.jpg` staged to
`/usr/share/backgrounds/azurelinux/` in all targets; dconf `picture-uri`
references corrected. Staging was initially missing from live ISO and
live-disk kickstarts (fixed in commit `8eb3e17`). QEMU boot confirmed deep
blue/dark wallpaper (avg=(12,30,70)). Full details in
`final_polish_finished.md § Wallpaper staging bug found and fixed (2026-07-24)`.

**Admin default shell:** `kiwi/anaconda-launcher.sh` now injects
`--shell=/usr/bin/pwsh` in the generated `user` kickstart directive. Full
pykickstart syntax verification, PAM/`/etc/shells` analysis, and GNOME/GDM
session behavior analysis in
`final_polish_finished.md § Shell Default and .NET First-Run Remediation`.

**EFI boot path:** `kiwi/post-bootloader.sh` copies `shimx64.efi`,
`shim.efi`, `grubx64.efi`, `mmx64.efi` from `EFI/fedora/` → `EFI/azurelinux/`
when Fedora RPMs install there but the NVRAM entry expects
`EFI/azurelinux/shimx64.efi`. Full details in
`final_polish_finished.md § Installer interactive testing (2026-07-23)`.

**Installer storage / bootloader:** Removed `clearpart --all --initlabel` and
`autopart --type=lvm`; changed `bootloader --location=mbr` to bare
`bootloader`. Anaconda TUI handles disk selection, partitioning, and optional
LUKS encryption. Full details in
`final_polish_finished.md § Installer interactive testing (2026-07-23)`.

---

## Active work items

No open items. All deliverable-polish-batch issues resolved and verified.

### ~~early-kms.conf missing from installer runtime~~ — RESOLVED

- **Status:** Fixed in `c661bdd`, **verified in build run `30118396215`** (2026-07-24).
- `validate-installer-iso.sh` confirms `early-kms.conf` with `virtio_gpu hyperv_drm bochs_drm`
  present in installer runtime squashfs. 10/10 checks pass.

---

## AQ testing: 2026-07-24 release (commit c661bdd)

All three release artifacts (installer ISO 2.9 GB, live ISO 2.75 GB, live
qcow2 3.1 GB) were downloaded via `Get-AzureLinuxDesktop.ps1`, reassembled
from split parts, and verified against published SHA-256 checksums.

### Static validation findings

**Both live ISO and installer ISO use a two-layer squashfs structure:**
`LiveOS/squashfs.img` → `LiveOS/rootfs.img` (ext4). The three validator
scripts were checking the outer squashfs layer (which contains only
`LiveOS/rootfs.img`) instead of the mounted inner rootfs. All three
validators have been fixed in commit `c661bdd`.

**early-kms.conf missing from installer runtime:** `kiwi/config.sh` was
writing the Plymouth conf (`50-azurelinux-plymouth.conf`) but not
`early-kms.conf`. The installer runtime (Anaconda environment) therefore
lacked the `virtio_gpu hyperv_drm bochs_drm` dracut module additions.
Fixed in `c661bdd`.

**Files confirmed in live ISO rootfs.img (mounted):**
- Plymouth azurelinux theme with ScaleLogoToFit ✅
- early-kms.conf with virtio_gpu hyperv_drm bochs_drm ✅
- All desktop files (mode 644): dotnet, PowerShell.desktop, edit, copilot ✅
- Custom launchers: azl-powershell-terminal, azl-dotnet-terminal, azl-copilot ✅
- D-Bus PowerShell activation service ✅
- dconf 00-dark-mode (color-scheme, picture-uri, picture-uri-dark) ✅
- Wallpapers at /usr/share/backgrounds/azurelinux/adwaita-{d,l}.jpg ✅
- Icons: edit.svg, powershell.png, dotnet.svg ✅
- livesys-gnome favorites patch: 5 correct apps ✅
- 1,175 packages total ✅

**Files confirmed in qcow2 XFS root (mounted):**
- Plymouth azurelinux theme with ScaleLogoToFit ✅
- early-kms.conf ✅
- All desktop files (mode 644) ✅
- D-Bus service, launchers ✅
- dconf: 00-dark-mode + 01-azl-desktop-favorites ✅
- Wallpapers ✅, EFI/azurelinux/shimx64.efi ✅
- 1,175 packages total ✅

**Installer ISO squashfs (Anaconda runtime, 427 packages):**
- GRUB: gfxterm, gfxpayload=keep, efi_gop, no ttyS0, rhgb ✅
- Plymouth azurelinux theme ✅
- anaconda-launcher.sh ✅
- early-kms.conf: MISSING in this artifact (pre-fix build) — fixed for next build

### QEMU boot tests

**Live ISO (VNC :7):** Boots, Plymouth visible during boot, GNOME session
autologins as liveuser (livesys-gnome runs at boot). VNC framebuffer capture
confirmed GNOME desktop loaded with dark wallpaper (adwaita-d.jpg, deep
blue/navy avg=(12,30,70) — consistent). Screen eventually blanks on idle
(GNOME power management working).

**qcow2 (VNC :8):** Boots from COW overlay. GDM starts (confirmed in serial
log). Autologin to liveuser working — liveuser pre-created at build time
by disk-specific %post block in the workflow (not livesys, which requires
`rd.live.image` kernel param and is intentionally not present for disk
images). VNC framebuffer capture confirmed GNOME desktop with dark wallpaper
(avg=(6,35,80), closely matching adwaita-d.jpg avg=(12,30,70)). Screen
blanks on idle. Both `/boot/grub2/grub.cfg` and `/boot/loader/entries/`
were empty in the static qcow2 mount; grubx64.efi has BLS autodiscovery
that finds the kernel and boots without explicit grub.cfg entries.

**QEMU screendump limitation:** `screendump` via QEMU monitor captures the
legacy VGA framebuffer, which shows black once GNOME Wayland takes over the
virtio-gpu DRM device. Use Python VNC client (as in this session) to capture
the actual display content.

### Overall AQ status

| Check | Live ISO | qcow2 | Installer ISO |
|---|---|---|---|
| Static filesystem validation | ✅ (post-fix) | ✅ | ✅ (runtime only; installed target requires full install) |
| Plymouth theme | ✅ | ✅ | ✅ (pre-fix: early-kms missing) |
| GNOME boots | ✅ | ✅ | N/A |
| Wallpaper applied | ✅ | ✅ (blue/dark) | N/A |
| early-kms.conf | ✅ | ✅ | ❌ (fixed in c661bdd, next build) |
| Dock favorites | ✅ (livesys-gnome patch confirmed) | ✅ (01-azl-desktop-favorites confirmed) | N/A |

---

## AQ testing: 2026-07-24b build artifacts (run 30118396215 / 29990996437)

Build artifacts downloaded via `aria2c -x 16` from GitHub Actions runs:
- Installer ISO: run `30118396215` (commit `c661bdd` — early-kms.conf fix)
- Live ISO + qcow2: run `29990996437` (same build as 2026-07-24 nightly release)

### Validator results (all three scripts fixed in `7a74231`)

Three validator false positives also found and fixed in this pass:
- `validate-live-iso-filesystem.sh`: favorite-apps check now accepts livesys-gnome script
  as alternate mechanism (live ISO uses runtime patching, not a dconf file)
- `validate-live-qcow2.sh`: RPM checks switched from broken SQLite GLOB to `chroot rpm -q`;
  dconf filename corrected from `00-azl-desktop-defaults` → `00-dark-mode`

| Artifact | Result | Key checks |
|---|---|---|
| Installer ISO (run 30118396215) | **10/10 PASS** | early-kms.conf ✅, Plymouth ✅, GRUB gfxterm ✅, no ttyS0 ✅ |
| Live ISO | **34/34 PASS** | livesys-gnome favorites ✅, wallpapers ✅, all launchers ✅ |
| qcow2 | **15/15 PASS** | RPM packages ✅, dconf ✅, early-kms.conf ✅, Plymouth ✅ |

### Installer ISO QEMU boot test

Boot started at 16:39. Plymouth confirmed active via VNC framebuffer capture:
98% dark + 2% bright (animated dots) — consistent with Plymouth dark splash.
Squashfs decompression from virtual CDROM takes 15-20+ min for 2.9 GB.
Serial log (ttyS0) shows only BdsDxe — expected, installer uses `console=tty0`.

Anaconda TUI confirmed via VNC after approximately 50 minutes of boot (the
bulk of the time was squashfs decompression from virtual ATAPI CDROM):
- VNC framebuffer: 98.1% dark + 1.9% gray (ncurses text, rgb 160,160,160) ✅
- Screen responded to keypresses (pixel count changed on '5'+Enter, 'r'+Enter) ✅
- Storage section stripped from kickstart — Anaconda is presenting interactive
  disk selection to the user as intended; no auto-partitioning ✅

QEMU screendump note: `screendump` via QEMU monitor works for Plymouth-phase
captures (captures VGA framebuffer) but captures stale VGA once Wayland/KMS
takes over. For post-Plymouth captures use the Python VNC client approach
documented in `qemu-gnome-interactive-testing.md`. For ncurses Anaconda TUI,
screendump works (since Anaconda is in text/framebuffer mode, not Wayland).

### Overall AQ status — 2026-07-24b

| Check | Live ISO | qcow2 | Installer ISO |
|---|---|---|---|
| Static filesystem validation | ✅ 34/34 | ✅ 15/15 | ✅ 10/10 |
| Plymouth animated boot splash | ✅ | ✅ | ✅ |
| early-kms.conf | ✅ | ✅ | ✅ (fixed in c661bdd) |
| GNOME autologin | ✅ | ✅ | N/A |
| Anaconda TUI appears | N/A | N/A | ✅ |
| Interactive disk selection | N/A | N/A | ✅ (no kickstart storage section) |
| Dock favorites | ✅ (livesys-gnome) | ✅ (01-azl-desktop-favorites) | N/A |
| Wallpaper applied | ✅ | ✅ | N/A |
