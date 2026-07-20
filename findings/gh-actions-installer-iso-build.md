# Building the installer ISO the same way Azure Linux actually does

How the installer ISO was built using KIWI-NG - the same tool
Microsoft's own Azure Linux installer ISO uses - and what broke along
the way. The live ISO build is in `gh-actions-live-iso-build.md`; this
is the installer's own timeline.

## What Azure Linux's real installer ISO is built with

`reference/azl-installer/` has files pulled directly off the real
`AzureLinux-4.0-x86_64.iso`, confirmed byte-for-byte identical to
upstream's `microsoft/azurelinux` `base/images/vm-iso-installer/`. The
whole thing is driven by `vm-iso-installer.kiwi` (KIWI-NG), not lorax:

- A `<repository>` bootstraps a minimal live-boot rootfs (Anaconda TUI,
  dracut-live, grub2/shim, nothing desktop-related).
- `config.sh` runs inside that rootfs, `dnf5 download --resolve
  --alldeps` every target-install package into `/opt/azl-offline-repo`
  and `createrepo_c` it.
- A kickstart template (`azl-install.ks.in`) whose `@@PACKAGES@@`
  placeholder `config.sh` fills in. The kickstart installs entirely
  offline from `file:///opt/azl-offline-repo/`.

An earlier "mkksiso against the real downloaded ISO" shortcut was
correctly called out as "Frankenstein stuff" and abandoned before any of
it got wired into a workflow.

## This project's adaptation

`kiwi/azl-desktop-installer.kiwi`, `kiwi/config.sh`, and
`kiwi/azl-install.ks.in`/`kiwi/azl-install-encrypted.ks.in` are direct
adaptations of those three upstream files - same schema, same
offline-repo-then-generate-kickstart pattern, same `@@PACKAGES@@`
templating, same `post-install.sh`/`post-bootloader.sh` reused
verbatim. Key differences:

