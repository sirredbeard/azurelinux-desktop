# Anaconda kickstart patterns

**Status:** Reference (patterns still in use)

## Context

Two kickstart paths coexist:

* Live ISO/qcow2: `livemedia-creator --no-virt` (Lorax/Anaconda
  dirinstall)
* Installer ISO: KIWI-NG with an offline repo and a rendered kickstart
  template

Both share most `%post` patterns. The installer kickstart is rendered
from `kiwi/azl-install.ks.in` via `config.sh`'s `render_kickstart()`,
then copied to `/root/azl-install-encrypted.ks` so the launcher's second
menu entry still has a file. Storage is interactive Anaconda TUI for
both.

## %post --nochroot vs chroot

* Regular `%post` has no network in `livemedia-creator --no-virt`
  builds. Anaconda's payload manages its own network; the chrooted
  `%post` shell does not inherit it. `curl` fails with
  `Could not resolve host`.
* `%post --nochroot` runs in the build-host environment with real
  network and real filesystem. The target root is at `/mnt/sysimage`
  (`ANACONDA_ROOT_PATH` in `pyanaconda/argument_parsing.py`). All
  curl-based downloads and `/workspace/` asset copies must live in
  `--nochroot` blocks.
* Pattern: stage files from `/workspace/` (live) or
  `/opt/azl-desktop-assets` (installer ISO) in `%post --nochroot`, copy
  the full assets tree to the target `/root/assets`, then chrooted
  `%post` uses `ASSETS=/root/assets` and removes the tree at the end.
* `/workspace` and installer `/opt/azl-desktop-assets` are not visible
  inside the target chroot. Only `%post --nochroot` can see them.
  See `findings/rpm-gpg-keys-on-target.md` for the disk-build failure
  when chroot still pointed at `/workspace`.

The test suite's own `%post` hit this bug. See `test-suite.md`.

## Asset staging permissions (critical)

Always use `install -m 0644` (data files) and `install -m 0755`
(executables) when staging assets in `%post`. Never use `cp -v`.

Root cause: the Fedora build container that processes `assets.tar.gz`
for the installer ISO runs with umask 077. `cp -v` preserves source
permissions, so extracted files land at mode 600. GNOME Shell (running
as the user) silently drops any `.desktop` file it cannot read.
PowerShell was absent from the installed GNOME dash despite dconf having
the correct `favorite-apps` value. Live ISO is unaffected (direct
workspace checkout keeps 644). Apply the fix everywhere.

Confirmed fix: `dconf read` / `gsettings get` of `favorite-apps` from
SSH inside the running installed GNOME session returned all entries.

Apply to all three kickstarts whenever adding or changing an asset
staging block.

## dconf in chroot

* Write defaults to `/etc/dconf/db/local.d/<filename>` and run
  `dconf update` in the chrooted `%post`.
* Profile file at `/etc/dconf/profile/user` must reference the `local`
  system db.
* Schema overrides go in `/etc/dconf/db/local.d/locks/` for mandatory
  settings.
* Live ISO: `livesys-gnome` applies session settings at boot (conditioned
  on `rd.live.image`). For qcow2 and installed targets, all settings must
  be in the persistent dconf database.

## Storage directives

* Do not re-add `clearpart`/`autopart` to the installer kickstart.
  Anaconda TUI handles disk selection and partitioning. It enforces
  minimum layout (/, /boot/efi on UEFI). Encryption is a TUI choice
  after those directives were removed (2026-07-23).
* Use bare `bootloader` (not `--location=mbr`). Firmware-agnostic; the
  project targets UEFI/GPT only.
* The `[!] Installation Destination (Kickstart insufficient)` warning
  in Anaconda TUI is correct and expected after removing
  `clearpart`/`autopart`. The `[!]` marker forces the user into storage
  before begin is available. Acceptable as-is.
* Live ISO kickstart storage: `bootloader --location=none`, flat
  `part / --size=16384` (nothing persists past squashfs capture),
  `shutdown` instead of `reboot`.

## Headless QEMU install (local test only)

Product installer ISO stays interactive for disk and admin account.
Unattended install into a test qcow2 is a local overlay, not a product
change:

* `scripts/qemu-headless-install-to-qcow2.sh` extracts `root/azl-install.ks`
  from the ISO, injects `ignoredisk`/`clearpart`/`autopart` for the
  virtio disk (`vda`), replaces `rootpw --lock` with an iscrypted admin
  user (default `fedora`/`fedora`), keeps product `%packages`/`%post`,
  and serves the temporary ks over HTTP on the host.
* Boot is direct-kernel (same pattern as `qemu-install-to-hostpart.sh`)
  with `inst.ks=http://10.0.2.2:<port>/test-install.ks`,
  `azl.autoinstall`, and `inst.text`. That path skips the launcher TUI.
* After Anaconda finishes, the guest reboots into the installed disk.
  The script waits on SSH, then shuts the guest down for mount checks
  with `scripts/verify-release-features.sh --installed-qcow`.

