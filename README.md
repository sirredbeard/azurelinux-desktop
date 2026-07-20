# Azure Linux Desktop Proof of Concept

<img width="1197" height="836" alt="Screenshot From 2026-07-17 18-01-10" src="https://github.com/user-attachments/assets/2df0ccfc-2cf4-43fa-b150-83319ea9d07d" />

This puts a real GNOME desktop on top of Microsoft's [Azure Linux 4.0](https://github.com/microsoft/azurelinux).

This is the bare-metal follow-up to [Azure Linux Desktop: a Build 2026 mashup of wslc, WinUI Reactor, and Azure Linux 4.0](https://www.boxofcables.dev/azure-linux-desktop-a-build-2026-mashup-of-wslc-winui-reactor-and-azure-linux-4-0/), the original concept, which ran the same idea as a themed session inside wslc, inside a .NET app.

This is a personal side project, explored for fun. **It is not affiliated with, sponsored by, or endorsed by Microsoft, the Fedora Project, Red Hat, the GNOME Foundation, or GitHub.** The package mixing required to accomplish this *will inevitably result in broken dependencies*. Be prepared to handle that. 

Some very basic testing is done on the outgoing images, I also build a minimal container to test the hybrid Azure Linux and Fedora dnf priority scheme adopted here. Nonetheless, **I do not recommend running this in production.** That's why live ISOs and VM images are available for you to explore this. An installer ISO is available if you dare to install on bare metal. I haven't tested it yet.

## What's included

### Base

* [Azure Linux](https://github.com/microsoft/AzureLinux) 4.0 base

### Desktop Environment

* [GNOME](https://www.gnome.org/) from [Fedora](https://fedoraproject.org/)

### Developer Tools

* [Microsoft VS Code Insiders](https://code.visualstudio.com/insiders/)
* [GitHub CLI](https://github.com/cli/cli)
* [GitHub Copilot CLI](https://github.com/github/copilot-cli)
* [GitHub Copilot App](https://github.com/github/app)
* [Github Desktop](https://github.com/shiftkey/desktop)
* [PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/linux-overview?view=powershell-7.6) (default shell)
* [Edit](https://github.com/microsoft/edit) (default terminal editor)
* [.NET 11 Runtime and SDK](https://dotnet.microsoft.com/en-us/download/dotnet/11.0)

### Web and Email

* [Microsoft Edge Canary](https://explore.microsoft.com/en-us/edge) (default web browser)
* [GNOME Evolution](https://help.gnome.org/evolution/mail-account-manage-microsoft-exchange.html) with Exchange support

### Errata

* Dark mode enabled
* GNOME utilities (audio player, video player, document viewer, screenshot utility, weather, text editor)
* Custom Plymouth boot theme
* Linux firmware, bluez, fwupd, upower, media codecs, common fonts
* [Flatpak](https://flatpak.org/) configured with [Flathub](https://flathub.org/)

## Why does this exist

[Azure Linux](https://github.com/microsoft/azurelinux) is server- and cloud-native by design, and [Fedora](https://fedoraproject.org/) always gets the latest GNOME. Azure Linux 4.0's userland turns out to be close enough to Fedora that a real, current GNOME desktop sourced from Fedora can be layered on top of it with the right repo priority setup.

The result: GNOME, PowerShell, Visual Studio Code Insiders, Microsoft Edge Canary, GitHub CLI, GitHub Desktop, GitHub Copilot (GUI and CLI), .NET, and Flathub/Flatpak support, all running on Azure Linux 4.0's actual base.

### Where the packages actually come from

The base is Azure Linux. Kernel, systemd, NetworkManager, bluez, fwupd-efi, linux-firmware, coreutils, util-linux, cryptsetup, and the rest of the system layer all resolve to Azure Linux. `glibc` has to come from Fedora: `gtk4` needs newer symbol versioning than AZL4's glibc ships, it's the ABI floor the rest of the GUI stack sits on. A few other packages (`wpa_supplicant`, `fwupd`/`fwupd-efi`, `fuse3`) must come from Fedora or ship side by side.

Current package-by-package listings are in [`findings/live-package-list.txt`](findings/live-package-list.txt) and [`findings/installer-package-list.txt`](findings/installer-package-list.txt).

## How it's built

There are two separate ISOs here, built two different ways, on purpose.

**The live ISO** (`kickstart/azurelinux-desktop-live.ks`) is what you boot to try the desktop without touching a disk. It's fed to [`lorax`](https://github.com/weldr/lorax) and `livemedia-creator --no-virt`, which runs a real `anaconda --dirinstall` package install against Azure Linux's own repos plus a pinned Fedora 44 repo for GNOME and everything GNOME needs, then squashes the result into a live-bootable ISO. Lorax is the right tool here because it's built specifically for producing live media, and the live ISO isn't trying to be anything else. The build runs on GitHub Actions ([`.github/workflows/build-live-iso.yml`](.github/workflows/build-live-iso.yml)) from a clean runner every time.

**The installer ISO** (`kiwi/`) is what you boot to actually install the desktop to a disk. This one is built with [KIWI-NG](https://github.com/OSInside/kiwi), because that's what Microsoft's own real Azure Linux 4.0 installer ISO is built with. I looked at `microsoft/azurelinux`'s own `base/images/vm-iso-installer/` directory and copied its approach: a `.kiwi` image description bootstraps a minimal live-boot environment (just enough to run a text-mode Anaconda, nothing desktop-related), `config.sh` downloads every real target package plus dependencies into an offline repo baked onto the ISO, and a kickstart template gets its package list filled in from that same list at build time. The kickstart installs entirely offline, no network needed at install time, same as the real thing. What's different from upstream is the package list itself (the full GNOME 50 + Microsoft/GitHub stack instead of Azure Linux's minimal cloud base), the extra network fetches for GitHub Copilot/edit/Flathub done during that same build-time window, and a real default account (`cinnamon`) instead of a locked-root cloud image. Full writeup of that decision in [`findings/gh-actions-installer-iso-build.md`](findings/gh-actions-installer-iso-build.md). The build runs on GitHub Actions too ([`.github/workflows/build-installer-iso.yml`](.github/workflows/build-installer-iso.yml)), same clean-runner-every-time approach.

**The disk images** (qcow2/VHDX/VDI/VMDK) skip the ISO/install step entirely and boot straight to a desktop. They come from the same `azurelinux-desktop-live.ks` kickstart as the live ISO, but run through `livemedia-creator --make-disk` instead of `--make-iso`, so the disk-image variant enables one extra thing the ISO doesn't need: `azl-growroot.service`, a small oneshot unit (`cloud-utils-growpart` + `xfs_growfs`) that grows the root partition/filesystem to fill whatever size the disk gets resized to after the anaconda install finishes, since Anaconda only sizes the partition to the small disk it's given at install time. `build-disk-image` ([`.github/workflows/build-live-iso.yml`](.github/workflows/build-live-iso.yml)) runs the anaconda install and produces the base qcow2; three independent jobs (`build-vhdx`, `build-vdi`, `build-vmdk`) each take that qcow2 and run a single `qemu-img convert` to produce the other three formats, each with its own `workflow_dispatch` input so any one of them can be rebuilt without re-running the anaconda install or the other conversions. Full trace of the bugs that came up building this (partition growth, VHDX losing its resize, a unit-enablement ordering bug) in [`findings/gh-actions-live-iso-build.md`](findings/gh-actions-live-iso-build.md).

Getting the live ISO's package set right took some package-resolution work, documented in [`findings/investigation.md`](findings/investigation.md):

- A curated GNOME desktop (shell, session, gdm, mutter, nautilus, the usual pieces) layered from Fedora onto Azure Linux 4.0 resolves cleanly with the right repo setup.
- Three real conflicts showed up along the way, a file collision, a version floor, and a hard ABI fork between Azure Linux's bootloader tooling and Fedora's flatpak/portal stack, each with its own fix, documented in the findings.
- Throwing Fedora's entire `workstation-product-environment` group at it in one shot does not work. Big, unpredictable package pulls surface new soname conflicts faster than you can track them.
- I also checked five alternative build architectures (systemd-sysext, bootc, systemd-nspawn desktop containers, the Universal Blue/Bluefin model, distrobox app export) to see if any of them sidestep the RPM-level conflicts instead of just moving them around. None of them do, though bootc is worth adopting later for reproducibility, and distrobox is genuinely useful for anything added after the base desktop. Full writeup in [`findings/alternative-architectures.md`](findings/alternative-architectures.md).

## How it's tested

Five stages, each one a higher bar than the last:

1. **podman, full resolve/installroot.** Before anything touches lorax/kiwi or a real ISO build, the full package set gets resolved and installed into a throwaway root filesystem with `dnf --installroot`, using [`scripts/podman-test-azl4-fedora44.sh`](scripts/podman-test-azl4-fedora44.sh). It parses the real repo/cost/excludepkgs setup and `%packages` list straight out of `kickstart/azurelinux-desktop-live.ks`, so it always tests what the live ISO would actually resolve, not a hand-maintained copy of it. Fast, cheap, and it is where every packaging conflict so far actually got caught, before a full ISO build was ever spent on it.
2. **podman, fast repo-origin check.** [`scripts/test-container-repos.sh`](scripts/test-container-repos.sh) is the narrower, cheaper follow-up to that broader installroot test: same kickstart-parsed repo definitions, but only a curated package set covering the actual Azure-Linux-vs-Fedora sourcing assertions (`systemd`/`kernel`/`NetworkManager` on AZL, `glibc`/`gdm`/`gnome-shell`/`flatpak` on Fedora, and the known `wpa_supplicant`/`fwupd` exceptions). This is the quick "did repo policy drift?" check for iteration.
3. **headless QEMU/OVMF, no KVM.** [`.github/workflows/test-images.yml`](.github/workflows/test-images.yml) builds a test-only qcow2 variant from the same kickstart, boots it headless in QEMU with real UEFI/OVMF firmware and a serial console, and waits for either a boot marker ([`scripts/test-boot-smoke.sh`](scripts/test-boot-smoke.sh)) or the guest's own PASS/FAIL markers from a first-boot oneshot test unit ([`scripts/test-post-boot-checks.sh`](scripts/test-post-boot-checks.sh) + [`scripts/test-in-guest-checks.sh`](scripts/test-in-guest-checks.sh)). This is intentionally slow - GitHub-hosted runners do not expose nested KVM, so the VM runs under pure TCG software emulation - but it is the first actually automated "does it boot, does `dnf upgrade` finish, does Flathub still work" gate.
4. **local QEMU/KVM, real window.** Once the automated headless checks look sane, the actual built ISO can be booted locally in QEMU/KVM with a real GTK window. [`scripts/qemu-test-live-iso.sh`](scripts/qemu-test-live-iso.sh) boots the live ISO for manual desktop QA. [`scripts/qemu-test-install-iso.sh`](scripts/qemu-test-install-iso.sh) does the same for the installer ISO against a persistent qcow2 target disk.
5. **Bare metal.** Not done yet. I have not booted this on real hardware. That is the next milestone once the live ISO itself is fully solid in QEMU.

## What else

I recorded all my findings, lessons learned, and the gotchas's I hit building this project in [/findings/](findings/) where you can read more, or have your LLM review it. All scripts, kickstart files, config files are here.

## How do I use this

Every release is built straight from this repo's kickstart/kiwi files through the GitHub Actions workflows linked above, so it can always be reproduced from source. Grab the latest one from [Releases](https://github.com/sirredbeard/azurelinux-desktop/releases), tagged by build date - live and installer releases share the same date tag when they publish the same day, so both ISOs (and the live disk images, see below) usually land in one release.

**PowerShell:**

```powershell
irm https://raw.githubusercontent.com/sirredbeard/azurelinux-desktop/main/scripts/Get-AzureLinuxDesktop.ps1 -OutFile Get-AzureLinuxDesktop.ps1
./Get-AzureLinuxDesktop.ps1 -Live
```

Swap `-Live` for whichever you want:

| Flag | Description |
| --- | --- |
| `-Live` | Live desktop ISO (default, boot/try it, no install) |
| `-Install` | Installer ISO (installs to a real or virtual disk) |
| `-Kvm` | Live desktop, pre-built qcow2 for QEMU/KVM |
| `-Hyperv` | Live desktop, pre-built VHDX for Hyper-V |
| `-VirtualBox` | Live desktop, pre-built VDI for VirtualBox |
| `-VMWare` | Live desktop, pre-built VMDK for VMware |

Don't have [PowerShell](https://github.com/PowerShell/PowerShell)? [Get it](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell).

Every asset runs well over GitHub's 2 GiB per-asset cap on releases, so it ships as split parts plus a `.sha256` manifest, and VHDX/VDI/VMDK also ship 7z-compressed on top (qemu-img only compresses qcow2 natively). The script handles all of that for you - downloading every part, reassembling, verifying, and decompressing - using [`aria2c`](https://aria2.github.io/) if it's on PATH for faster downloads, falling back to `Invoke-WebRequest` otherwise. `-OutputDirectory <path>` and `-KeepParts` combine with any of the flags above. See [`findings/asset-download-details.md`](findings/asset-download-details.md) for the full flag reference, more example invocations, and why assets are packaged this way.

On Linux or macOS, download the parts and the manifest by hand from the Releases page, then reassemble and verify with:

```bash
cat azurelinux-desktop-live.iso.split.*.part > azurelinux-desktop-live.iso
sha256sum -c azurelinux-desktop-live.iso.sha256
```

(swap `azurelinux-desktop-live.iso` for `azurelinux-desktop-install.iso` or `azurelinux-desktop-live.qcow2` for the other non-compressed asset kinds - same split/manifest naming pattern.)

VHDX, VDI, and VMDK reassemble to a `.7z` instead of the disk image itself, so add one more step after the checksum passes:

```bash
cat azurelinux-desktop-live.vhdx.7z.split.*.part > azurelinux-desktop-live.vhdx.7z
sha256sum -c azurelinux-desktop-live.vhdx.7z.sha256
7z x azurelinux-desktop-live.vhdx.7z
```

(swap `azurelinux-desktop-live.vhdx` for `azurelinux-desktop-live.vdi` or `azurelinux-desktop-live.vmdk` for the other two - same pattern.)

[`scripts/qemu-test-live-iso.sh`](scripts/qemu-test-live-iso.sh) boots the reassembled live ISO with `-cpu host` and a real GTK window, so you can actually watch the desktop come up instead of squinting at serial output:

```bash
./scripts/qemu-test-live-iso.sh /path/to/azurelinux-desktop-live.iso
```

[`scripts/qemu-test-install-iso.sh`](scripts/qemu-test-install-iso.sh) does the same for the installer ISO, creating a persistent qcow2 target disk and installing onto it:

```bash
./scripts/qemu-test-install-iso.sh /path/to/azurelinux-desktop-install.iso
```

[`scripts/qemu-test-disk-image.sh`](scripts/qemu-test-disk-image.sh) boots a qcow2/VHDX disk image directly (headless, serial console, real UEFI/OVMF firmware, `-snapshot` by default so it never modifies the artifact):

```bash
./scripts/qemu-test-disk-image.sh /path/to/azurelinux-desktop-live.qcow2
```

[`scripts/test-boot-smoke.sh`](scripts/test-boot-smoke.sh) is the CI/headless version of that check: same UEFI/OVMF/serial-console path, but no KVM, no window, and a wait-for-marker loop that exits nonzero if the serial-enabled test qcow2 never reaches a login/GDM/systemd boot marker:

```bash
./scripts/test-boot-smoke.sh /path/to/azurelinux-desktop-live.qcow2
```

[`scripts/test-container-repos.sh`](scripts/test-container-repos.sh) is the quick repo-policy check when you only want to know whether the Azure-Linux-vs-Fedora package sourcing rules still resolve the way the kickstart says they should, without booting a VM at all:

```bash
./scripts/test-container-repos.sh
```

The full headless suite lives in [`.github/workflows/test-images.yml`](.github/workflows/test-images.yml). It builds a dedicated test qcow2, runs the boot-smoke check, then boots that same qcow2 again and lets the guest itself run `dnf upgrade`, package-origin assertions, and a real Flathub install over the serial console. [`scripts/test-post-boot-checks.sh`](scripts/test-post-boot-checks.sh) is that second host-side wrapper; it expects the test-only qcow2 variant the workflow builds, not a release artifact.

The `-Kvm`/`-Hyperv`/`-VirtualBox`/`-VMWare` disk images all skip the install step entirely - boot the qcow2 straight in QEMU/KVM, attach the VHDX to a Hyper-V Generation 2 VM, attach the VDI to a VirtualBox VM, or attach the VMDK to a VMware Workstation/Player VM (all UEFI-only, same as the installed system itself), and you're at the desktop with no Anaconda run needed. All four are converted from the same 64G-grown qcow2, so they're the same disk contents in different container formats - VDI and VMDK just haven't been boot-tested in this project yet, since this dev environment deliberately has no VirtualBox or VMware installed.

Real hardware should work the same way once you have burned or flashed the live or installer ISO to media, though see above, bare metal has not been verified yet.

### Default accounts

The live ISO and pre-built disk images autologin as `liveuser` (no password, passwordless `sudo`) - there's nothing to type in, they are throwaway test images.

The installer ISO creates a real, persistent account named `cinnamon` on the installed system (`wheel`/`sudo`, GDM autologin after the first boot). Its password is a known, deliberately public placeholder - **`cinnamon`** - not a real security boundary for a personal proof of concept; change it (`passwd cinnamon`) on any install you actually care about securing.

## Where do I get help

This is a one-person experiment, not a supported project. Open an issue if something here is wrong, or if you have found a fix to one of the open conflicts. I would genuinely like to know. Do not expect support running this on your own hardware. Nobody has booted it there yet, including me.

## License

Code original to this repository is MIT licensed. The built images pull in
Azure Linux, Fedora and GNOME, PowerShell, Visual Studio Code Insiders,
Microsoft Edge Canary, .NET, GitHub CLI, GitHub Desktop, GitHub Copilot CLI,
GitHub Copilot, and edit, each under its own license - see
[LICENSE](LICENSE) for the full text and per-component acknowledgements.

This is a personal proof-of-concept project. It is not affiliated with,
sponsored by, or endorsed by Microsoft, the Fedora Project, Red Hat, the
GNOME Foundation, or GitHub. Microsoft, Azure, Azure Linux, Windows,
Microsoft Edge, Visual Studio Code, PowerShell, GitHub, GitHub Desktop,
and GitHub Copilot are trademarks of the Microsoft group of companies.
Fedora is a trademark of Red Hat, Inc. GNOME is a trademark of the GNOME
Foundation. Linux is the registered trademark of Linus Torvalds in the
United States and other countries. No ownership of any of these names,
logos, or trademarks is claimed.
