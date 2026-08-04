# Canary container (repo-priority proof)

**Status:** active canary; see `release.yml` canary jobs

## Context

`scripts/build-canary-container.sh` and the canary jobs in `.github/workflows/release.yml` build, push, and test a small OCI image on GHCR (`ghcr.io/sirredbeard/azurelinux-desktop/canary`). Its purpose: fast proof that the Azure-Linux-base + Fedora-GNOME-layer repo priority split still resolves packages from the intended repo, without a full ISO build. It is not a containerized desktop. Mirrors Azure Linux's own `container-base` approach (systemd=false, non-bootable, tiny package set). Use `dnf --installroot` + `podman import` rather than KIWI.

## What the container installs

The container installs the project-specific package and side-load boundary:

- Azure identity/repository packages (Azure Linux base layer)
- Fedora GTK and Plymouth families (desktop library boundary, but no GNOME session)
- Microsoft Edge Canary, PowerShell, Azure CLI, VS Code Insiders, GitHub CLI and Desktop
- .NET 11 SDK via linux-x64 tarball side-load (`fetch-latest-thirdparty.sh` + `install-dotnet-sdk-tarball.sh`), not yum 9.x
- Flatpak, GitHub Copilot GUI/CLI, `microsoft/edit`
- Plymouth packages (`plymouth`, `plymouth-plugin-script`, `plymouth-plugin-label`) - exercises the Fedora Plymouth boundary that the live ISO and installer both depend on
- Same kickstart-parsed repo list and cost/exclude/include policy as live

**Does NOT install:** GDM, GNOME Shell, Mutter, Wayland, or any desktop session package group. GUI library dependencies pulled by the selected tools are expected. A working GUI is not.

## What it tests

- Repo priority split: AZL packages resolve from AZL, Fedora packages from Fedora, Microsoft/GitHub packages from their repos.
- `azurelinux-desktop-policy` transaction: proves DNF can resolve `kernel` + `azurelinux-desktop-policy` + `azurelinux-desktop-usbhid-kmod` together from the Pages repo. Cannot load the module (not bootable) but catches a stale Pages repo or broken dependency before an ISO build.
- Plymouth package availability: `plymouth`, `plymouth-plugin-script`, `plymouth-plugin-label` all resolve from Fedora. If these fail here, the installer runtime will also fail.
- Side-load binary presence: `copilot` and `edit` executables exist after install.
- `/etc/os-release` reports `NAME="Azure Linux"`, `ID=azurelinux`.

## Post-publish test (same workflow)

`release.yml` runs the canary test job after each canary publish. Steps:
1. Refresh and upgrade the image.
2. Install optional packages from both sides of the boundary: Azure `ovfenv` and `telegraf`, Fedora `dconf-editor`, GNOME Sudoku, IDLE.
3. Check RPM release tags for expected Azure or Fedora source (`.azl4*` vs `.fc43`).
4. Install Firefox, Flatseal, and Polari from Flathub (Flatpak install + inventory; `bwrap` sandbox creation fails in a non-bootable OCI image, which is expected).
5. Record versions for project-specific tools. Keep DNF transaction, enabled-repository, origin, version, and Flatpak logs as workflow artifacts.

The Flatpak test confirms the Flathub remote and Flatpak CLI work; it does not confirm that apps launch (bwrap namespace creation correctly fails in a container without `user.max_user_namespaces`).

## Three bugs found dogfood-testing

1. **`chroot /mnt/azl rpm -qa` failed (exit 127)** — no `rpm` binary in the installed set (only `librpm` came in transitively). Fix: query from the host with `rpm --root=/mnt/azl -qa`.

2. **Installed rootfs vanished after container exit.** `dnf5 --installroot=/mnt/azl` ran inside ephemeral `podman run --rm`, and `/mnt/azl` was never bind-mounted to a host path. Fix: `-v "$ROOTFS:/mnt/azl:Z"`.

3. **`tar` failed with "Permission denied" on `/etc/shadow`.** Root-owned within rootless-podman's user-namespace mapping. Fix: `podman unshare tar ...` / `podman unshare rm -rf ...`.

## Plymouth asset staging in the container

The container installs Plymouth packages to exercise the Fedora Plymouth boundary but does not set a Plymouth theme or rebuild an initramfs. Plymouth is present as a package-resolution and boundary check, not a runtime feature. If `plymouth`, `plymouth-plugin-script`, or `plymouth-plugin-label` fail to resolve in the container build, the installer runtime (which needs the same packages from the same Fedora boundary) will also fail.

## Package set alignment rules

- Keep every custom repository, RPM, and side-loaded tool that the live ISO and installer carry.
- Do NOT add GNOME, GDM, Mutter, or a desktop package group merely to make the container look like an image.
- Plymouth packages: include as a repo/boundary canary; do not configure themes or rebuild initramfs.
- Kernel package: not included (container is not bootable). The `azurelinux-desktop-policy` transaction check proves the kernel/module dependency is resolvable without retaining an actual kernel image.

## CI notes

- Canary rides the `azurelinux-desktop-publication` concurrency group on `release.yml` (same as the rest of publication).
- Local equivalent: `scripts/test-canary-container-local.sh` builds the same canary, runs the same checks, keeps logs outside the repository.

## Confirmed working

Local: 547 MB image, correct repo sourcing, `/etc/os-release` reports Azure Linux 4.0. CI run `29652166344`: pushed `:latest` and UTC-date tag to GHCR, pulled back and verified. Preflight run 2026-07-22 (`scripts/test-canary-container-local.sh`): pass (rc:0) after flatpak-step hardening; bwrap namespace warnings observed in container context but run completed.

## References

- `canary-container.md` — superseded by this file; three bugs documented
- `azure-kernel-usbhid-kmod.md` — Pages repo and policy package details
- `fedora-azl-repo-mixing.md` — repo priority split, FEDORA_EXCLUDES
Preflight 2026-07-22: container repo-origin checks PASS; canary local PASS after flatpak-step hardening (bwrap namespace warnings in container context, run completed).
- `microsoft/azurelinux` `base/images/container-base/container-base.kiwi` — upstream container-base precedent