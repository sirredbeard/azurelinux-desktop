# Scripts

Build, test, download, and debug helpers for Azure Linux Desktop. These are
real artifacts, not scratch paste. Prefer running them against a real image
before you lean on a one-off shell line.

If you are an agent: start with this map, then open the script header. Every
script states purpose, usage, needs, and whether CI calls it. Headers only
describe the tool; the body is the source of truth for flags and edge cases.

Work large downloads under `~/azl-work`, not `/tmp`.

## Full map

| Script | CI | Role |
| --- | --- | --- |
| [`Get-AzureLinuxDesktop.ps1`](Get-AzureLinuxDesktop.ps1) | No | Download + reassemble + checksum published release assets (live ISO, installer ISO, qcow2/VHDX/VDI/VMDK). |
| [`resolve-release-tag.sh`](resolve-release-tag.sh) | Yes (`release.yml`) | Attach uploads to latest existing GitHub Release; mint UTC-date tag only when none exists. |
| [`fetch-latest-thirdparty.sh`](fetch-latest-thirdparty.sh) | Yes (image builds) | Resolve latest GitHub Copilot GUI/CLI, microsoft/edit, Flathub repo file, .NET 11 SDK tarball. |
| [`install-copilot-desktop-flatpak.sh`](install-copilot-desktop-flatpak.sh) | Yes (image/canary) | System-install Microsoft Copilot GTK Flatpak + Platform//50 into a rootfs; register Pages update remote. |
| [`prestage-copilot-flatpak-system.sh`](prestage-copilot-flatpak-system.sh) | Yes (live/disk/installer) | Build a copy-ready `/var/lib/flatpak` tree before livemedia/kiwi (avoids Anaconda post hang). || [`install-dotnet-sdk-tarball.sh`](install-dotnet-sdk-tarball.sh) | Yes (image/canary) | Install a .NET SDK tarball into a rootfs. |
| [`log-latest-vendor-packages.sh`](log-latest-vendor-packages.sh) | Yes | Snapshot Microsoft/GitHub yum NEVRAs and .NET 11 version into CI logs. |
| [`ci-commit-package-list.sh`](ci-commit-package-list.sh) | Yes (`build-*.yml`) | Commit refreshed `findings/*-package-list.txt`. |
| [`build-canary-container.sh`](build-canary-container.sh) | Yes (`release.yml`) | Build package-policy canary OCI image. |
| [`build-desktop-kmods.sh`](build-desktop-kmods.sh) | Yes (`publish-desktop-kmods.yml`) | Build OOT desktop kmod RPMs for an Azure Linux kernel. |
| [`generate-kmod-repo-index.sh`](generate-kmod-repo-index.sh) | Yes (kmods) | DNF repo index for GitHub Pages kmod repo. |
| [`build-qcow2-local.sh`](build-qcow2-local.sh) | No | Local disk-image build; generates disk kickstart from live.ks. |
| [`build-fedora-kernel-live-control.sh`](build-fedora-kernel-live-control.sh) | No | Diagnostic live build with Fedora kernel (not a release path). |
| [`patch-anaconda-efi-skip-bug.py`](patch-anaconda-efi-skip-bug.py) | Yes (live disk) | Patch anaconda EFI bootable-partition bug before `--make-disk`. |
| [`configure-anaconda-efi-vendor.py`](configure-anaconda-efi-vendor.py) | Yes (live build) | EFI vendor path helpers for anaconda (`EFI/azurelinux`). |
| [`patch-dracut-livenet-hook.sh`](patch-dracut-livenet-hook.sh) | Yes (live kickstart) | Fix target dracut livenet hook during live image `%post`. |
| [`patch-kiwi-dnf5.sh`](patch-kiwi-dnf5.sh) | Yes (installer build) | KIWI + DNF5 compatibility in the installer build container. |
| [`render-test-kickstart.sh`](render-test-kickstart.sh) | No | Render kickstart variants for local experiments. |
| [`qemu-uefi-common.sh`](qemu-uefi-common.sh) | No | Shared UEFI/OVMF helpers (sourced by other qemu scripts). |
| [`qemu-test-live-iso.sh`](qemu-test-live-iso.sh) | No | Boot a live ISO in QEMU. |
| [`qemu-test-install-iso.sh`](qemu-test-install-iso.sh) | No | **Destructive to target disk image.** Installer ISO → qcow2. |
| [`qemu-test-disk-image.sh`](qemu-test-disk-image.sh) | No | Boot qcow2/VHDX with snapshot by default. |
| [`qemu-test-live-qcow2.sh`](qemu-test-live-qcow2.sh) | No | Boot a live-style qcow2. |
| [`qemu-vnc-live-iso.sh`](qemu-vnc-live-iso.sh) | No | Live ISO + VNC for captures. |
| [`qemu-vnc-disk-image.sh`](qemu-vnc-disk-image.sh) | No | Disk image + VNC for captures. |
| [`qemu-install-to-hostpart.sh`](qemu-install-to-hostpart.sh) | No | **Host-destructive if wrong device.** Installer → nested partition. |
| [`qemu-boot-installed-hostpart.sh`](qemu-boot-installed-hostpart.sh) | No | Boot nested install (BT passthrough / snapshot options). |
| [`qemu-manual-install-qa.sh`](qemu-manual-install-qa.sh) | No | Manual installer QA driver. |
| [`restage-azl-nested-boot.sh`](restage-azl-nested-boot.sh) | No | Restage nested boot, dracut `50azl-nested-partx`, GRUB drop-in. |
| [`inspect-azl-nested-install.sh`](inspect-azl-nested-install.sh) | No | Mount/inspect nested root without full boot. |
| [`test-boot-smoke.sh`](test-boot-smoke.sh) | No | Headless serial-marker smoke boot. |
| [`test-container-repos.sh`](test-container-repos.sh) | Yes/local | Repo-priority and package-origin assertions. |
| [`test-repo-common.sh`](test-repo-common.sh) | Indirect | Shared helpers for repo tests (sourced). |
| [`test-canary-container.sh`](test-canary-container.sh) | Yes (`release.yml`) | Canary policy tests (DNF, origins, tools, Flatpak). |
| [`test-canary-container-local.sh`](test-canary-container-local.sh) | No | Local canary build+test without GHCR push. |
| [`test-bt-qemu-passthrough.sh`](test-bt-qemu-passthrough.sh) | No | BT USB passthrough diagnostics in QEMU. |
| [`azl-bt-gather.sh`](azl-bt-gather.sh) | No | On-system BT diagnostics bundle (sudo; read-mostly). |
| [`test-in-guest-checks.sh`](test-in-guest-checks.sh) | No | Checks inside a booted guest. |
| [`test-post-boot-checks.sh`](test-post-boot-checks.sh) | No | Post-boot service/path assertions. |
| [`test-installer-kiwi-build.sh`](test-installer-kiwi-build.sh) | No | Local KIWI smoke (Actions remains authoritative). |
| [`test-installer-runtime-resolve.sh`](test-installer-runtime-resolve.sh) | No | Resolve installer offline set without full ISO. |
| [`podman-test-azl4-fedora.sh`](podman-test-azl4-fedora.sh) | No | Podman resolve of mixed desktop package set. |
| [`run-preflight-split.sh`](run-preflight-split.sh) | Local | Split local preflight with per-step logs (not a workflow). |
| [`validate-live-iso.sh`](validate-live-iso.sh) | No | Live ISO structure/content validation. |
| [`validate-live-iso-filesystem.sh`](validate-live-iso-filesystem.sh) | No | Mounted live root polish checks. |
| [`validate-installer-iso.sh`](validate-installer-iso.sh) | No | Installer ISO layout checks (initrd path, files). |
| [`validate-live-qcow2.sh`](validate-live-qcow2.sh) | No | qcow2 partition/EFI/content checks. |
| [`verify-final-polish-filesystems.sh`](verify-final-polish-filesystems.sh) | No | Cross-deliverable polish parity on mounted roots. |
| [`validate-interactive.sh`](validate-interactive.sh) | No | Interactive QEMU QA checklist driver. |
| [`analyze-screenshot.py`](analyze-screenshot.py) | No | Pixel stats / diffs for boot screenshots. |
| [`analyze-live-wallpaper-match.sh`](analyze-live-wallpaper-match.sh) | No | Match live screenshot to wallpaper candidates on-device. |
| [`boot-monitor.py`](boot-monitor.py) | No | Serial boot marker watcher. |

