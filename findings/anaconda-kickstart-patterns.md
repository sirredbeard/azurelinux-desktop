# Anaconda kickstart patterns

**Status:** reference (patterns still in use)

## Context

Two kickstart paths coexist: the live ISO/qcow2 path uses `livemedia-creator --no-virt` (Lorax/Anaconda dirinstall), and the installer ISO path uses KIWI-NG with an offline repo and a rendered kickstart template. Both share most `%post` patterns. The installer kickstart is rendered from `kiwi/azl-install.ks.in`/`kiwi/azl-install-encrypted.ks.in` via `config.sh`'s `render_kickstart()`.

## Known issues and root causes

### %post --nochroot vs. chroot

- **Regular `%post` has no network access** in `livemedia-creator --no-virt` builds. Anaconda's payload/dnf5 backend manages its own network setup; it is not inherited by the chrooted `%post` shell. `curl` in a regular `%post` fails with `Could not resolve host`.
- **`%post --nochroot` runs in the build-host environment** with real network and real filesystem. The target root is mounted at `/mnt/sysimage` (hardcoded in `pyanaconda/argument_parsing.py` as `ANACONDA_ROOT_PATH`). All curl-based downloads and `/workspace/` asset copies must live in `--nochroot` blocks.
- **Pattern:** stage files from `/workspace/` and download from network in `%post --nochroot` (writing to `/mnt/sysimage/...`), then pick up from inside the chroot in a regular `%post`. The test suite's own `%post` hit this bug — render-test-kickstart.sh had a regular `%post` reading `/workspace/scripts/...`, which doesn't exist inside the chroot.
- **`/workspace` is not mounted inside the chroot.** Only `%post --nochroot` can see `/workspace`.

### Asset staging permissions — critical

- **Always use `install -m 0644` (data files) and `install -m 0755` (executables)** when staging assets in `%post` sections. Never use `cp -v`.
- **Root cause:** The Fedora 43 build container that processes `assets.tar.gz` for the installer ISO runs with umask 077. `cp -v` preserves source permissions verbatim, so extracted files land at mode 600. GNOME Shell (running as the user, not root) silently drops any `.desktop` file it cannot read — PowerShell was absent from the installed GNOME dash despite dconf having the correct `favorite-apps` value. The live ISO is unaffected (direct workspace checkout preserves 644), but the fix is applied everywhere as belt-and-suspenders.
- **Confirmed fix:** `dconf read /org/gnome/shell/favorite-apps` and `gsettings get org.gnome.shell favorite-apps` from an SSH session inside the running installed GNOME session returned all 5 entries correctly.
- Apply to all three kickstarts whenever adding or changing an asset staging block.

### dconf in chroot

- Write dconf defaults to `/etc/dconf/db/local.d/<filename>` and run `dconf update` in the chrooted `%post`.
- Profile file at `/etc/dconf/profile/user` must reference the `local` system db.
- Schema overrides go in `/etc/dconf/db/local.d/locks/` for mandatory settings.
- Live ISO: `livesys-gnome` applies session settings at boot (conditioned on `rd.live.image`). For qcow2 and installed targets, all settings must be in the persistent dconf database.

### Storage directives

- **Do not re-add `clearpart`/`autopart` to the installer kickstart.** Anaconda TUI handles disk selection and partitioning interactively; it enforces minimum layout requirements (/, /boot/efi on UEFI). Encryption becomes a TUI choice after those directives were removed (2026-07-23 interactive testing batch).
- **Use bare `bootloader`** (not `--location=mbr`). Firmware-agnostic; the project targets UEFI/GPT only. `--location=mbr` is legacy BIOS and can install an unnecessary MBR path beside EFI.
- The `[!] Installation Destination (Kickstart insufficient)` warning in Anaconda TUI is **correct and expected** after removing `clearpart`/`autopart`. The `[!]` marker forces the user into option 5 (storage) before `b` (begin) is available. The wording is Anaconda-internal and not configurable without patching Anaconda. Acceptable as-is (manual QA 2026-07-25 open-item closure).
- **Live ISO kickstart storage:** `bootloader --location=none`, flat `part / --size=16384` (nothing persists past squashfs capture), `shutdown` instead of `reboot`.

### Cinnamon placeholder cleanup

Installer templates once carried a leftover `user --name=cinnamon` style placeholder and `config.sh` sed to strip it. Removed from both installer kickstart templates and live kickstart comments during the 2026-07-23 batch so Anaconda never sees a fake account directive.

### Offline repo pattern (installer ISO)

- `file:///opt/azl-offline-repo/` is the offline repository URI in the installer kickstart.
- `config.sh` downloads all packages with `dnf5 download --resolve --alldeps --arch=x86_64 --arch=noarch` (repeat `--arch`, do not use `--arch=x86_64,noarch` — comma form fails with "Unsupported architecture").
- `--alldeps` without `--arch` flags pulls i686 multilib, causing unresolvable conflicts.
- `EXTRA_REPO_PKGS` covers Anaconda support packages not in the kickstart `%packages` block (e.g. `grub2-tools-extra`). Both `INSTALL_PKGS` and `EXTRA_REPO_PKGS` must be in the offline repo; missing an Anaconda support RPM fails at installation time, not at build time.
- `dnf5 --assumeno` exits nonzero after a successful solve (user declined the transaction). Validation must only reject explicit resolver errors, not this specific exit path.

