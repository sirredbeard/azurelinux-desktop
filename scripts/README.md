# Scripts

Build, test, download, and debug helpers for Azure Linux Desktop. These are
real artifacts, not scratch paste. Prefer running them against a real image
before you lean on a one-off shell line.

If you are an agent: start here, then open the script header. Most files state
purpose, inputs, and whether they are destructive.

## Download and release

| Script | Use when |
| --- | --- |
| [`Get-AzureLinuxDesktop.ps1`](Get-AzureLinuxDesktop.ps1) | Download published live ISO, installer ISO, or disk images from GitHub Releases (split parts + checksums). |
| [`fetch-latest-thirdparty.sh`](fetch-latest-thirdparty.sh) | Build-time only. Resolve latest Copilot GUI/CLI, microsoft/edit, Flathub repo file. |
| [`log-latest-vendor-packages.sh`](log-latest-vendor-packages.sh) | Print latest Microsoft/GitHub yum NEVRAs into a CI log. |
| [`ci-commit-package-list.sh`](ci-commit-package-list.sh) | CI helper: commit refreshed `findings/*-package-list.txt`. |

## Image and container builds

| Script | Use when |
| --- | --- |
| [`build-canary-container.sh`](build-canary-container.sh) | Build the repo-priority canary OCI image locally. |
| [`build-desktop-kmods.sh`](build-desktop-kmods.sh) | Build OOT desktop kmod RPMs for a given AZL kernel (usually inside AZL container). |
| [`build-qcow2-local.sh`](build-qcow2-local.sh) | Local disk-image path when you are not on Actions. |
| [`build-fedora-kernel-live-control.sh`](build-fedora-kernel-live-control.sh) | Control build: Fedora kernel live for comparison. |
| [`generate-kmod-repo-index.sh`](generate-kmod-repo-index.sh) | Pages repo index for published kmods. |
| [`patch-anaconda-efi-skip-bug.py`](patch-anaconda-efi-skip-bug.py) | Patch Fedora anaconda EFI skip bug before livemedia-creator. |
| [`patch-dracut-livenet-hook.sh`](patch-dracut-livenet-hook.sh) | Live ISO dracut livenet hook fix. |
| [`patch-kiwi-dnf5.sh`](patch-kiwi-dnf5.sh) | KIWI + dnf5 compatibility patch in the installer build container. |
| [`configure-anaconda-efi-vendor.py`](configure-anaconda-efi-vendor.py) | EFI vendor path helpers for anaconda. |
| [`render-test-kickstart.sh`](render-test-kickstart.sh) | Render kickstart variants for local tests. |

## QEMU and nested dual-boot

Read [`../findings/qemu-gnome-interactive-testing.md`](../findings/qemu-gnome-interactive-testing.md) before interactive GNOME work.

| Script | Use when |
| --- | --- |
| [`qemu-uefi-common.sh`](qemu-uefi-common.sh) | Shared UEFI/OVMF helpers (sourced by other qemu scripts). |
| [`qemu-test-live-iso.sh`](qemu-test-live-iso.sh) | Boot a live ISO in QEMU (often graphical). |
| [`qemu-test-install-iso.sh`](qemu-test-install-iso.sh) | **Destructive to the target disk image.** Installer ISO → persistent qcow2. |
| [`qemu-test-disk-image.sh`](qemu-test-disk-image.sh) | Boot a qcow2/VHDX with snapshot (does not write back by default). |
| [`qemu-test-live-qcow2.sh`](qemu-test-live-qcow2.sh) | Live-style qcow2 boot helper. |
| [`qemu-vnc-live-iso.sh`](qemu-vnc-live-iso.sh) / [`qemu-vnc-disk-image.sh`](qemu-vnc-disk-image.sh) | VNC-oriented variants. |
| [`qemu-install-to-hostpart.sh`](qemu-install-to-hostpart.sh) | Install into the nested dual-boot container partition. Host-destructive if pointed wrong. |
| [`qemu-boot-installed-hostpart.sh`](qemu-boot-installed-hostpart.sh) | Boot the nested install (supports BT USB passthrough / snapshot modes). |
| [`qemu-manual-install-qa.sh`](qemu-manual-install-qa.sh) | Manual installer QA checklist driver. |
| [`restage-azl-nested-boot.sh`](restage-azl-nested-boot.sh) | Restage nested boot bits after host changes. |
| [`inspect-azl-nested-install.sh`](inspect-azl-nested-install.sh) | Mount/inspect nested root without full boot. |