## By task

### Download and release

* [`Get-AzureLinuxDesktop.ps1`](Get-AzureLinuxDesktop.ps1) - published assets from GitHub Releases.
* [`resolve-release-tag.sh`](resolve-release-tag.sh) - one-release attach rule for CI uploads.
* [`fetch-latest-thirdparty.sh`](fetch-latest-thirdparty.sh) / [`install-copilot-desktop-flatpak.sh`](install-copilot-desktop-flatpak.sh) / [`install-dotnet-sdk-tarball.sh`](install-dotnet-sdk-tarball.sh) / [`log-latest-vendor-packages.sh`](log-latest-vendor-packages.sh) - always-latest vendor side-loads.
* [`ci-commit-package-list.sh`](ci-commit-package-list.sh) - package list refresh commit.

### Image and container builds

* [`build-canary-container.sh`](build-canary-container.sh) - canary OCI.
* [`build-desktop-kmods.sh`](build-desktop-kmods.sh) / [`generate-kmod-repo-index.sh`](generate-kmod-repo-index.sh) - Pages kmod repo (see `publish-desktop-kmods.yml`).
* [`build-qcow2-local.sh`](build-qcow2-local.sh) - local disk image.
* [`build-fedora-kernel-live-control.sh`](build-fedora-kernel-live-control.sh) - Fedora-kernel control only.
* Anaconda/KIWI patches: [`patch-anaconda-efi-skip-bug.py`](patch-anaconda-efi-skip-bug.py), [`configure-anaconda-efi-vendor.py`](configure-anaconda-efi-vendor.py), [`patch-dracut-livenet-hook.sh`](patch-dracut-livenet-hook.sh), [`patch-kiwi-dnf5.sh`](patch-kiwi-dnf5.sh).

