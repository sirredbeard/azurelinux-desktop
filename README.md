# Azure Linux Desktop Proof of Concept

<img width="1197" height="836" alt="Screenshot From 2026-07-17 18-01-10" src="https://github.com/user-attachments/assets/2df0ccfc-2cf4-43fa-b150-83319ea9d07d" />

This puts a real GNOME desktop on top of Microsoft's [Azure Linux 4.0](https://github.com/microsoft/azurelinux).

This is the bare metal follow-up to [Azure Linux Desktop: a Build 2026 mashup of wslc, WinUI Reactor, and Azure Linux 4.0](https://www.boxofcables.dev/azure-linux-desktop-a-build-2026-mashup-of-wslc-winui-reactor-and-azure-linux-4-0/), the original concept, which ran the same idea as a themed session inside wslc, inside a .NET app.

This is a personal side project, explored for fun. **It is not affiliated with, sponsored by, or endorsed by Microsoft, the Fedora Project, Red Hat, the GNOME Foundation, or GitHub.** The package mixing required to accomplish this *will inevitably result in broken dependencies*. Be prepared to handle that. 

**I do not recommend running this in production.** That's why live ISOs and VM images are available for you to explore this. An installer ISO is available if you dare to install on bare metal, but only on a machine you can sacrifice, do not install this as your daily driver. Some basic testing is done on the outgoing images. A minimal 'canary' container is built to test the repo mixing and do a handful of tasks, that's it.

Third-party scripts/RPM packages are very likely to get confused by the repo mixing here. I strongly encourage using [Flatpak](https://flatpak.org/) for applications. Flatpak is configured here with Flathub and tested in the minimal 'canary' container.

**This project is x86_64-focused for now.** The live ISO, installer ISO, and
disk images target Intel-class machines: chipset, GPU, and audio paths that
show up on typical Intel laptops and desktops are what get exercised. aarch64
is on the wishlist (I want to get there), but it is not a supported image
target yet. Out-of-tree desktop drivers this repo publishes today cover the
x86_64 gaps Azure's stock kernel leaves open (USB HID/storage, Intel
Wi-Fi, ALSA HDA/USB audio, Bluetooth, UVC cameras, ThinkPad ACPI, and
USB Type-C/UCSI). If you need another driver for real hardware, [open an
issue](https://github.com/sirredbeard/azurelinux-desktop/issues) and say what
chip it is. Willing to add modules the same way when the case is clear.

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
* [GitHub Desktop](https://github.com/shiftkey/desktop)
* [PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/linux-overview?view=powershell-7.6) (default shell)
* [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux?view=azure-cli-latest&pivots=dnf)
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
* **Desktop hardware kmods (x86_64 only).** Azure's stock x86_64 kernel
  leaves USB HID/storage, WLAN, SOUND, BT, MEDIA_USB, TYPEC, and
  THINKPAD_ACPI off. aarch64 already builds more of this in-tree. This
  repo builds matching out-of-tree modules (USB HID/storage, Intel
  Wi-Fi, ALSA HDA/USB audio, Bluetooth, UVC, thinkpad_acpi, Type-C/UCSI),
  publishes them from
  [GitHub Pages](https://sirredbeard.github.io/azurelinux-desktop/repo/)
  via
  [`publish-desktop-kmods.yml`](.github/workflows/publish-desktop-kmods.yml),
  and pulls them into the live ISO, disk images, installer ISO, and
  canary through a policy RPM so the kernel cannot orphan the
  modules. Firmware and userspace still come from Azure packages
  (`iwlwifi-*-firmware`, `intel-audio-firmware`, `alsa-ucm`, `bluez`,
  `NetworkManager-bluetooth`). How that pipeline works:
  [`findings/out-of-tree-usb-kmods-pages.md`](findings/out-of-tree-usb-kmods-pages.md).

## Why does this exist

[Azure Linux](https://github.com/microsoft/azurelinux) is server- and cloud-native by design, and [Fedora](https://fedoraproject.org/) always gets the latest GNOME. Azure Linux 4.0's userland turns out to be close enough to Fedora that a real, current GNOME desktop sourced from Fedora can be layered on top of it with the right repo priority setup.

The result: GNOME, PowerShell, Azure CLI, Visual Studio Code Insiders, Microsoft Edge Canary, GitHub CLI, GitHub Desktop, GitHub Copilot (GUI and CLI), .NET, and Flathub/Flatpak support, all running on Azure Linux 4.0's actual base.

### Where the packages actually come from

The base is Azure Linux. Kernel, systemd, NetworkManager, bluez, fwupd-efi, linux-firmware, coreutils, util-linux, cryptsetup, and the rest of the system layer all resolve to Azure Linux. `glibc` has to come from Fedora: `gtk4` needs newer symbol versioning than AZL4's glibc ships, it's the ABI floor the rest of the GUI stack sits on. A few other packages (`wpa_supplicant`, `fwupd`/`fwupd-efi`, `fuse3`) must come from Fedora or ship side by side.

Current package-by-package listings are in [`findings/live-package-list.txt`](findings/live-package-list.txt) and [`findings/installer-package-list.txt`](findings/installer-package-list.txt). Successful live and installer ISO builds on Actions refresh those files automatically.

Microsoft and GitHub products are not version-pinned in the kickstarts. Each build pulls whatever is current from the Microsoft yum repos (PowerShell, Azure CLI, VS Code Insiders, Edge Canary), the GitHub CLI repo, the GitHub Desktop mirror, and GitHub Releases for Copilot GUI/CLI and `microsoft/edit`. .NET 11 is not on the yum feeds yet (preview), so builds side-load the current linux-x64 SDK tarball from Microsoft's release metadata / download page. Side-loads fail the build if latest cannot be resolved. Build logs snapshot the yum NEVRAs and the resolved .NET 11 version that day.

Build/test helpers live under [`scripts/`](scripts/) with a short catalog in [`scripts/README.md`](scripts/README.md).

## How it's built

There are two separate ISOs here, built two different ways, on purpose.

**The live ISO** (`kickstart/azurelinux-desktop-live.ks`) is what you boot to try the desktop without touching a disk. It's fed to [`lorax`](https://github.com/weldr/lorax) and `livemedia-creator --no-virt`, which runs a real `anaconda --dirinstall` package install against Azure Linux's own repos plus a pinned Fedora repo for GNOME and everything GNOME needs, then squashes the result into a live-bootable ISO. Lorax is the right tool here because it's built specifically for producing live media, and the live ISO isn't trying to be anything else. The build runs on GitHub Actions ([`.github/workflows/build-live-iso.yml`](.github/workflows/build-live-iso.yml)) from a clean runner every time.

**The installer ISO** (`kiwi/`) is what you boot to actually install the desktop to a disk. **Standard installation erases, repartitions, and installs Azure Linux Desktop onto the entire selected target disk. It is destructive: back up data and disconnect every disk you do not intend to erase before continuing.** This one is built with [KIWI-NG](https://github.com/OSInside/kiwi), because that's what Microsoft's own real Azure Linux 4.0 installer ISO is built with. I looked at `microsoft/azurelinux`'s own `base/images/vm-iso-installer/` directory and copied its approach: a `.kiwi` image description bootstraps a minimal live-boot environment (just enough to run a text-mode Anaconda, nothing desktop-related), `config.sh` downloads every real target package plus dependencies into an offline repo baked onto the ISO, and a kickstart template gets its package list filled in from that same list at build time. The kickstart installs entirely offline, no network needed at install time, same as the real thing. What's different from upstream is the package list itself (the full GNOME + Microsoft/GitHub stack instead of Azure Linux's minimal cloud base) and the extra network fetches for GitHub Copilot/edit/Flathub done during that same build-time window. Account setup remains interactive, matching Azure Linux's installer templates. Full writeup of that decision in [`findings/kiwi-ng-installer-build.md`](findings/kiwi-ng-installer-build.md). The build runs on GitHub Actions too ([`.github/workflows/build-installer-iso.yml`](.github/workflows/build-installer-iso.yml)), same clean-runner-every-time approach.

**The disk images** (qcow2/VHDX/VDI/VMDK) skip the ISO/install step entirely and boot straight to a desktop. They come from the same `azurelinux-desktop-live.ks` kickstart as the live ISO, but run through `livemedia-creator --make-disk` instead of `--make-iso`, so the disk-image variant enables one extra thing the ISO doesn't need: `azl-growroot.service`, a small oneshot unit (`cloud-utils-growpart` + `xfs_growfs`) that grows the root partition/filesystem to fill whatever size the disk gets resized to after the anaconda install finishes, since Anaconda only sizes the partition to the small disk it's given at install time. `build-disk-image` ([`.github/workflows/build-live-iso.yml`](.github/workflows/build-live-iso.yml)) runs the anaconda install and produces the base qcow2; three independent jobs (`build-vhdx`, `build-vdi`, `build-vmdk`) each take that qcow2 and run a single `qemu-img convert` to produce the other three formats, each with its own `workflow_dispatch` input so any one of them can be rebuilt without re-running the anaconda install or the other conversions. Full trace of the bugs that came up building this (partition growth, VHDX losing its resize, a unit-enablement ordering bug) in [`findings/github-actions-build.md`](findings/github-actions-build.md).

Getting the live ISO's package set right took some package-resolution work, documented in [`findings/fedora-azl-repo-mixing.md`](findings/fedora-azl-repo-mixing.md):

- A curated GNOME desktop (shell, session, gdm, mutter, nautilus, the usual pieces) layered from Fedora onto Azure Linux 4.0 resolves cleanly with the right repo setup.
- Three real conflicts showed up along the way, a file collision, a version floor, and a hard ABI fork between Azure Linux's bootloader tooling and Fedora's flatpak/portal stack, each with its own fix, documented in the findings.
- Throwing Fedora's entire `workstation-product-environment` group at it in one shot does not work. Big, unpredictable package pulls surface new soname conflicts faster than you can track them.
- I also checked five alternative build architectures (systemd-sysext, bootc, systemd-nspawn desktop containers, the Universal Blue/Bluefin model, distrobox app export) to see if any of them sidestep the RPM-level conflicts instead of just moving them around. None of them do, though bootc is worth adopting later for reproducibility, and distrobox is genuinely useful for anything added after the base desktop. Full writeup in [`findings/fedora-azl-repo-mixing.md`](findings/fedora-azl-repo-mixing.md).

## How it's tested

Five stages, each one a higher bar than the last:

1. **podman, full resolve/installroot.** Before anything touches lorax/kiwi or a real ISO build, the full package set gets resolved and installed into a throwaway root filesystem with `dnf --installroot`, using [`scripts/podman-test-azl4-fedora.sh`](scripts/podman-test-azl4-fedora.sh). It parses the real repo/cost/excludepkgs setup and `%packages` list straight out of `kickstart/azurelinux-desktop-live.ks`, so it always tests what the live ISO would actually resolve, not a hand-maintained copy of it. Fast, cheap, and it is where every packaging conflict so far actually got caught, before a full ISO build was ever spent on it.
2. **podman, repo-origin canary.** [`scripts/test-container-repos.sh`](scripts/test-container-repos.sh) resolves the union of the real live and installer package inputs through the kickstart-parsed repository policy, then checks the packages the policy explicitly places on either side. It is the quick "did repo policy drift?" check for iteration, not a second desktop build.
3. **Published canary container.** Every published canary container
   runs `dnf5 update` and `upgrade`, installs representative Azure and Fedora
   packages, verifies their origins, records the custom project-tool versions,
   and installs Firefox plus Flatseal from Flathub. Its DNF,
   repository, origin, version, and Flatpak logs are retained as Actions
   artifacts.
4. **Local QEMU/OVMF artifact checks.** The QEMU helpers in
   [`scripts/`](scripts/) boot downloaded release artifacts with real UEFI
   firmware and hardware acceleration when it is available. GitHub-hosted
   runners are not used for guest boot testing.
5. **local QEMU/KVM, real window.** Once the automated headless checks look sane, the actual built ISO can be booted locally in QEMU/KVM with a real GTK window. [`scripts/qemu-test-live-iso.sh`](scripts/qemu-test-live-iso.sh) boots the live ISO for manual desktop QA. [`scripts/qemu-test-install-iso.sh`](scripts/qemu-test-install-iso.sh) does the same for the installer ISO against a persistent qcow2 target disk.
6. **Bare metal.** Nested dual-boot install on real hardware is used for
   driver and Bluetooth work. Wi-Fi and BT need the project kmod packages.
   See [`findings/`](findings/) for the current notes.

## What else

I recorded findings, lessons learned, and the gotchas I hit in
[`findings/`](findings/). Read those notes yourself, or point an LLM at them.

All [scripts](scripts/), [kickstart files](kickstart/), and
[KIWI / installer config](kiwi/) live in this repo.

### Desktop hardware modules (x86_64)

Short version is under [Errata](#errata). Longer version:

Azure Linux 4.0 on **x86_64** turns several desktop drivers off in the
stock cloud kernel. Fine for many VMs. Bad for a laptop: no USB
keyboard/mouse path, a USB stick cannot present the live or installer
root, Intel Wi-Fi never binds, ALSA/HDA never loads, Bluetooth has no
kernel stack, UVC cameras stay dark, Type-C/UCSI docking hooks are
missing, and ThinkPad platform keys/LEDs need `thinkpad_acpi`. aarch64
already has more of this in-tree. On x86_64, `cfg80211`/`mac80211` and
parts of media/videobuf2 stay as modules; the vendor pieces under
`CONFIG_WLAN`, `CONFIG_SOUND`, `CONFIG_BT`, `CONFIG_MEDIA_USB_SUPPORT`,
`CONFIG_TYPEC`, and `CONFIG_THINKPAD_ACPI` are what we rebuild OOT.

This project builds out-of-tree modules against each exact Azure
`kernel-devel` release and publishes a small DNF repo on
[GitHub Pages](https://sirredbeard.github.io/azurelinux-desktop/repo/)
(that URL is a browsable package index; the site root is
[here](https://sirredbeard.github.io/azurelinux-desktop/)):

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
[`.github/workflows/publish-desktop-kmods.yml`](.github/workflows/publish-desktop-kmods.yml)
and [`scripts/build-desktop-kmods.sh`](scripts/build-desktop-kmods.sh).

How the pipeline works, upstream checks, and anti-orphan policy:
[`findings/out-of-tree-usb-kmods-pages.md`](findings/out-of-tree-usb-kmods-pages.md).
Host-vs-image hardware scorecard (Intel-class laptop probe):
[`findings/intel-laptop-host-vs-azl-drivers.md`](findings/intel-laptop-host-vs-azl-drivers.md).
Wave plan:
[`findings/plan-close-desktop-driver-gaps.md`](findings/plan-close-desktop-driver-gaps.md).

HID detail:
[`findings/azure-kernel-usbhid-kmod.md`](findings/azure-kernel-usbhid-kmod.md).
Stick boot / storage detail:
[`findings/usb-storage-missing-initrd.md`](findings/usb-storage-missing-initrd.md).
Wi-Fi / `CONFIG_WLAN` detail:
[`findings/wifi-missing-on-bare-metal.md`](findings/wifi-missing-on-bare-metal.md).

Secure Boot note: these are project-built modules, not signed by the
Azure kernel key.

## How do I use this

Every release is built straight from this repo's kickstart/kiwi files through
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

Every asset runs well over GitHub's 2 GiB per-asset cap on releases, so it ships as split parts plus a `.sha256` manifest, and VHDX/VDI/VMDK also ship 7z-compressed on top (qemu-img only compresses qcow2 natively). The script handles all of that for you - downloading every part, reassembling, verifying, and decompressing - using [`aria2c`](https://aria2.github.io/) if it's on PATH for faster downloads, falling back to `Invoke-WebRequest` otherwise. `-OutputDirectory <path>` and `-KeepParts` combine with any of the flags above. See [`scripts/Get-AzureLinuxDesktop.ps1`](scripts/Get-AzureLinuxDesktop.ps1) for the full flag reference, more example invocations, and why assets are packaged this way.

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

[`scripts/qemu-test-live-iso.sh`](scripts/qemu-test-live-iso.sh) boots the reassembled live ISO with `-cpu host`, a QEMU USB tablet, and a real GTK window, so you can actually watch the desktop and test pointer input instead of squinting at serial output. The USB tablet is deliberate: it exercises the image's project-provided `usbhid` module rather than QEMU's default PS/2 mouse path. Set `AZL_QEMU_INPUT_DEVICE` to `usb-mouse`, `virtio-tablet`, or `virtio-mouse` to try another input path. See [USB HID, mass storage, and Intel Wi-Fi (x86_64)](#usb-hid-mass-storage-and-intel-wi-fi-x86_64) above.

```bash
./scripts/qemu-test-live-iso.sh /path/to/azurelinux-desktop-live.iso
```

### Using the installer ISO

The installer is **text-mode Anaconda**, driven by a kickstart built into the
ISO (same idea as Microsoft's own Azure Linux installer media). It is not a
graphical desktop installer.

What it does for you:

1. Boots a small live environment and starts the offline installer.
2. Asks for an **administrator username and password** (interactive, like
   upstream Azure Linux templates).
3. Installs the full package set from the offline repo on the ISO. No
   network is required at install time for that payload.

What you still configure by hand in the TUI before you can press **`b`**
(begin installation):

* **Storage** is required. Pick the target disk, partitioning scheme, and
  optional LUKS. **Standard install erases and repartitions the selected
  disk.** Back up first. Disconnect every drive you do not intend to wipe.
* Language, time zone, and similar spoke values ship with defaults. Change
  them if you care; storage is the spoke that blocks "begin installation"
  when it is still marked incomplete.

After install, reboot into the new system and sign in with the admin account
you created.

[`scripts/qemu-test-install-iso.sh`](scripts/qemu-test-install-iso.sh) boots
the installer ISO in QEMU with a persistent qcow2 target disk:

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

The local QEMU helpers remain available for focused boot and installer checks.
They are not part of a GitHub Actions guest-testing workflow.

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
