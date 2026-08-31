# Fedora + Azure Linux repo mixing

**Status:** active policy; canary guards drift

## Context

This project installs a full GNOME desktop on Azure Linux by mixing AZL
repos (priority source for base OS) with Fedora repos (GNOME/GTK stack
and anything AZL does not ship). Core challenges: `cost=` vs `priority=`
in dnf5, ABI conflicts between package families, and an explicit exclude
list so Fedora NEVRAs do not silently replace AZL-owned packages.

## priority= vs cost=

- `priority=` is a hard shadow. dnf5 picks the highest-priority repo's
  candidate even if it is unresolvable. Lower-priority repos never get
  that package name.
- `cost=` only tie-breaks identical NEVRAs. If Fedora has a newer NEVRA
  than AZL for the same name, Fedora wins regardless of cost.

When `priority=` was switched to `cost=` alone (to fix a
`grub2-efi-x64-cdboot` conflict), a real install flipped almost
everything to Fedora builds, including kernel and systemd.

Fix: `--setopt=Fedora.excludepkgs=<list>` (and matching for
Fedora-updates) removes names from Fedora's candidate pool before cost
tie-breaks. Wired into `kiwi/config.sh` `FEDORA_EXCLUDES` and the live
kickstart `repo --excludepkgs=`.

After clawback, base OS pieces (kernel, systemd, NetworkManager, bluez,
firmware, coreutils/util-linux/cryptsetup/openssh/audit/firewalld/
selinux-policy layer as owned) resolve to AZL again. Exact package
counts drift over time; trust canary and preflight scripts, not a frozen
number in this file.

## Packages that cannot move back to AZL

1. **glibc family (stays on Fedora).** gtk4/gnome-shell need a glibc
   symbol floor AZL does not meet. Excluding glibc from Fedora with
   `--skip-unavailable` silently drops the GNOME session.
2. **wpa_supplicant (stays on Fedora).** No AZL build. Silent drop
   breaks WiFi with nothing loud in the build log.
3. **fwupd (stays on Fedora).** AZL fwupd vs Fedora freerdp/libcbor
   soname fight. Fedora fwupd is the workable choice. `fwupd-efi` can
   still resolve to AZL.

## ABI fork: fuse3-libs

AZL `grub2-tools-minimal` links `libfuse3.so.3`. Fedora flatpak/portal
need `libfuse3.so.4`. Both stay installed. Do not try to unify them.

## Version-locked sibling libraries

Clawing back a parent without its exact-version-locked siblings breaks
it. When excluding from Fedora, keep families together, for example:

- util-linux / util-linux-core with libblkid, libmount, libuuid,
  libfdisk, libsmartcols
- e2fsprogs with libcom_err
- xz with xz-libs

## FEDORA_EXCLUDES list

The live kickstart carries a long static exclude list for AZL-owned
names (audit, bash, bluez, coreutils, cryptsetup, dbus, device-mapper,
e2fsprogs, firewalld, kernel*, kmod, NetworkManager*, openssh*,
selinux-policy*, systemd*, util-linux*, and related). Keep the live
kickstart and installer config as the source of truth. Update both when
ownership changes.

Installer ISO: `kiwi/config.sh` can build excludes dynamically from
installed RPM vendor "Microsoft Corporation". Live/qcow2 kickstarts use
the static list and must be updated by hand when new AZL-owned packages
would otherwise be shadowed.

## Cockpit / selinux-policy / anaconda-webui

Earlier assumption that AZL shipped cockpit was wrong. Cockpit is
Fedora-sourced. `anaconda-live` gained a dep on `anaconda-webui`, which
needs recent cockpit. That forces Fedora selinux-policy packages that
satisfy cockpit's version floor, rather than pinning cockpit out of
Fedora forever.

Current direction: do not exclude the whole cockpit family and do not
force AZL selinux-policy when Fedora's newer policy is required for the
Anaconda/cockpit chain. Verify with canary rebuilds when Anaconda deps
move again.

Security updates for cockpit stay on the Fedora path.

## Other specific conflicts

- `hunspell-en`: pure file collision; exclude from AZL, let Fedora win.
- `gsettings-desktop-schemas`: version floor for gnome-shell; exclude
  from AZL.
- Entire grub2/shim family to Fedora when fuse3 soname forks collide
  with cherry-picks.
- dnf5/libdnf5 family to Fedora when gnome-software needs a newer
  dnf5daemon than AZL ships.
- `-aznfs` in `%packages`: ms-prod helper whose `%pre` fails without
  `/proc`.
- `grub2-efi-x64-cdboot` must be explicit for Lorax EFI templates.

## Persisting non-AZL/non-Fedora repos

Build-time-only repo lines left packages frozen with no upgrade path.
Both `%post` blocks write:

- `azl-desktop-microsoft-github.repo` (ms-prod, vscode, edge-canary,
  gh-cli, github-desktop; priority 1)
- `azl-desktop-rpmfusion.repo` (free/nonfree; priority 50)

Azure Linux base and Fedora `.repo` files come from their packages.

## What did not work

- `priority=` for Fedora repos (broke grub2-efi-x64-cdboot resolution)
- `dnf group install workstation-product-environment` (far more
  conflicts than a curated set)
- `--skip-unavailable` for packages not in AZL (silent drop)
- Using Fedora rawhide instead of the current stable Fedora donor
  (too much glibc drift)

## Alternative architectures considered and rejected

- systemd-sysext/confext: same host glibc; does not solve symbol floors
- bootc/OSTree: no AZL bootc base; same libdnf conflicts under the hood
- systemd-nspawn full desktop: seat/GPU/PipeWire bridging pain
- Toolbox/distrobox for the GNOME session itself: wrong tool
- Full COPR rebuild of the desktop stack: means owning a newer glibc;
  only as a narrow pilot if ever

## Desktop lifecycle and update policy

- Treat each published image as one tested AZL + Fedora generation.
- Routine `dnf upgrade` is reasonable only while that generation's repos
  and ownership exclusions stay unchanged.
- When the Fedora desktop repo reaches EOL, AZL updates do not replace
  missing desktop-layer security updates.
- Do not auto-redirect an installed image to a newer Fedora release.
- Normal migration: backup or snapshot, then clean install of a new
  image.

## Prior art

- Unaffiliated installers that add Fedora repos to AZL for lighter DEs
  confirm the basic approach.
- ublue-style CentOS + GNOME COPR stacks hit the same conflict class and
  fix with excludes and version locks.

## Related

- Live kickstart repo lines and `kiwi/config.sh` FEDORA_EXCLUDES
- `scripts/podman-test-azl4-fedora.sh`, canary tests
- `github-actions-build.md`
- `live-iso-installer-parity.md`

## pinentry and NetworkManager-wwan (runtime dnf update)

See `dnf-update-pinentry-nm-wwan.md`.

* pinentry stays on Fedora with pinentry-gnome3; exclude pinentry from AZL base.
* NetworkManager-wwan stays on AZL with the rest of NetworkManager; exclude from Fedora.
* Install-time excludepkgs must be rewritten onto stock `[azurelinux-base]`
  section names or they vanish after first boot.

## perl core

Claw perl, perl-libs, perl-interpreter, perl-Errno to AZL. Fedora newer perl-libs breaks AZL Errno exact NVR require. See dnf-update-pinentry-nm-wwan.md.