- `INSTALL_PKGS` is the full GNOME + Microsoft/GitHub stack (mirrors
  the live ISO's `%packages`), not Azure Linux's minimal cloud-base set.
- GitHub Copilot GUI/CLI, `microsoft/edit`, and Flathub's repo file are
  fetched during the single build-time network window in `config.sh` and
  staged under `/opt/azl-offline-extras/`.
- Project branding/launcher assets get packaged into `assets.tar.gz` by
  `build-installer-iso.yml` and declared as a KIWI `<archive>`.
- Single profile, x86_64 only.

`.github/workflows/build-installer-iso.yml` mirrors `build-live-iso.yml`'s
shape (bare `ubuntu-24.04` runner, Fedora container via `docker run
--privileged`, same artifact-upload conventions) but runs `kiwi-ng
system build` instead of `livemedia-creator`.

## Parity bugs caught before any build was attempted

Line-by-line comparison of the live kickstart against the installer's
config turned up two real bugs:

- **RPMFusion missing** from `config.sh`'s `dnf5 download` repo list,
  but `ffmpeg`/`gstreamer1-plugin-libav` need it.
- **Global `--exclude=` instead of per-repo.** The grub2/shim/dnf5
  family exclude was applied globally (`dnf5 download --exclude=...`),
  which would have dropped those packages from the offline repo entirely
  (Fedora's copies excluded along with AZL's). Fixed with per-repo
  `--setopt=<repo>.excludepkgs=...`.

Also brought over the live ISO's runtime repo persistence
(`azl-desktop-fedora.repo` + sed-based AZL repo exclude patch in
`%post`) so the installed system keeps a working `dnf install` path.

## CI build failures: the sequence

**Run 1: `kiwi-ng: command not found`.** Fedora's `python3-kiwi`
installs the binary as `/usr/bin/kiwi-ng-3` (Fedora Python-packaging
suffix), not `kiwi-ng`. Fixed with `command -v` fallback.

**Run 2: `KiwiRuntimeError: Required tool implantisomd5 not found`.**
`mediacheck="true"` needs `isomd5sum`. Added to the container's package
list.

**Local podman loop surfaced three more conflicts** (iterated locally
instead of burning CI runs):

- `grub2-tools-extra` was in `INSTALL_PKGS` but hard-requires an
  exact-version `grub2-tools-minimal` from azl-base (excluded). Not
  actually a target-install package - only needed as a build tool.
  Removed from `INSTALL_PKGS`.
- **Multilib i686/x86_64 conflict.** `dnf5 download --alldeps` pulled
  `libpeas1-gtk-...i686` alongside the `.x86_64` build, causing an
  unresolvable conflict. `--setopt=multilib_policy=best` didn't help -
  `--alldeps` walks every architecture's chain regardless. Fixed with
  `--arch=x86_64 --arch=noarch` (note: must be repeated, not
  comma-separated - `--arch=x86_64,noarch` fails with "Unsupported
  architecture").
- **`priority=` vs `cost=` mismatch** caused `grub2-efi-x64-cdboot`'s
  azl-base dependency to be unresolvable. `priority` is a hard shadow
  (locks onto the higher-priority repo's candidate even if unresolvable);
  `cost` only tie-breaks identical NEVRAs. Fixed by switching `config.sh`
  to `--setopt=<repo>.cost=`, matching the live kickstart's `repo
  --cost=`. First time the full installer package graph resolved
  end-to-end.

## More CI failures after the package graph was clean

## Flatpak SELinux offline-repository closure

The first real headless standard installation reached Anaconda's software
selection stage and failed because the offline repository contained Fedora
Flatpak but omitted its exact matching `flatpak-selinux` dependency whenever
the target includes the targeted SELinux policy. The trimmed Anaconda error
is retained in
[`logs/installer-flatpak-selinux-dependency.log`](logs/installer-flatpak-selinux-dependency.log).

`flatpak-selinux` is now explicit in `INSTALL_PKGS`. A constrained local
solver test showed that its policy utility requirements resolve from the
Azure package set without replacing the base policy stack. The important
validation detail is that `dnf5 --assumeno` exits nonzero after a successful
solve because it declines the transaction; validation must instead reject
explicit resolver errors such as missing providers and conflicting requests.

**Anaconda bootloader support packages.** The next published-ISO installation
passed the Flatpak transaction and reached software installation, where
Anaconda added `grub2-tools-extra` for the UEFI bootloader. It is not listed in
the kickstart package block, so the old dry-run missed it; the offline
repository did too. The actual Anaconda evidence is retained in
[`logs/installer-grub-support-package.log`](logs/installer-grub-support-package.log).

`grub2-tools-extra` now belongs to `EXTRA_REPO_PKGS`, alongside the other
Anaconda-only support packages. Its matching GRUB dependencies, `grubby`,
`mtools`, and `os-prober` were already present in the generated offline repo.
The completeness dry-run now validates both `INSTALL_PKGS` and
`EXTRA_REPO_PKGS`, so a missing Anaconda support RPM fails the image build
instead of a real installation.

**`libselinux`/`libseccomp` missing from bootstrap.** All 162 of 163
bootstrap packages installed, then scriptlets failed with `error while
loading shared libraries: libseccomp.so.2` / `libselinux.so.1` against
`systemctl`, `mountpoint`, `find`, etc. The bootstrap packages'
`Requires` don't declare these as dependencies even though their
binaries dlopen/link against them at runtime. Fixed by adding both
explicitly to `<packages type="bootstrap">`.

**`qemu-img` not found.** KIWI-NG needs it to build the FAT-formatted
EFI system partition image. Added to the container's package list. Also
pre-empted a `mtools`/`mcopy` gap (found by reading kiwi-ng source)
before it could burn another CI round-trip.

**`fedora:45` container instability.** `fedora:45` is
`RELEASE_TYPE=development` (daily-drifting prerelease). `dnf5 install`
was replacing glibc/coreutils/rpm mid-container, causing `/workspace`
bind-mount failures. Fixed by pinning to `Fedora container`
(`RELEASE_TYPE=stable`) in both `build-installer-iso.yml` and
`build-live-iso.yml`.

**`/workspace` mkdir still failed after the pin.** A different cause
from the container churn: a GitHub-hosted-runner/Docker bind-mount
timing issue. Fixed pragmatically by running `mkdir` *before*
`dnf5 install` (while the mount is fresh), with a retry loop.

**Unescaped apostrophes inside `bash -c '...'`.** Comments like
`# kiwi-ng's EFI-fat-image builder` closed the outer single-quote
early, silently corrupting the script. Fixed by rewording comments to
avoid apostrophes entirely. **Rule for this workflow: no apostrophes
anywhere inside `bash -c '...'` single-quoted regions.**

**`mkfs.ext4` not found.** KIWI-NG needs `e2fsprogs` for the ext4 disk
image. Added to the container's package list.

## First successful build

Run `29625540225` succeeded end-to-end (~3.1GiB ISO). Build log archived
at `findings/logs/gha-run29625540225-installer-first-success.log`. The
post-build kickstart-extraction step failed because the installer ISO's dracut-live
squashfs nests an ext4 `rootfs.img` inside the outer `squashfs.img` -
`unsquashfs` can't reach into ext4. Fixed with `debugfs -R "dump ..."`.

## Critical bug: `@@PACKAGES@@` placeholder matched wrong occurrence

Inspecting the real rendered kickstart from the built ISO revealed it
was **badly malformed**: `%packages` was the first block, all the
`repo`/`lang`/`keyboard`/`bootloader`/partitioning directives were
shoved after `%end`, and a literal `@@PACKAGES@@` line was left orphaned
at line 166. Root cause: `config.sh`'s `sed` split matched the first
occurrence of `@@PACKAGES@@` in the file, which was in a *header
comment* describing the mechanism (`kiwi/config.sh expands @@PACKAGES@@
at ISO-build time`), not the real placeholder further down.

**Same category as the apostrophe bug**: a template mechanism's own
explanatory comment accidentally contained a literal instance of the
marker being searched for. Fixed by rewording the comment. Verified
locally with both `sed` invocations against the corrected file.

## Three-way ISO comparison findings

Diffed our installer vs. our live ISO vs. official Microsoft
`AzureLinux-4.0-x86_64.iso`:

- **Hardware-support packages** (`linux-firmware`, `bluez`, `fwupd`,
  `microcode_ctl`, `NetworkManager-wifi`, `wpa_supplicant`) were
  relying on weak deps that may or may not resolve at Anaconda install
  time. Added all six explicitly to `INSTALL_PKGS`. Also added
  `microcode_ctl` to the live kickstart (confirmed absent from its
  build log despite the `%packages` comment claiming otherwise).
- **`generic-logos`/`-fedora-logos`** was missing from the installer.
- **Installer grub menu** still said "Install Azure Linux 4.0" instead
  of "Install Azure Linux Desktop".
- **PolicyKit polkit rule** correctly *not* carried over to the installer
  (the installer's account has a real password, so the polkit challenge
  is satisfiable normally).

## Installer ISO package sourcing: same 93% Fedora ratio

The installer's offline repo showed the same 60/982/16 AZL/Fedora/other
split as the live ISO, for the same `cost=` vs `priority=` reason. Fixed
with the same claw-back mechanism - see `package-sourcing-clawback.md`.

## Additional plumbing built in the same pass

- `scripts/qemu-test-install-iso.sh` - creates a target qcow2, boots
  the installer ISO against it, prints the command to boot the
  installed disk afterward.
- `.github/workflows/release-installer-iso.yml` - same UTC-date tag
  pattern as the live release. Both release workflows targeting the same
  day upsert into the same GitHub Release automatically.
- `scripts/podman-test-azl4-fedora.sh` rewritten to parse the live
  kickstart's repo/package config directly instead of a stale
  hand-maintained copy.

## All persisted upstream repos, not just Fedora

The seven non-AZL, non-Fedora kickstart `repo` lines (`ms-prod`,
`vscode`, `edge-canary`, `gh-cli`, `github-desktop`, `rpmfusion-free`,
`rpmfusion-nonfree`) were build-time-only - never persisted to
`/etc/yum.repos.d`, leaving those packages frozen at ISO-build-time
versions with no `dnf upgrade` path. Fixed with two new `.repo` files
in both `%post` blocks:

- `azl-desktop-microsoft-github.repo`: `ms-prod`, `vscode`,
  `edge-canary`, `gh-cli`, `github-desktop` (`priority=1`).
- `azl-desktop-rpmfusion.repo`: `rpmfusion-free`, `rpmfusion-nonfree`
  (`priority=50`).

## `install-azl` silently failed for both menu options: kickstart filename mismatch

Found while dogfooding a real downloaded installer ISO locally in QEMU
(`qemu-test-install-iso.sh`, GTK window, manual QA). `install-azl` (the
symlink to `anaconda-launcher.sh`) prompts "1) Standard installation /
2) Encrypted disk (LUKS)", but both choices failed:

- Option 1: anaconda started, immediately printed `Kickstart file
  /run/install/ks.cfg is missing.` and exited 1.
- Option 2: `cp: cannot stat '/root/azl-install-encrypted.ks': No such
  file or directory`, then the same `ks.cfg is missing` failure.

`anaconda-launcher.sh` is kept byte-for-byte identical to upstream on
purpose (see `reference/azl-installer/README.md`), so its `cp
/root/azl-install.ks /run/install/ks.cfg` (option 1) and `cp
/root/azl-install-encrypted.ks /run/install/ks.cfg` (option 2) source
paths were never touched here. The bug was on this project's own side:
`kiwi/config.sh` rendered its one kickstart template to
`/root/azl-desktop-install.ks` (a name chosen to make it obviously
"this project's variant," not upstream's literal filename), so neither
path `anaconda-launcher.sh` looks for ever existed - option 1's `cp`
failed too, just silently (no `set -e`/exit-code check on that
particular `cp` in the unmodified upstream script), leaving
`/run/install/ks.cfg` never created either way.

A second, previously-undiscovered gap: this project never actually
had an encrypted kickstart variant at all - only
`kiwi/azl-desktop-install.ks.in` (standard) existed, so option 2 was
broken from the start regardless of naming, not a regression.

**Fix**: renamed the template to `kiwi/azl-install.ks.in` (rendering to
`/root/azl-install.ks`, matching upstream's own filename exactly, so
`anaconda-launcher.sh` never needs to change again), and generated a
real `kiwi/azl-install-encrypted.ks.in` companion (rendering to
`/root/azl-install-encrypted.ks`) - diffed against upstream's own
`azl-install.ks`/`azl-install-encrypted.ks` pair to confirm the only
real difference is the disk-layout section (`autopart --type=lvm
--encrypted` instead of explicit LVM partitioning, no `--passphrase` so
anaconda prompts interactively) - everything else, including the whole
package list and every `%post` block, is identical between the two.
`kiwi/config.sh`'s `render_kickstart()` now renders both from the same
`generate_packages_section()` output so they can't drift apart.
