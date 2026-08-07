# Canary container (repo-priority proof)

**Status:** Active canary. Lifecycle is `containers.yml` (not `release.yml`).

## Purpose

`containers/canary/Dockerfile` (wrapper `scripts/build-canary-container.sh`) and
`.github/workflows/containers.yml` build, push, prune, and test a small OCI image
on GHCR (`ghcr.io/sirredbeard/azurelinux-desktop/canary`).

Goal: fast proof that the Azure Linux base + Fedora GNOME-layer repo
priority split still resolves packages from the intended repo, without a
full ISO build. It is not a containerized desktop. Mirrors Azure Linux's
own `container-base` idea (no systemd boot, non-bootable, tiny package
set). Built with `docker build` from the repo root. Stage 1 is Fedora as a
build host; packages go into `dnf --installroot` so `azurelinux-release`
does not conflict with `fedora-release`. Final image is `FROM scratch`
plus that rootfs. Repos and dconf come from `assets/` (no kickstart awk,
no nested podman).

## What it installs

Project-specific package and side-load boundary:

* Azure identity and repository packages (Azure Linux base layer)
* Fedora GTK and Plymouth families (desktop library boundary, no GNOME
  session)
* Microsoft Edge Canary, PowerShell, Azure CLI, VS Code Insiders,
  GitHub CLI and Desktop
* .NET SDK via linux-x64 tarball side-load
  (`fetch-latest-thirdparty.sh` + `install-dotnet-sdk-tarball.sh`), not
  yum 9.x
* Flatpak, GitHub Copilot GUI/CLI, `microsoft/edit`
* Plymouth packages (`plymouth`, `plymouth-plugin-script`,
  `plymouth-plugin-label`) so the Fedora Plymouth boundary is exercised
* Same repo cost/exclude policy as live via `assets/yum.repos.d/azurelinux-desktop.repo`

Does not install GDM, GNOME Shell, Mutter, Wayland, or any desktop
session package group. GUI library deps pulled by tools are expected. A
working GUI is not.

## What it tests

* Repo priority split: AZL packages from AZL, Fedora from Fedora,
  Microsoft/GitHub from their repos
* `azurelinux-desktop-policy` transaction: DNF can resolve `kernel` +
  policy + usbhid kmod together from the Pages repo. Cannot load the
  module (not bootable) but catches a stale Pages repo or broken dep
  before an ISO build
* Plymouth package availability from Fedora
* Side-load binary presence: `copilot` and `edit`
* `/etc/os-release` reports `NAME="Azure Linux"`, `ID=azurelinux`

## Post-publish test (same workflow)

After each canary publish, `containers.yml` `canary-test` runs:

1. Refresh and upgrade the image.
2. Install optional packages from both sides of the boundary (Azure
   `ovfenv` and `telegraf`, Fedora `dconf-editor`, GNOME Sudoku, IDLE).
3. Check RPM release tags for expected Azure or Fedora source
   (`.azl4*` vs `.fc43`).
4. Install Firefox, Flatseal, and Polari from Flathub (install +
   inventory; `bwrap` sandbox creation fails in a non-bootable OCI
   image, which is expected).
5. Record versions for project tools. Keep DNF transaction, repo,
   origin, version, and Flatpak logs as workflow artifacts.

The Flatpak test confirms the Flathub remote and Flatpak CLI work. It
does not confirm that apps launch.

## Historical installroot bugs (fixed by Dockerfile path)

1. `chroot /mnt/azl rpm -qa` failed (exit 127). No `rpm` binary in the
   installed set (only `librpm` came in transitively). Fix: query from
   the host with `rpm --root=/mnt/azl -qa`.

2. Installed rootfs vanished after container exit.
   `dnf5 --installroot=/mnt/azl` ran inside ephemeral
   `podman run --rm`, and `/mnt/azl` was never bind-mounted to a host
   path. Fix: `-v "$ROOTFS:/mnt/azl:Z"`.

3. `tar` failed with "Permission denied" on `/etc/shadow`. Root-owned
   within rootless-podman's user-namespace mapping. Fix:
   `podman unshare tar ...` / `podman unshare rm -rf ...`.

## Plymouth in the container

The container installs Plymouth packages to exercise the Fedora
boundary. It does not set a theme or rebuild an initramfs. If those
packages fail to resolve here, the installer runtime will also fail.

## Package set rules

* Keep every custom repository, RPM, and side-loaded tool that live and
  installer carry.
* Do not add GNOME, GDM, Mutter, or a desktop package group just to make
  the container look like an image.
* Include Plymouth packages as a repo/boundary canary only.
* Kernel package is not retained. The policy transaction proves the
  kernel/module dependency is resolvable without keeping a kernel image.

## CI notes

* Canary rides the `azurelinux-desktop-publication` concurrency group on
  `release.yml`.
* Local equivalent: `scripts/test-canary-container-local.sh`.

## Confirmed working

Local: correct repo sourcing, `/etc/os-release` reports Azure Linux 4.0.
CI has pushed `:latest` and UTC-date tags to GHCR and pulled them back.
Preflight after flatpak-step hardening: pass (bwrap namespace warnings
in container context are expected).

## Copilot Flatpak GPG (2026-08-04)

Canary must keep the Microsoft Copilot GTK system Flatpak and the Pages
remote. After Pages signed the stream, `scripts/test-canary-container.sh`
asserts:

* app present with origin on `copilot-desktop-gtk`
* remote name registered
* `/var/lib/flatpak/repo/config` has `gpg-verify=true` for that remote
* `flatpak remote-ls` reaches live Pages

Unsigned or `--no-gpg-verify` remotes fail the canary on purpose so
image builds do not ship a system update path that GNOME Software cannot
use.

## Bug: canary test required awk (2026-08-04)

**Status:** Resolved (Actions canary-test success on run 30948995292)

Evidence: run `30940687637` / job `92101184754` (`canary-test`):

```
/usr/local/bin/test-canary-container: line 141: awk: command not found
```

The gpg-verify assert used `awk` on `/var/lib/flatpak/repo/config`.
The canary package set is intentional minimal (no awk). Live/installer
images still get gawk via the full base set.

Fix: parse the remote section in pure bash in
`scripts/test-canary-container.sh`. Do not add gawk only for this check.

## Related

* `azure-kernel-usbhid-kmod.md` (Pages repo and policy package)
* `fedora-azl-repo-mixing.md` (repo priority split, FEDORA_EXCLUDES)
* `microsoft/azurelinux` `base/images/container-base/container-base.kiwi`