### Template rendering: `@@PACKAGES@@` placeholder

- **Comments must not contain the literal marker.** A comment like `# kiwi/config.sh expands @@PACKAGES@@` in the kickstart template caused `sed` to match the comment's occurrence first, producing a badly malformed rendered kickstart: all `repo`/`lang`/`keyboard`/`bootloader`/partitioning directives shoved after `%end`.
- **Kickstart filename must match what `anaconda-launcher.sh` expects.** The launcher copies `/root/azl-install.ks` to `/run/install/ks.cfg` (option 1) and `/root/azl-install-encrypted.ks` (option 2). Using a different rendered filename (e.g. `/root/azl-desktop-install.ks`) silently leaves `/run/install/ks.cfg` missing; Anaconda then exits with `Kickstart file /run/install/ks.cfg is missing.` The launcher has no `set -e`; the failed `cp` is silent.
- Both standard and encrypted templates share `generate_packages_section()` output so their package lists and `%post` blocks can't drift apart.

### Excluding packages

- **Use `%packages -pkgname`** (not repo-level `--excludepkgs=`) for packages whose postinstall scriptlets hard-fail in chroot (e.g. `mdatp`). The `%packages` exclusion works regardless of source repo; repo-level `--excludepkgs=` can be bypassed if the package resolves from a different repo.
- **Per-repo `--setopt=<repo>.excludepkgs=`** for build-time exclusions in `config.sh`'s `dnf5 download`. Do not use global `--exclude=`: that drops the packages from all repos including Fedora's copies, potentially removing packages the offline repo needs.

### AZL boot flow (reference)

- Azure Linux's own ISO uses `azl.autoinstall` (not `inst.ks=`) to trigger a dracut hook that hands off to `/usr/local/bin/anaconda-launcher.sh`. This project reuses that launcher verbatim.

### GDM autologin configuration

- `/etc/gdm/custom.conf` must have exactly **one `[daemon]` section**. A second `[daemon]` section (from appending config) creates ambiguous duplicate settings; GDM receives conflicting directives and may not autologin reliably.
- Correct pattern: write the full `[daemon]` section with `AutomaticLoginEnable=true` and `AutomaticLogin=liveuser` as a replacement, not an append.

### fedora-logos and anaconda-webui

- `anaconda-webui` (pulled in by `anaconda-live` for the live installer stack) hard-requires `fedora-logos`. `azurelinux-logos` conflicts with `fedora-logos`. Both the live ISO and installer ISO now align on `fedora-logos` from Fedora.
- The `system-logos` virtual dependency that would allow remix packages is present in upstream Anaconda source but not in the Fedora package this build consumes and not in AZL's published packages. Current policy: keep both paths on `fedora-logos`.
- Log excerpt: `logs/release-canary-fedora-logos-2026-07-21.log`.

## What didn't work

- **`cp -v` for asset staging:** always produces mode 600 files in the Fedora 43 build container. See Asset staging permissions section above.
- **Global `--exclude=` in `config.sh`'s `dnf5 download`:** drops packages from Fedora's copies too, breaking the offline repo for packages that must come from Fedora.
- **Anaconda GUI path (`anaconda-gui`):** not in AZL repos; available from Fedora 43. Hard-requires `fedora-logos`. Total overhead ~317 MiB download, ~1 GiB installed above text-only Anaconda. Not currently enabled; see `anaconda-gui-installer.md` research if this path is re-investigated.

## Current state

All three kickstarts use `install -m 0644`/`install -m 0755` for all asset staging. Installer kickstarts render from `kiwi/azl-install.ks.in` and `kiwi/azl-install-encrypted.ks.in` to `/root/azl-install.ks` and `/root/azl-install-encrypted.ks` respectively. Both share the same package section and `%post` blocks. Disk partitioning is delegated to Anaconda TUI for the installer. Live ISO uses `rd.live.image` conditional services for session-time-only settings; installed targets use persistent dconf databases.

## References

- `logs/installer-flatpak-selinux-dependency.log` — flatpak-selinux missing from offline repo
- `logs/installer-grub-support-package.log` — grub2-tools-extra missing from offline repo
- `logs/release-canary-fedora-logos-2026-07-21.log` — fedora-logos conflict trace
- `efi-vendor-path-azurelinux.md` — EFI/fedora vs EFI/azurelinux copy in post-bootloader
- `uefi-bdsdxe-text-before-plymouth.md` — installed GRUB gfxterm parity
- `admin-default-shell-pwsh.md` — anaconda-launcher user --shell
- `deliverable-polish-validation.md` - static verification runs (for example `29984008922`)
- `kiwi-ng-installer-build.md` — KIWI-specific config.sh patterns
- `gnome-desktop-defaults.md` — dconf, GDM, GNOME session configuration