### QEMU and nested dual-boot

Read [`../findings/qemu-gnome-interactive-testing.md`](../findings/qemu-gnome-interactive-testing.md) before interactive GNOME work.

* Shared: [`qemu-uefi-common.sh`](qemu-uefi-common.sh)
* Boot tests: `qemu-test-live-iso.sh`, `qemu-test-disk-image.sh`, `qemu-test-live-qcow2.sh`, VNC variants
* Installer: `qemu-test-install-iso.sh` (destructive to the target image), `qemu-manual-install-qa.sh`
* Nested host partition: `qemu-install-to-hostpart.sh`, `qemu-boot-installed-hostpart.sh`, `restage-azl-nested-boot.sh`, `inspect-azl-nested-install.sh`

### Validation and tests

* Repo/canary: `test-container-repos.sh`, `test-repo-common.sh`, `test-canary-container.sh`, `test-canary-container-local.sh`, `podman-test-azl4-fedora.sh`, `run-preflight-split.sh`
* Installer resolve: `test-installer-runtime-resolve.sh`, `test-installer-kiwi-build.sh`
* Guest/boot: `test-boot-smoke.sh`, `test-in-guest-checks.sh`, `test-post-boot-checks.sh`, `test-bt-qemu-passthrough.sh`, `azl-bt-gather.sh`
* Artifact FS: `validate-live-iso.sh`, `validate-live-iso-filesystem.sh`, `validate-installer-iso.sh`, `validate-live-qcow2.sh`, `verify-final-polish-filesystems.sh`, `validate-interactive.sh`
* Screenshots: `analyze-screenshot.py`, `analyze-live-wallpaper-match.sh`, `boot-monitor.py`

## Workflows these scripts plug into

* [`../.github/workflows/release.yml`](../.github/workflows/release.yml) - human-facing publication; calls canary build/test, `resolve-release-tag.sh`, and optional kmods.
* [`../.github/workflows/build-live-iso.yml`](../.github/workflows/build-live-iso.yml) / [`build-installer-iso.yml`](../.github/workflows/build-installer-iso.yml) - reusable image builds (not dispatched alone).
* [`../.github/workflows/publish-desktop-kmods.yml`](../.github/workflows/publish-desktop-kmods.yml) - hybrid: own schedule/dispatch **and** `workflow_call` from release. Keep it separate so kernel drift can rebuild the Pages DNF repo without a full ISO night.

## Conventions

* Prefer `install -m` over `cp` when staging assets into images.
* Do not commit secrets. `GITHUB_TOKEN` is CI-only env.
* Destructive scripts say so in the header and refuse missing args.
* Keep findings in `../findings/` when a script exposes a new root cause. Paste key log lines into the topic file; do not add a `findings/logs/` tree.
* Kickstart source of truth is `../kickstart/azurelinux-desktop-live.ks`. The disk-image kickstart is generated at build time; see [`../kickstart/README.md`](../kickstart/README.md).

## Always-latest vendor packages

* `fetch-latest-thirdparty.sh` - GitHub release assets (Copilot GUI RPM, Copilot CLI, microsoft/edit, Flathub remote) plus the current **.NET 11** linux-x64 SDK tarball from Microsoft release-metadata / download page / aka.ms (not yum).
* `install-dotnet-sdk-tarball.sh` - Layout `/usr/share/dotnet` + `/usr/bin/dotnet` + `DOTNET_ROOT` from that tarball.
* `log-latest-vendor-packages.sh` - NEVRA snapshot from Microsoft/GitHub yum feeds, and the resolved .NET 11 SDK version (tarball side-load).