## Validation and tests

| Script | Use when |
| --- | --- |
| [`test-boot-smoke.sh`](test-boot-smoke.sh) | Headless serial marker smoke boot. |
| [`test-container-repos.sh`](test-container-repos.sh) | Repo-priority / package origin canary (CI preflight). |
| [`test-canary-container.sh`](test-canary-container.sh) / [`test-canary-container-local.sh`](test-canary-container-local.sh) | Hybrid image tests. |
| [`test-bt-qemu-passthrough.sh`](test-bt-qemu-passthrough.sh) | Bluetooth USB passthrough diagnostics in QEMU. |
| [`azl-bt-gather.sh`](azl-bt-gather.sh) | On-system BT diagnostics tarball (sudo; read-mostly). |
| [`test-in-guest-checks.sh`](test-in-guest-checks.sh) / [`test-post-boot-checks.sh`](test-post-boot-checks.sh) | Guest-side checks after boot. |
| [`test-installer-kiwi-build.sh`](test-installer-kiwi-build.sh) / [`test-installer-runtime-resolve.sh`](test-installer-runtime-resolve.sh) | Installer package resolve / kiwi dry checks. |
| [`test-repo-common.sh`](test-repo-common.sh) | Shared repo test helpers. |
| [`podman-test-azl4-fedora.sh`](podman-test-azl4-fedora.sh) | Podman resolve of the mixed desktop set. |
| [`run-preflight-split.sh`](run-preflight-split.sh) | Split local preflight with per-step logs. |
| [`validate-live-iso.sh`](validate-live-iso.sh) / [`validate-installer-iso.sh`](validate-installer-iso.sh) / [`validate-live-qcow2.sh`](validate-live-qcow2.sh) | Artifact filesystem / structure checks. |
| [`validate-live-iso-filesystem.sh`](validate-live-iso-filesystem.sh) / [`verify-final-polish-filesystems.sh`](verify-final-polish-filesystems.sh) | Mounted-root polish checks. |
| [`validate-boot-behavior.sh`](validate-boot-behavior.sh) / [`validate-interactive.sh`](validate-interactive.sh) | Boot behavior and interactive QA. |

## Misc analysis

| Script | Use when |
| --- | --- |
| [`analyze-screenshot.py`](analyze-screenshot.py) / [`analyze-live-wallpaper-match.sh`](analyze-live-wallpaper-match.sh) | Screenshot / wallpaper pixel checks. |
| [`boot-monitor.py`](boot-monitor.py) | Serial boot marker watcher. |

## Conventions

* Prefer `install -m` over `cp` when staging assets into images.
* Do not commit secrets. `GITHUB_TOKEN` is CI-only env.
* Destructive scripts should say so in the header and refuse missing args.
* Keep findings in `../findings/` when a script exposes a new root cause.

## Always-latest vendor packages

- `fetch-latest-thirdparty.sh` - GitHub release assets (Copilot GUI RPM, Copilot CLI, microsoft/edit, Flathub remote) plus the current **.NET 11** linux-x64 SDK tarball from Microsoft release-metadata / download page / aka.ms (not yum).
- `install-dotnet-sdk-tarball.sh` - Layout `/usr/share/dotnet` + `/usr/bin/dotnet` + `DOTNET_ROOT` from that tarball.
- `log-latest-vendor-packages.sh` - NEVRA snapshot from Microsoft/GitHub yum feeds, and logs the resolved .NET 11 SDK version (tarball side-load).
