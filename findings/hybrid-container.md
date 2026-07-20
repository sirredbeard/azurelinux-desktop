# Hybrid container publishing - what it is and three bugs found building it

`scripts/build-hybrid-container.sh` + `.github/workflows/build-container.yml`
publish a small OCI image to GHCR (`ghcr.io/sirredbeard/azurelinux-desktop/hybrid`)
straight from the kickstart's own repo/priority setup. A fast proof that
the Azure-Linux-base + Fedora-GNOME-layer repo priority split still
resolves packages from the intended repo, pullable without running a
build.

## What it deliberately is not

Not a containerized desktop. Ships a tiny proof-of-priority package set:
`filesystem`, `bash`, `azurelinux-release` (from `azl-base`, cost=1)
plus `glib2`, `gtk4` (from `Fedora`, cost=50).

## Precedent

Mirrors Azure Linux's own `container-base` approach
(`microsoft/azurelinux`'s `base/images/container-base/container-base.kiwi`):
tiny, non-bootable, no systemd, `machine-bootable=false`. This project
uses `dnf --installroot` + `podman import` instead of KIWI.

## Three bugs found dogfood-testing

1. **`chroot /mnt/azl rpm -qa` failed (exit 127)** - no `rpm` binary
   in the installed set (only `librpm` came in transitively). Fix: query
   from the host with `rpm --root=/mnt/azl -qa`.

2. **Installed rootfs vanished after container exit.** `dnf5
   --installroot=/mnt/azl` ran inside ephemeral `podman run --rm`, and
   `/mnt/azl` was never bind-mounted to a host path. Fix:
   `-v "$ROOTFS:/mnt/azl:Z"`.

3. **`tar` failed with "Permission denied" on `/etc/shadow`.** These
   files are root-owned within rootless-podman's user-namespace
   mapping. Fix: `podman unshare tar ...` / `podman unshare rm -rf ...`.

## Confirmed working

Local: 547MB image, correct repo sourcing, `/etc/os-release` reports
Azure Linux 4.0. CI run
[29652166344](https://github.com/sirredbeard/azurelinux-desktop/actions/runs/29652166344):
pushed `:latest` and UTC-date tag to GHCR, pulled back and verified.
