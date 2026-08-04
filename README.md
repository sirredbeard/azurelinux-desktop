# Azure Linux Desktop Proof of Concept

<img width="1197" height="836" alt="Screenshot From 2026-07-17 18-01-10" src="https://github.com/user-attachments/assets/2df0ccfc-2cf4-43fa-b150-83319ea9d07d" />

## What this is

This puts a real GNOME desktop on top of Microsoft's [Azure Linux 4.0](https://github.com/microsoft/azurelinux).

**This not officially supported by Microsoft, Azure, GitHub, or Fedora. This is a personal proof of concept experiment only.**

This is a follow-up to [Azure Linux Desktop: a Build 2026 mashup of wslc, WinUI Reactor, and Azure Linux 4.0](https://www.boxofcables.dev/azure-linux-desktop-a-build-2026-mashup-of-wslc-winui-reactor-and-azure-linux-4-0/), the original concept, which ran the same idea as a themed session inside wslc, inside a .NET app, on Windows.

This is a personal side project, explored for fun. **It is not affiliated with, sponsored by, or endorsed by Microsoft, the Fedora Project, Red Hat, the GNOME Foundation, or GitHub.** The package mixing required to accomplish this *will likely result in broken dependencies*. Be prepared to handle that. 

**Do not run this in production.** That's why live ISOs and VM images are available for you to explore. An installer ISO is available if you dare to install on bare metal, but only on a machine you can sacrifice, do not install this as your daily driver. Some basic testing is done on the outgoing images. A minimal 'canary' container is built to test the repo mixing and do a handful of tasks, that's it.

Third-party scripts/RPM packages are very likely to get confused by the repo mixing here. I strongly encourage using [Flatpak](https://flatpak.org/) for desktop applications. Flatpak is configured on installs with Flathub added and tested in the minimal 'canary' container.

**This project is x86_64-focused for now.** The live ISO, installer ISO, and
disk images target Intel-class machines: chipset, GPU, and audio paths that
show up on typical Intel laptops and desktops are what get exercised. aarch64
is on the wishlist (I want to get there), but it is not a supported image
target yet. Out-of-tree desktop drivers this repo publishes cover some
x86_64 gaps Azure's stock kernel leaves open: USB HID/storage, Intel
Wi-Fi, ALSA HDA/USB audio, Bluetooth, UVC cameras, ThinkPad ACPI, and
USB Type-C/UCSI. If you need another driver for real hardware, [open an
issue](https://github.com/sirredbeard/azurelinux-desktop/issues) and I'll do my best.

## What's included

### Base

* [Azure Linux](https://github.com/microsoft/AzureLinux) 4.0 base

### Desktop Environment

* [GNOME](https://www.gnome.org/) from [Fedora](https://fedoraproject.org/)
* [Copilot](https://github.com/sirredbeard/copilot-desktop-gtk)

### Web and Email

* [Microsoft Edge Canary](https://explore.microsoft.com/en-us/edge) (default web browser)
* [GNOME Evolution](https://help.gnome.org/evolution/mail-account-manage-microsoft-exchange.html) with Exchange support

### Developer Tools

* [Microsoft VS Code Insiders](https://code.visualstudio.com/insiders/)
* [GitHub CLI](https://github.com/cli/cli)
* [GitHub Copilot CLI](https://github.com/github/copilot-cli)
* [GitHub Copilot App](https://github.com/github/app)
* [GitHub Desktop](https://github.com/shiftkey/desktop)
* [PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/linux-overview?view=powershell-7.6) (default shell)
* [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux?view=azure-cli-latest&pivots=dnf)
* [Edit](https://github.com/microsoft/edit) (default terminal editor)
* [.NET 11 Runtime and SDK](https://dotnet.microsoft.com/en-us/download/dotnet/11.0)

### Also Included

* Dark mode enabled by default
* GNOME utilities (audio player, video player, document viewer, screenshot utility, weather, text editor)
* Custom Azure Linux Plymouth boot theme
* Linux firmware, bluez, fwupd, upower, media codecs, and common fonts
* [Flatpak](https://flatpak.org/) configured with [Flathub](https://flathub.org/)
* Desktop hardware kernel modules

## Why does this exist

[Azure Linux](https://github.com/microsoft/azurelinux) is server- and cloud-native by design, and [Fedora](https://fedoraproject.org/) always gets the latest GNOME. Azure Linux 4.0's userland turns out to be close enough to Fedora that a real, current GNOME desktop sourced from Fedora can be layered on top of it with the right repo priority setup.

The result: GNOME, Copilot, PowerShell, Visual Studio Code Insiders, Microsoft Edge Canary, GitHub CLI, GitHub Desktop, GitHub Copilot (GUI and CLI), .NET, Azure CLI, and Flatpak support, all running on Azure Linux 4.0's actual base.

### Where the packages actually come from

The base is Azure Linux. Kernel, systemd, NetworkManager, bluez, fwupd-efi, linux-firmware, coreutils, util-linux, cryptsetup, and the rest of the system layer all resolve to Azure Linux. `glibc` has to come from Fedora: `gtk4` needs newer symbol versioning than Azure Linux 4.0's glibc ships, it's the ABI floor the rest of the GUI stack sits on. A few other packages (`wpa_supplicant`, `fwupd`/`fwupd-efi`, `fuse3`) must come from Fedora or ship side by side.

Current package-by-package listings are in [`findings/live-package-list.txt`](findings/live-package-list.txt) and [`findings/installer-package-list.txt`](findings/installer-package-list.txt). Successful live and installer ISO builds on Actions refresh those files automatically.

Microsoft and GitHub products are not version-pinned in the kickstarts. Each build pulls whatever is current from the Microsoft yum repos (PowerShell, Azure CLI, VS Code Insiders, Edge Canary), the GitHub CLI repo, the GitHub Desktop mirror, and GitHub Releases for Copilot GUI/CLI and `microsoft/edit`. .NET 11 is not on the yum feeds yet, so SDK tarball builds are side-loaded. The Microsoft Copilot GTK app is installed from its latest Flatpak on GitHub Pages (`com.github.sirredbeard.copilot-desktop-gtk`) with `org.gnome.Platform//50` from Flathub, so later updates use ordinary `flatpak update`.

Build/test helpers live under [`scripts/`](scripts/) with a short catalog in [`scripts/README.md`](scripts/README.md).

## How it's built

There are two separate ISOs/images here, built two different ways:

**The live ISO** (`kickstart/azurelinux-desktop-live.ks`) is what you boot to try the desktop without touching a disk. It's fed to [`lorax`](https://github.com/weldr/lorax) and `livemedia-creator --no-virt`, which runs a real `anaconda --dirinstall` package install against Azure Linux's own repos plus a pinned Fedora repo for GNOME and everything GNOME needs, then squashes the result into a live-bootable ISO. Lorax is built specifically for producing live media. The build runs on GitHub Actions ([`.github/workflows/release.yml`](.github/workflows/release.yml)) from a clean runner every time.

**The installer ISO** (`kiwi/`) is what you boot to actually install the desktop to a disk. This one is built with [KIWI-NG](https://github.com/OSInside/kiwi), because that's what Microsoft's own real Azure Linux 4.0 installer ISO is built with. I looked at `microsoft/azurelinux`'s own `base/images/vm-iso-installer/` directory and copied its approach: a `.kiwi` image description bootstraps a minimal live-boot environment (just enough to run a text-mode Anaconda, nothing desktop-related), `config.sh` downloads every real target package plus dependencies into an offline repo baked onto the ISO, and a kickstart template gets its package list filled in from that same list at build time. The kickstart installs entirely offline, no network needed at install time, same as the real thing. What's different from upstream is the package list itself (the full GNOME + Microsoft/GitHub stack instead of Azure Linux's minimal cloud base) and the extra network fetches for GitHub Copilot, edit, etc. done during that same build-time window. Account setup remains interactive, matching Azure Linux's installer templates. Full writeup of that decision in [`findings/kiwi-ng-installer-build.md`](findings/kiwi-ng-installer-build.md). The build runs on GitHub Actions too ([`.github/workflows/release.yml`](.github/workflows/release.yml)), same clean-runner-every-time approach.

**The disk images** (qcow2/VHDX/VDI/VMDK) skip the ISO/install step entirely and boot straight to a desktop. They come from the same `azurelinux-desktop-live.ks` kickstart as the live ISO, but run through `livemedia-creator --make-disk` instead of `--make-iso`, so the disk-image variant enables one extra thing the ISO doesn't need: `azl-growroot.service`, a small oneshot unit (`cloud-utils-growpart` + `xfs_growfs`) that grows the root partition/filesystem to fill whatever size the disk gets resized to after the anaconda install finishes, since Anaconda only sizes the partition to the small disk it's given at install time. `build-disk-image` (driven by [`release.yml`](.github/workflows/release.yml)) runs the anaconda install and produces the base qcow2; three independent jobs (`build-vhdx`, `build-vdi`, `build-vmdk`) each take that qcow2 and run a single `qemu-img convert` to produce the other three formats, each with its own `workflow_dispatch` input so any one of them can be rebuilt without re-running the anaconda install or the other conversions.

## How it's tested

Fast checks first. Real boots and metal last. GitHub-hosted runners build
and publish artifacts.

1. **Local package resolve.** Before spending an ISO build,
   [`scripts/podman-test-azl4-fedora.sh`](scripts/podman-test-azl4-fedora.sh)
   resolves and installroots the live kickstart package set with the real
   repo costs and excludes. Initial packaging conflicts die here.
2. **Local repo-policy check.**
   [`scripts/test-container-repos.sh`](scripts/test-container-repos.sh)
   resolves the live and installer inputs through the same repository
   policy and checks that pinned packages still come from the side the
   kickstart intends.
3. **Canary container (CI).** A small OCI image,
   [`ghcr.io/sirredbeard/azurelinux-desktop/canary`](https://github.com/sirredbeard/azurelinux-desktop/pkgs/container/azurelinux-desktop%2Fcanary),
   is built from the same repo priority rules, project RPMs, and
   side-loads as the images (including .NET 11 and vendor tools). It is
   not a desktop. No GNOME, no GDM. The release workflow builds it, and
   [`release.yml`](.github/workflows/release.yml) builds and tests it on every full
   release, and on a manual canary-only dispatch.
   [`scripts/test-canary-container.sh`](scripts/test-canary-container.sh)
   runs inside the published image: `dnf` update/upgrade, Azure Linux and
   Fedora origin checks, project tool versions, the preinstalled Microsoft
   Copilot Flatpak plus Pages remote reachability, and a couple of sample
   Flatpaks from Flathub.
4. **Filesystem checks on built media.** After an ISO or disk image
   lands, the validate helpers under [`scripts/`](scripts/) inspect layout,
   boot files, and package snapshots without needing a full GUI session.
5. **Local QEMU boots.** Release artifacts are booted here with real UEFI
   (OVMF) and KVM when available.
   [`scripts/qemu-test-live-iso.sh`](scripts/qemu-test-live-iso.sh) and
   [`scripts/qemu-test-install-iso.sh`](scripts/qemu-test-install-iso.sh)
   open a GTK window for manual desktop and installer QA.
   [`scripts/qemu-test-disk-image.sh`](scripts/qemu-test-disk-image.sh) and
   [`scripts/test-boot-smoke.sh`](scripts/test-boot-smoke.sh) cover the
   qcow2 path headless or with a window. Bluetooth USB passthrough has
   been exercised in QEMU with a real headset.
6. **Bare metal.** Nested dual-boot install on real hardware is used for
   Wi-Fi, Bluetooth, and other laptop drivers. Those paths need the
   project modules described under
   [Desktop hardware modules (x86_64)](#desktop-hardware-modules-x86_64).
   Notes live in [`findings/`](findings/).

## What else

I recorded findings, lessons learned, and the gotchas I hit in
[`findings/`](findings/). Read those notes yourself, or point an LLM at them.

All [scripts](scripts/), [kickstart files](kickstart/), and
[KIWI / installer config](kiwi/) live in this repo.

### Desktop hardware modules (x86_64)

Azure Linux 4.0 on **x86_64** turns several desktop drivers off in the
stock cloud kernel. Fine for many VMs. Rough on a laptop: no USB
keyboard/mouse path, a USB stick cannot present the live or installer
root, Intel Wi-Fi never binds, ALSA/HDA never loads, Bluetooth has no
kernel stack, UVC cameras stay dark, Type-C/UCSI docking hooks are
missing, and ThinkPad platform keys/LEDs need `thinkpad_acpi`. aarch64
already has more of this in-tree. On x86_64, `cfg80211`/`mac80211` and
parts of media/videobuf2 stay as modules; the vendor pieces under
`CONFIG_WLAN`, `CONFIG_SOUND`, `CONFIG_BT`, `CONFIG_MEDIA_USB_SUPPORT`,
`CONFIG_TYPEC`, and `CONFIG_THINKPAD_ACPI` are what this project rebuilds
out of tree.

This project builds out-of-tree modules against each exact Azure
`kernel-devel` release and publishes a small DNF repo on
[GitHub Pages](https://sirredbeard.github.io/azurelinux-desktop/repo/):

* `azurelinux-desktop-usbhid-kmod` - `usbhid.ko`
* `azurelinux-desktop-usb-storage-kmod` - `usb-storage.ko` and `uas.ko`
* `azurelinux-desktop-iwlwifi-kmod` - `iwlwifi.ko`, `iwlmvm.ko`,
  `iwldvm.ko`, `iwlmld.ko`
* `azurelinux-desktop-sound-kmod` - ALSA core, Intel HDA, common
  codecs, USB audio
* `azurelinux-desktop-bluetooth-kmod` - Bluetooth core + `btusb` and
  Intel/Realtek/Broadcom/MediaTek helpers
* `azurelinux-desktop-uvc-kmod` - `uvcvideo.ko`
* `azurelinux-desktop-thinkpad-kmod` - `thinkpad_acpi.ko`
* `azurelinux-desktop-typec-kmod` - `typec.ko`, `typec_ucsi.ko`,
  `ucsi_acpi.ko`
* `azurelinux-desktop-policy` - couples every sibling kmod RPM to the
  matching `kernel-core` so a kernel-only update cannot leave you
  without desktop hardware

Userspace/firmware stay on Azure packages where they exist:
`iwlwifi-*-firmware`, `intel-audio-firmware`, `alsa-ucm`, `bluez`,
`NetworkManager-bluetooth`.

Build and publish:

* [`.github/workflows/publish-desktop-kmods.yml`](.github/workflows/publish-desktop-kmods.yml)
* [`scripts/build-desktop-kmods.sh`](scripts/build-desktop-kmods.sh)

Further reading:

* [`findings/out-of-tree-usb-kmods-pages.md`](findings/out-of-tree-usb-kmods-pages.md) - pipeline, upstream checks, anti-orphan policy
* [`findings/intel-laptop-host-vs-azl-drivers.md`](findings/intel-laptop-host-vs-azl-drivers.md) - host-vs-image hardware scorecard
* [`findings/plan-close-desktop-driver-gaps.md`](findings/plan-close-desktop-driver-gaps.md) - wave plan
* [`findings/azure-kernel-usbhid-kmod.md`](findings/azure-kernel-usbhid-kmod.md) - HID detail
* [`findings/usb-storage-missing-initrd.md`](findings/usb-storage-missing-initrd.md) - stick boot / storage
* [`findings/wifi-missing-on-bare-metal.md`](findings/wifi-missing-on-bare-metal.md) - Wi-Fi / `CONFIG_WLAN`

Secure Boot note: These are project-built modules, not signed by the
Azure kernel key.

## How do I use this

Every release is built straight from this repo's kickstart or kiwi files through
the GitHub Actions workflows linked above, so it can always be reproduced from
source. The nightly publication builds the live ISO, all live VM image
formats, the installer ISO, and the canary container from the current default
branch. It removes the preceding release, tags, and canary container versions
first. There is intentionally only one current release, not an archive of
old builds. Grab it from
[Releases](https://github.com/sirredbeard/azurelinux-desktop/releases).

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

Every asset runs well over GitHub's 2 GiB per-asset cap on releases, so it ships as split parts plus a `.sha256` manifest, and VHDX/VDI/VMDK also ship 7z-compressed on top (qemu-img only compresses qcow2 natively). The script handles all of that for you - downloading every part, reassembling, verifying, and decompressing, using [`aria2c`](https://aria2.github.io/) if it's on PATH for faster downloads, falling back to `Invoke-WebRequest` otherwise. `-OutputDirectory <path>` and `-KeepParts` combine with any of the flags above. 

See [`scripts/Get-AzureLinuxDesktop.ps1`](scripts/Get-AzureLinuxDesktop.ps1) for the full flag reference, more example invocations, and why assets are packaged this way.

On Linux or macOS, download the parts and the manifest by hand from the Releases page, then reassemble and verify with:

```bash
cat azurelinux-desktop-live.iso.split.*.part > azurelinux-desktop-live.iso
sha256sum -c azurelinux-desktop-live.iso.sha256
```

VHDX, VDI, and VMDK reassemble to a `.7z` instead of the disk image itself, so add one more step after the checksum passes:

```bash
cat azurelinux-desktop-live.vhdx.7z.split.*.part > azurelinux-desktop-live.vhdx.7z
sha256sum -c azurelinux-desktop-live.vhdx.7z.sha256
7z x azurelinux-desktop-live.vhdx.7z
```

[`scripts/qemu-test-live-iso.sh`](scripts/qemu-test-live-iso.sh) boots the reassembled live ISO with `-cpu host`, a QEMU USB tablet, and a real GTK window, so you can actually watch the desktop and test pointer input instead of squinting at serial output. The USB tablet is deliberate: it exercises the image's project-provided `usbhid` module rather than QEMU's default PS/2 mouse path. Set `AZL_QEMU_INPUT_DEVICE` to `usb-mouse`, `virtio-tablet`, or `virtio-mouse` to try another input path.

```bash
./scripts/qemu-test-live-iso.sh /path/to/azurelinux-desktop-live.iso
```

### Using the installer ISO

The installer is **text-mode Anaconda**, same as Microsoft's own Azure
Linux installer media. It is not a graphical desktop installer.

What you will see:

1. Boot the ISO. A small live environment comes up.
2. You set an **administrator username and password** first.
3. Anaconda then launches for the rest of the install.
4. **Storage starts incomplete on purpose.** Disk partitioning is left to
   Anaconda's interactive TUI. You pick the target disk, layout, and
   optional encryption yourself. There is no autopart kickstart that
   silently wipes a disk for you.
5. Language, time zone, and similar spokes ship with defaults. Change them
   if you care. Storage is the spoke that blocks **begin installation**
   until you finish it.
6. The package payload installs from the offline repo on the ISO. No
   network is required for that step.

After install, reboot into the new system and sign in with the admin
account you created.

[`scripts/qemu-test-install-iso.sh`](scripts/qemu-test-install-iso.sh) boots
the installer ISO in QEMU with a persistent qcow2 target disk:

```bash
./scripts/qemu-test-install-iso.sh /path/to/azurelinux-desktop-install.iso
```

[`scripts/qemu-test-disk-image.sh`](scripts/qemu-test-disk-image.sh) boots a qcow2/VHDX disk image directly (headless, serial console, real UEFI/OVMF firmware, `-snapshot` by default so it never modifies the artifact):

```bash
./scripts/qemu-test-disk-image.sh /path/to/azurelinux-desktop-live.qcow2
```

The `-Kvm`/`-Hyperv`/`-VirtualBox`/`-VMWare` disk images all skip the install step entirely - boot the qcow2 straight in QEMU/KVM, attach the VHDX to a Hyper-V Generation 2 VM, attach the VDI to a VirtualBox VM, or attach the VMDK to a VMware Workstation/Player VM (all UEFI-only, same as the installed system itself), and you're at the desktop with no Anaconda run needed. All four start from the same grown qcow2. VHDX, VDI, and VMDK are produced with `qemu-img convert` only. This project boot-tests the qcow2 path. The other three formats are not boot-tested here yet (no Hyper-V, VirtualBox, or VMware in this environment on purpose), so treat them as best-effort container conversions until someone runs them on the real hypervisor.

Real hardware follows the same media path once you burn or flash the live or
installer ISO. Dual-boot on bare metal is already being used for development;
treat a full-disk install as destructive and unforgiving.

### Default accounts

The live ISO and pre-built disk images autologin as Fedora-style `liveuser`
(no password, passwordless `sudo`). Nothing to type. They are throwaway test
images.

On the installer ISO, there is no fixed account. You set the administrator
username and password in the text installer before the payload runs.

## Where do I get help

This is a one-person experiment, not a supported project. Open an issue if
something here is wrong, or if you have found a fix to one of the open
conflicts. I would genuinely like to know. Do not expect support running this
on your own hardware.

## License

Code original to this repository is MIT licensed. The built images pull in
Azure Linux, Fedora and GNOME, PowerShell, Visual Studio Code Insiders,
Microsoft Edge Canary, .NET, GitHub CLI, GitHub Desktop, GitHub Copilot CLI,
GitHub Copilot, the unofficial Microsoft Copilot Flatpak, and edit, each under its own license - see
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
