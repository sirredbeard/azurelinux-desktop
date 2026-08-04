# Findings index

Institutional memory for this project. One markdown file per issue or durable
topic. When something is fixed, keep the technical note here and mark
**Status:** clearly. Do not recreate megafiles like `final_polish.md`.

When a log line proves a point, paste the short excerpt into the topic file
itself. Do not keep a separate log archive under `findings/`.

Package snapshots:

* [`live-package-list.txt`](live-package-list.txt) — last successful live ISO resolve
* [`installer-package-list.txt`](installer-package-list.txt) — last successful installer resolve

CI refreshes those on successful builds via
[`scripts/ci-commit-package-list.sh`](../scripts/ci-commit-package-list.sh).

## How to use this directory (humans and agents)

1. Search by symptom (`HCI`, `Plymouth`, `flatpak`, `GRUB`, `kmod`).
2. Open the matching file. Read **Status** first.
3. When you learn something new, update the topic file (or add one) before the
   session ends. Prefer short plain English. Put only the failure or success
   lines that matter in the file, not full CI dumps.

## Still worth re-checking on metal

| File | Topic |
| --- | --- |
| [`plymouth-animation-duration.md`](plymouth-animation-duration.md) | Short splash on fast boots |
| [`wifi-missing-on-bare-metal.md`](wifi-missing-on-bare-metal.md) | Wi-Fi OOT kmod; re-check after kernel bumps |
| [`bluetooth-hci-timeout-thinkpad.md`](bluetooth-hci-timeout-thinkpad.md) | BT layout fix; QEMU verified |
| [`usb-storage-missing-initrd.md`](usb-storage-missing-initrd.md) | USB storage OOT in initrd |
| [`gnome-software-flatpak-empty.md`](gnome-software-flatpak-empty.md) | Software catalog empty until appstream |
| [`installed-grub-missing-efi-modules.md`](installed-grub-missing-efi-modules.md) | Text GRUB without EFI modules on `/boot` |
| [`systemd-modules-load-snd-hda.md`](systemd-modules-load-snd-hda.md) | modules-load sound unit noise |

## Boot and Plymouth

| File | Topic |
| --- | --- |
| [`plymouth-boot-animation.md`](plymouth-boot-animation.md) | Theme packing, serial console, early KMS |
| [`first-boot-plymouth-relabel.md`](first-boot-plymouth-relabel.md) | Quiet first-boot grow + SELinux under Plymouth |
| [`uefi-bdsdxe-text-before-plymouth.md`](uefi-bdsdxe-text-before-plymouth.md) | Firmware text before splash |
| [`installer-grub-test-media.md`](installer-grub-test-media.md) | Media check GRUB entry |
| [`efi-vendor-path-azurelinux.md`](efi-vendor-path-azurelinux.md) | `EFI/fedora` vs `EFI/azurelinux` |

## Desktop drivers and kmods

| File | Topic |
| --- | --- |
| [`out-of-tree-usb-kmods-pages.md`](out-of-tree-usb-kmods-pages.md) | Pages repo + policy RPM pipeline; **detect gate** (`build_required`, why prepare/build skip) |
| [`desktop-kmod-waves-1-5.md`](desktop-kmod-waves-1-5.md) | Sound, BT, UVC, thinkpad, typec waves |
| [`azure-kernel-usbhid-kmod.md`](azure-kernel-usbhid-kmod.md) | Early usbhid kmod writeup |
| [`intel-laptop-host-vs-azl-drivers.md`](intel-laptop-host-vs-azl-drivers.md) | Host Fedora vs nested Azure Linux driver gap |
| [`plan-close-desktop-driver-gaps.md`](plan-close-desktop-driver-gaps.md) | Original driver gap plan |
| [`pipewire-user-units-not-enabled.md`](pipewire-user-units-not-enabled.md) | Screencast / PipeWire user units |

## Desktop and apps

| File | Topic |
| --- | --- |
| [`gnome-desktop-defaults.md`](gnome-desktop-defaults.md) | dconf, wallpaper, GDM, favorites |
| [`powershell-dock-identity.md`](powershell-dock-identity.md) | PowerShell app-id / dock |
| [`dotnet-cli-first-run.md`](dotnet-cli-first-run.md) | .NET launcher and first-run noise |
| [`edit-desktop-missing.md`](edit-desktop-missing.md) | edit missing from overview |
| [`admin-default-shell-pwsh.md`](admin-default-shell-pwsh.md) | Installer admin shell |
| [`locale-conf-mode-600.md`](locale-conf-mode-600.md) | locale.conf mode breaks bash |
| [`flatpak-live-session-space.md`](flatpak-live-session-space.md) | Flatpak space on live ISO |

## Build, packages, parity

| File | Topic |
| --- | --- |
| [`fedora-azl-repo-mixing.md`](fedora-azl-repo-mixing.md) | Repo cost/priority and excludes |
| [`latest-vendor-packages.md`](latest-vendor-packages.md) | Always-latest Microsoft/GitHub tools and .NET 11 |
| [`live-iso-installer-parity.md`](live-iso-installer-parity.md) | Parity matrix across deliverables |
| [`canary-container.md`](canary-container.md) | Package-policy canary OCI image |
| [`github-actions-build.md`](github-actions-build.md) | Actions graph, lorax/disk CI lessons |
| [`release-upload-in-build-job.md`](release-upload-in-build-job.md) | In-job release upload; no parent upload-* wait on full reusable call |
| [`kiwi-ng-installer-build.md`](kiwi-ng-installer-build.md) | Installer KIWI path |
| [`anaconda-kickstart-patterns.md`](anaconda-kickstart-patterns.md) | Kickstart patterns that matter here |
| [`anaconda-nvme-cli-offline-repo.md`](anaconda-nvme-cli-offline-repo.md) | Offline nvme-cli gap |
| [`deliverable-polish-validation.md`](deliverable-polish-validation.md) | Historical polish checklist |

## Host dual-boot and testing

| File | Topic |
| --- | --- |
| [`dual-boot-nested-host-partition.md`](dual-boot-nested-host-partition.md) | Nested install on a container partition |
| [`qemu-gnome-interactive-testing.md`](qemu-gnome-interactive-testing.md) | QEMU Wayland / SSH testing quirks |
| [`test-suite.md`](test-suite.md) | What the scripts under `/scripts` cover |