Do not put `clearpart`/`autopart` or a baked-in admin password back into
`kiwi/azl-install.ks.in`.

## Cinnamon placeholder cleanup

Installer templates once carried a leftover `user --name=cinnamon`
style placeholder and `config.sh` sed to strip it. Removed so Anaconda
never sees a fake account directive.

## Offline repo pattern (installer ISO)

* `file:///opt/azl-offline-repo/` is the offline repository URI.
* `config.sh` downloads packages with
  `dnf5 download --resolve --alldeps --arch=x86_64 --arch=noarch`
  (repeat `--arch`; do not use comma form).
* `--alldeps` without `--arch` flags pulls i686 multilib and causes
  conflicts.
* `EXTRA_REPO_PKGS` covers Anaconda support packages not in kickstart
  `%packages` (for example `grub2-tools-extra`, `nvme-cli`). Missing an
  Anaconda support RPM fails at installation time, not at build time.
* `dnf5 --assumeno` exits nonzero after a successful solve (user
  declined the transaction). Validation must only reject explicit
  resolver errors, not this exit path.

## Template rendering: @@PACKAGES@@ placeholder

* Comments must not contain the literal marker. A comment like
  `# kiwi/config.sh expands @@PACKAGES@@` caused `sed` to match the
  comment first and produce a badly malformed rendered kickstart.
* Kickstart filename must match what `anaconda-launcher.sh` expects.
  The launcher copies `/root/azl-install.ks` to `/run/install/ks.cfg`
  (option 1) and `/root/azl-install-encrypted.ks` (option 2). A
  different rendered filename silently leaves `/run/install/ks.cfg`
  missing. The launcher has no `set -e`; the failed `cp` is silent.
* Both standard and encrypted templates share
  `generate_packages_section()` output so package lists and `%post`
  blocks cannot drift apart.

## Excluding packages

* Use `%packages -pkgname` (not repo-level `--excludepkgs=`) for
  packages whose postinstall scriptlets hard-fail in chroot (for
  example `mdatp`). Repo-level exclude can be bypassed if the package
  resolves from a different repo.
* Per-repo `--setopt=<repo>.excludepkgs=` for build-time exclusions in
  `config.sh`'s `dnf5 download`. Do not use global `--exclude=`: that
  drops packages from all repos including Fedora's copies.

## AZL boot flow (reference)

Azure Linux's own ISO uses `azl.autoinstall` (not `inst.ks=`) to
trigger a dracut hook that hands off to
`/usr/local/bin/anaconda-launcher.sh`. This project reuses that
launcher.

## GDM autologin configuration

`/etc/gdm/custom.conf` must have exactly one `[daemon]` section. A
second `[daemon]` section creates ambiguous duplicate settings. Write
the full section with `AutomaticLoginEnable=true` and
`AutomaticLogin=liveuser` as a replacement, not an append.

## fedora-logos and anaconda-webui

`anaconda-webui` (pulled by `anaconda-live`) hard-requires
`fedora-logos`. `azurelinux-logos` conflicts with `fedora-logos`. Both
the live ISO and installer ISO align on `fedora-logos` from Fedora.

Evidence:

```
Failed to resolve the transaction:
Problem: package anaconda-webui-... from fedora43 requires fedora-logos,
but none of the providers can be installed
  - package azurelinux-logos-... from azl-base conflicts with fedora-logos
  - package anaconda-live-... from fedora43 requires anaconda-webui
```

## What did not work

* `cp -v` for asset staging: always produces mode 600 files in the
  Fedora build container.
* Global `--exclude=` in `config.sh`'s `dnf5 download`: drops packages
  from Fedora's copies too.
* Anaconda GUI path (`anaconda-gui`): not in AZL repos; available from
  Fedora. Hard-requires `fedora-logos`. Large overhead. Not currently
  enabled.

## Current state

Live and installer paths use `install -m 0644`/`install -m 0755` for
asset staging. The installer template is only `kiwi/azl-install.ks.in`;
`config.sh` renders it to `/root/azl-install.ks` and copies that file to
`/root/azl-install-encrypted.ks`. Disk partitioning is delegated to
Anaconda TUI for the installer. Live ISO uses `rd.live.image`
conditional services for session-time-only settings; installed targets
use persistent dconf databases.

## Related

Offline repo gap evidence:

```
package flatpak-... from azl-offline requires
(flatpak-selinux = ... if selinux-policy-targeted),
but none of the providers can be installed

Requirement 'grub2-tools-extra' is applied.
Reason: Necessary for the bootloader configuration.
No match for argument: grub2-tools-extra
```

* `efi-vendor-path-azurelinux.md`
* `uefi-bdsdxe-text-before-plymouth.md`
* `admin-default-shell-pwsh.md`
* `deliverable-polish-validation.md`
* `kiwi-ng-installer-build.md`
* `gnome-desktop-defaults.md`
