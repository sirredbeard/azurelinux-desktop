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
| [`usb-storage-missing-initrd.md`](usb-storage-missing-initrd.md) | USB storage OOT in initrd |
| [`gnome-software-flatpak-empty.md`](gnome-software-flatpak-empty.md) | Software catalog empty until appstream |
| [`gnome-software-catalog-preseed.md`](gnome-software-catalog-preseed.md) | Preseed AppStream so first open is not `…` tiles |
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
| [`bluetooth-hci-timeout-thinkpad.md`](bluetooth-hci-timeout-thinkpad.md) | BT HCI fix; QEMU + bare-metal confirmed |
| [`wifi-missing-on-bare-metal.md`](wifi-missing-on-bare-metal.md) | Wi-Fi OOT kmod; bare-metal confirmed |
| [`out-of-tree-usb-kmods-pages.md`](out-of-tree-usb-kmods-pages.md) | OOT kmods on Pages; RPM GPG signing with shared key |
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
| [`gnome-software-catalog-preseed.md`](gnome-software-catalog-preseed.md) | Bake Flathub/RPM AppStream for first Software open |
| [`installed-grub-skip-menu.md`](installed-grub-skip-menu.md) | Installed AZL GRUB: timeout 0, straight to Plymouth |
| [`flatpak-untrusted-non-gpg-remote.md`](flatpak-untrusted-non-gpg-remote.md) | System Flatpak: GPG + polkit; 0.1.15 sign-before-deltas; canary gpg-verify |
| [`gpg-key-rotation.md`](gpg-key-rotation.md) | Shared Flatpak+RPM OpenPGP key; `GPG_*` secrets; Pages resign order |
| [`rpm-gpgcheck-vendor-keys.md`](rpm-gpgcheck-vendor-keys.md) | Stop `gpgcheck=0` on Fedora/MS/GitHub; vendored keys |
| [`copilot-desktop-gtk-webkit-performance.md`](copilot-desktop-gtk-webkit-performance.md) | Copilot Flatpak WebKit RAM, KMSI inject, low-memory profile |
| [`github-copilot-bundled-git-libcurl.md`](github-copilot-bundled-git-libcurl.md) | GitHub Copilot GUI: force system git (LOCAL_GIT_DIRECTORY); metal clone OK |
| [`passwordless-sudo-wheel.md`](passwordless-sudo-wheel.md) | Wheel NOPASSWD on live and installed images |
| [`missing-color-emoji-fonts.md`](missing-color-emoji-fonts.md) | Noto Color Emoji missing; GitHub reactions tofu in Edge |
| [`rpmdb-permissions.md`](rpmdb-permissions.md) | rpmdb root-owned is correct; mode should be 0644 not 0600 |
| [`intel-hw-video-accel.md`](intel-hw-video-accel.md) | T470s HD 520: Mesa/Vulkan OK; need RPM Fusion intel-media-driver |
| [`h264-intel-media-stack.md`](h264-intel-media-stack.md) | Full Mesa/Vulkan/iHD/gst-vaapi/mp3/H.264 on live, installer, canary |
| [`rpm-gpg-keys-on-target.md`](rpm-gpg-keys-on-target.md) | Installer missed copying vendor RPM GPG keys onto target root |

## Build, packages, parity

| File | Topic |
| --- | --- |
| [`live-iso-erofs-evaluation.md`](live-iso-erofs-evaluation.md) | EROFS vs SquashFS for live ISO (issue #4) |
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
| [`bare-metal-inventory.md`](bare-metal-inventory.md) | First in-OS session: hardware, packages, repos, tools, journal noise |
| [`dual-boot-nested-host-partition.md`](dual-boot-nested-host-partition.md) | Nested install on a container partition |
| [`qemu-gnome-interactive-testing.md`](qemu-gnome-interactive-testing.md) | QEMU Wayland / SSH testing quirks |
| [`hypervisor-mouse-ps2-boxes.md`](hypervisor-mouse-ps2-boxes.md) | Boxes/PS/2 defaults vs AZL missing psmouse |
| [`hypervisor-guest-agents.md`](hypervisor-guest-agents.md) | Ship-all spice/qemu/hyperv/vmware/vbox agents |
| [`test-suite.md`](test-suite.md) | What the scripts under `/scripts` cover |

