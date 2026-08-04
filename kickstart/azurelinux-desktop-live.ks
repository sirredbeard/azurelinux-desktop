# Azure Linux Desktop - live ISO / disk-image kickstart
#
# Source of truth for:
#   - Live ISO via lorax + livemedia-creator --make-iso --no-virt
#   - Pre-built disk images (qcow2/VHDX/VDI/VMDK) via --make-disk
#
# Disk images do not use a second hand-maintained kickstart. CI and
# scripts/build-qcow2-local.sh sed this file into a temporary
# azurelinux-desktop-live-disk.ks (bootloader on, xfs --grow root,
# enable azl-growroot.service, plus a small extra %post for liveuser on
# a non-live root). Do not commit that generated file.
#
# Bare-metal *installer* media is separate: kiwi/ + Anaconda
# (findings/kiwi-ng-installer-build.md). Built with Fedora tooling on
# purpose, not by rewriting Microsoft's installer ISO.
#
# Background: bare-metal follow-up to the WSL wslc/WinUI Reactor demo
# (https://www.boxofcables.dev/azure-linux-desktop-a-build-2026-mashup-of-wslc-winui-reactor-and-azure-linux-4-0/).
# Azure Linux 4.0 is close to Fedora 43 on core userland (same upstream
# lines, different build tags). It ships no desktop. This kickstart
# installs a real Azure Linux 4.0 base, then layers current GNOME and
# desktop deps from Fedora 43. Stay on that Fedora baseline: newer
# Fedora needs glibc symbols Azure Linux 4.0 does not have yet.
#
# Repo policy at install time uses dnf `cost=` on the repo lines below
# (lower cost wins). Azure base/microsoft = cost 1. Fedora / RPM Fusion =
# cost 50. The installed system's /etc/yum.repos.d files use dnf
# `priority=` the same way (1 vs 50). Fedora excludepkgs claw base/system
# names back to Azure packages. Details and conflict history:
# findings/fedora-azl-repo-mixing.md. Canary container exercises the same
# mix: findings/canary-container.md.
#
# xconfig/startxonboot + rootpw are lorax/livemedia-creator conventions.
# url is the primary install source anaconda --dirinstall wants in
# addition to the repo lines; Azure base is cost=1 so it is a fine pick.
xconfig --startxonboot
lang en_US.UTF-8
keyboard us
timezone America/New_York --utc
selinux --enforcing
firewall --enabled --ssh
url --url="https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64"
# Match the installer kickstart hostname (kiwi/azl-install.ks.in).
network --bootproto=dhcp --device=link --activate --hostname=azurelinux-desktop
rootpw --lock
# NetworkManager only, not systemd-networkd - matches lorax's
# fedora-livemedia.ks template. Do not enable both on a live image.
# ModemManager dropped from --enabled: it's not in %packages (no cellular/
# WWAN modem support requested), and anaconda hard-fails
# ("NonCriticalInstallationError: Cannot enable ... ModemManager") trying
# to enable a systemd unit for a service that was never installed - only
# list services here for units that are actually part of %packages.
services --disabled=sshd --enabled=gdm,NetworkManager,livesys,livesys-late

# Live ISO layout: single filesystem for the squashfs capture. No real
# bootloader/EFI/swap. Disk-image builds sed these three lines:
#   bootloader --location=none  -> bootloader
#   part / --size=16384         -> part / --fstype=xfs --size=16384 --grow
#   # AZL_GROWROOT_ENABLE_MARKER -> systemctl enable azl-growroot.service
bootloader --location=none
clearpart --all --initlabel
reqpart
part / --size=16384

# livemedia-creator captures after a clean shutdown (not reboot).
shutdown

# .NET SDK is side-loaded from Microsoft's linux-x64 tarball (see
# scripts/fetch-latest-thirdparty.sh + install-dotnet-sdk-tarball.sh), not
# from yum. .NET 11 preview/RC is not on packages.microsoft.com feeds
# (Microsoft docs: preview installs use the binary archive). We always take
# the current 11.0 SDK via aka.ms (preview while pre-release, GA when the
# non-preview shortlink works). Build fails if the
# tarball cannot be resolved. Never ship EOL-bound 9.x for the desktop.

# dnf5/libdnf5/dnf5daemon-server: Azure Linux ships its own dnf5 stack,
# but Fedora gnome-software needs a newer dnf5daemon-server than that
# stack provides. gnome-software only exists on Fedora here, so take the
# whole dnf5/libdnf5 family from Fedora rather than splitting it. Same
# "don't split a coupled family" rule as grub2/shim.
repo --name=azl-base --baseurl=https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64 --cost=1 --excludepkgs=hunspell-en,grub2,grub2-pc,grub2-pc-modules,grub2-efi-x64,grub2-efi-x64-modules,grub2-efi-x64-cdboot,grub2-tools,grub2-tools-extra,grub2-tools-minimal,grub2-common,shim,shim-x64,gsettings-desktop-schemas,dnf5,dnf5daemon-server,dnf5daemon-server-polkit,libdnf5,libdnf5-cli,libdnf5-plugin-actions,libdnf5-plugin-appstream,libdnf5-plugin-expired-pgp-keys,libdnf5-plugin-local
repo --name=azl-microsoft --baseurl=https://packages.microsoft.com/azurelinux/4.0/beta/microsoft/x86_64 --cost=1 --excludepkgs=hunspell-en,grub2,grub2-pc,grub2-pc-modules,grub2-efi-x64,grub2-efi-x64-modules,grub2-efi-x64-cdboot,grub2-tools,grub2-tools-extra,grub2-tools-minimal,grub2-common,shim,shim-x64,gsettings-desktop-schemas
repo --name=azl-desktop-kmods --baseurl=https://sirredbeard.github.io/azurelinux-desktop/repo --cost=1
# Claw-back excludepkgs: keep named base/system packages on Azure Linux
# even when Fedora also offers them. cost= alone does not pin ownership
# across different NEVRAs. Same list and reasoning as kiwi/config.sh
# FEDORA_EXCLUDES (glibc, wpa_supplicant, fwupd*, fuse3* deliberately
# not here - real ABI floors or no safe Azure fallback).
repo --name=fedora43 --baseurl=https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/ --cost=50 --excludepkgs=audit,audit-libs,audit-rules,bash,bluez,bluez-libs,bluez-obexd,bzip2,ca-certificates,chrony,coreutils,coreutils-common,cryptsetup,cryptsetup-libs,dbus,dbus-broker,dbus-common,dbus-daemon,dbus-libs,dbus-tools,device-mapper,device-mapper-event,device-mapper-event-libs,device-mapper-libs,device-mapper-persistent-data,diffutils,dosfstools,e2fsprogs,e2fsprogs-libs,efibootmgr,findutils,firewalld,firewalld-filesystem,gawk,gawk-all-langpacks,grep,gzip,hwdata,iproute,iputils,kbd,kbd-legacy,kbd-misc,kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra,kmod,less,less-color,libaio,libblkid,libcom_err,libfdisk,liblastlog2,libmount,libnm,libsmartcols,libuuid,linux-firmware,linux-firmware-whence,lvm2,lvm2-libs,microcode_ctl,ModemManager-glib,mtools,ncurses,ncurses-base,ncurses-libs,NetworkManager,NetworkManager-libnm,NetworkManager-team,NetworkManager-tui,NetworkManager-wifi,NetworkManager-bluetooth,alsa-ucm,alsa-lib,openssh,openssh-clients,openssh-server,patch,polkit,polkit-libs,procps-ng,python3-audit,python3-firewall,python3-libmount,sed,setup,shadow-utils,sudo,sudo-python-plugin,systemd,systemd-boot-unsigned,systemd-container,systemd-libs,systemd-networkd,systemd-pam,systemd-resolved,systemd-shared,systemd-sysusers,systemd-udev,tar,util-linux,util-linux-core,vim-data,vim-minimal,xz,xz-libs,amd-gpu-firmware,amd-ucode-firmware,atheros-firmware,brcmfmac-firmware,cirrus-audio-firmware,intel-audio-firmware,intel-gpu-firmware,mt7xxx-firmware,nvidia-gpu-firmware,nxpwireless-firmware,qcom-wwan-firmware,realtek-firmware,tiwilink-firmware,iwlegacy-firmware,iwlwifi-dvm-firmware,iwlwifi-mld-firmware,iwlwifi-mvm-firmware
repo --name=fedora43-updates --baseurl=https://dl.fedoraproject.org/pub/fedora/linux/updates/43/Everything/x86_64/ --cost=50 --excludepkgs=audit,audit-libs,audit-rules,bash,bluez,bluez-libs,bluez-obexd,bzip2,ca-certificates,chrony,coreutils,coreutils-common,cryptsetup,cryptsetup-libs,dbus,dbus-broker,dbus-common,dbus-daemon,dbus-libs,dbus-tools,device-mapper,device-mapper-event,device-mapper-event-libs,device-mapper-libs,device-mapper-persistent-data,diffutils,dosfstools,e2fsprogs,e2fsprogs-libs,efibootmgr,findutils,firewalld,firewalld-filesystem,gawk,gawk-all-langpacks,grep,gzip,hwdata,iproute,iputils,kbd,kbd-legacy,kbd-misc,kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra,kmod,less,less-color,libaio,libblkid,libcom_err,libfdisk,liblastlog2,libmount,libnm,libsmartcols,libuuid,linux-firmware,linux-firmware-whence,lvm2,lvm2-libs,microcode_ctl,ModemManager-glib,mtools,ncurses,ncurses-base,ncurses-libs,NetworkManager,NetworkManager-libnm,NetworkManager-team,NetworkManager-tui,NetworkManager-wifi,NetworkManager-bluetooth,alsa-ucm,alsa-lib,openssh,openssh-clients,openssh-server,patch,polkit,polkit-libs,procps-ng,python3-audit,python3-firewall,python3-libmount,sed,setup,shadow-utils,sudo,sudo-python-plugin,systemd,systemd-boot-unsigned,systemd-container,systemd-libs,systemd-networkd,systemd-pam,systemd-resolved,systemd-shared,systemd-sysusers,systemd-udev,tar,util-linux,util-linux-core,vim-data,vim-minimal,xz,xz-libs,amd-gpu-firmware,amd-ucode-firmware,atheros-firmware,brcmfmac-firmware,cirrus-audio-firmware,intel-audio-firmware,intel-gpu-firmware,mt7xxx-firmware,nvidia-gpu-firmware,nxpwireless-firmware,qcom-wwan-firmware,realtek-firmware,tiwilink-firmware,iwlegacy-firmware,iwlwifi-dvm-firmware,iwlwifi-mld-firmware,iwlwifi-mvm-firmware
# aznfs (Azure Files NFS mount helper) rides along in ms-prod's dependency
# graph even though nothing we actually want (powershell) needs it for real -
# it's a pure Azure-cloud tool with a %pre scriptlet that hard-fails without
# /proc mounted, and has zero purpose on a bare-metal desktop, so excluded.
# mdatp (Microsoft Defender for Endpoint) started showing up transitively
# from the same repo between builds (upstream repo drift, nothing in this
# kickstart asks for it) and its own postinstall scriptlet fails outright
# in a %post --dirinstall chroot (`[Errno 2] No such file or directory:
# '/usr/sbin/load_policy'` - it wants a live SELinux userspace that isn't
# present in this build environment). Also just not something a personal
# desktop proof of concept wants installed anyway - excluded.
repo --name=ms-prod --baseurl=https://packages.microsoft.com/rhel/9/prod/ --cost=1 --excludepkgs=aznfs,mdatp
repo --name=vscode --baseurl=https://packages.microsoft.com/yumrepos/vscode --cost=1
repo --name=edge-canary --baseurl=https://packages.microsoft.com/yumrepos/edge-canary --cost=1
repo --name=gh-cli --baseurl=https://cli.github.com/packages/rpm --cost=1
repo --name=github-desktop --baseurl=https://mirror.mwt.me/shiftkey-desktop/rpm --cost=1

# RPMFusion, for real ffmpeg/h264/aac decoding - Fedora's own gstreamer
# packages are the "-free" builds only (patent-clean, no mp3/h264/aac).
# Cost 50 puts it in the same "fill the gaps" tier as Fedora proper.
repo --name=rpmfusion-free --mirrorlist=https://mirrors.rpmfusion.org/mirrorlist?repo=free-fedora-43&arch=x86_64 --cost=50
repo --name=rpmfusion-nonfree --mirrorlist=https://mirrors.rpmfusion.org/mirrorlist?repo=nonfree-fedora-43&arch=x86_64 --cost=50

# --nocore: Azure Linux has no comps @core group that helps here.
# GNOME and desktop packages come from Fedora 43.
%packages --nocore --excludedocs
# Azure Linux base
azurelinux-release
azurelinux-repos
bash
coreutils
systemd
systemd-networkd
systemd-resolved
dnf5
grub2
grub2-efi-x64
grub2-efi-x64-modules
shim
efibootmgr
kernel
kernel-modules
kernel-modules-extra
azurelinux-desktop-policy
openssh-server
openssh-clients
sudo
vim-minimal
ncurses
ca-certificates
setup
shadow-utils
util-linux
selinux-policy-targeted
audit
chrony
cryptsetup
firewalld

# xfsprogs and cloud-utils-growpart aren't needed by the live ISO at all
# (its root is a read-only squashfs, nothing to grow), but they cost
# almost nothing to carry and the disk-image variant genuinely needs
# both at runtime: the disk-image build step converts a 16GB `--grow`
# root partition into a 64G qcow2/VHDX (see the "Build disk-image
# kickstart variant" step comment in .github/workflows/build-live-iso.yml
# for why `--grow` alone doesn't get the extra ~48GB actually used), and
# the azl-growroot.service unit below (only ever enabled on the
# disk-image variant, via the disk-image kickstart's own sed step) needs
# `growpart` (from cloud-utils-growpart) to extend the partition and
# `xfs_growfs` (from xfsprogs) to extend the filesystem into it, both at
# the target's first real boot.
xfsprogs
cloud-utils-growpart
iproute
NetworkManager

# Live-media-only packages - not part of the installable variant's package
# list, needed here so livemedia-creator can build a bootable squashfs/ISO
# and so the live session has the standard Fedora live-boot user setup
# (livesys creates/configures "liveuser" at runtime, see the %post note
# below on GDM autologin).
livesys-scripts
anaconda-live
dracut-live
dracut-config-generic
glibc-all-langpacks

# grub2-efi-x64-cdboot: REQUIRED for a live/bootable ISO specifically, not
# covered by the grub2-efi-x64/shim/efibootmgr already in %packages above.
# lorax's live x86.tmpl only builds EFI/BOOT + images/efiboot.img (the
# El Torito UEFI boot path) if it finds boot/efi/EFI/*/gcdx64.efi in the
# installed tree - that file ships specifically in this -cdboot
# subpackage, not in plain grub2-efi-x64. Missing it doesn't fail the
# package install or the anaconda --dirinstall step - it silently skips
# the whole EFI section of the ISO template, and then xorrisofs blows up
# much later with "Cannot determine attributes of source file
# '.../EFI/BOOT': No such file or directory" because x86.tmpl's xorrisofs
# graft-point list references EFI/BOOT unconditionally regardless of
# whether the EFI section actually ran. See findings/github-actions-build.md.
grub2-efi-x64-cdboot
grub2-tools-extra

# GNOME desktop from Fedora 43 - core session only, not the whole
# workstation-product-environment comps group. See
# findings/fedora-azl-repo-mixing.md.
gnome-shell
gnome-session
gnome-session-wayland-session
gdm
mutter
gnome-control-center
gnome-control-center-filesystem
gnome-terminal
gnome-text-editor
gnome-system-monitor
gnome-disk-utility
gnome-calculator
nautilus
gnome-backgrounds
gnome-menus
gsettings-desktop-schemas
gnome-keyring
gnome-keyring-pam
gvfs
gvfs-mtp
gvfs-smb
gvfs-goa
gnome-online-accounts
xdg-desktop-portal
xdg-desktop-portal-gnome
xdg-desktop-portal-gtk
pipewire
pipewire-alsa
pipewire-pulseaudio
wireplumber
flatpak
gnome-software

# The rest of a normal GNOME desktop - default viewers, a handful of
# core apps, nothing that pulls in an office suite or a docs/tour/parental-
# controls stack we don't want. Loupe/Papers are the current GNOME renames
# of eog/evince - use those, not the old names.
loupe
papers
totem
snapshot
gnome-clocks
gnome-characters
gnome-font-viewer
gnome-logs
gnome-connections
gnome-weather
gnome-screenshot
evolution
evolution-ews

# Explicit excludes for weak/transitive deps observed sneaking in during
# the no-virt live build despite not being requested anywhere - see
# findings/fedora-azl-repo-mixing.md (weak-dep leak notes). The
# `-pkgname` syntax excludes a package even if something else pulls it in
# as a Recommends/weak dep.
-gnome-tour
-gnome-user-docs
-yelp
-yelp-libs
-malcontent-control

# mdatp (Microsoft Defender for Endpoint) - started getting pulled in as
# a transitive/weak dep from one of the Microsoft repos between builds
# (upstream repo drift - nothing in this kickstart asks for it directly).
# Excluding it on the ms-prod repo definition alone wasn't enough (still
# showed up in the transaction), so it's coming in from azl-microsoft or
# a dependency chain the per-repo excludepkgs doesn't cover - the
# %packages `-pkgname` form excludes it regardless of which repo/weak-dep
# path pulls it in. Its own postinstall scriptlet also just doesn't work
# in a %post --dirinstall chroot anyway (`[Errno 2] No such file or
# directory: '/usr/sbin/load_policy'` - wants a live SELinux userspace
# this build environment doesn't have), and it's not something a personal
# desktop proof of concept wants installed regardless.
-mdatp

# fedora-logos rides in as a weak/transitive dep of gdm/gnome-shell (see
# findings/live-package-list.txt: fedora-logos was
# never asked for directly) and puts Fedora's own blue "f" logo and
# background on the GDM login screen of what is otherwise an Azure Linux
# build. generic-logos is Fedora's own trademark-free drop-in replacement
# (provides redhat-logos/system-logos, same file paths fedora-logos
# ships) - built for exactly this respin scenario - so swap it in and
# exclude fedora-logos outright rather than leave two competing logo
# packages both trying to own the same paths.

# Fonts, broad coverage beyond just Adwaita's own faces
adwaita-sans-fonts
adwaita-mono-fonts
liberation-fonts-all
dejavu-sans-fonts
google-noto-fonts-common

# Real codec support - Fedora's own gstreamer packages are the "-free"
# builds only (no patented mp3/h264/aac decode). RPMFusion's ffmpeg and
# gstreamer1-plugin-libav fill that in; gstreamer1-plugin-openh264 is Cisco's own
# royalty-free build and ships from Fedora directly, no RPMFusion needed.
gstreamer1-plugins-good
gstreamer1-plugins-bad-free
gstreamer1-plugins-ugly-free
gstreamer1-plugin-openh264
gstreamer1-plugin-libav
ffmpeg

# Deliberately NOT installed, on request: libreoffice, gnome-maps,
# gnome-tour, gnome-user-docs/yelp (help), simple-scan (document scanner),
# malcontent (parental controls).

# Microsoft + GitHub tooling, from official repos where they exist
microsoft-edge-canary
powershell
azure-cli
code-insiders
gh
github-desktop

# .NET - going with the bleeding-edge 11.0 preview line straight from
# azl-microsoft (Microsoft's own build), matching the "stay bleeding edge"
# choice made for Edge Canary and VS Code Insiders elsewhere in this list.

# Hardware/power support Azure Linux doesn't bother with (it's a cloud/
# container distro - VMs don't suspend, don't have batteries, don't need
# per-vendor wifi firmware). linux-firmware, bluez, fwupd, and
# microcode_ctl were previously left off this list entirely, relying on
# them riding in as weak/Recommends-level deps of kernel/NetworkManager
# - true for the first three (confirmed present in this build's own
# lorax/livemedia-creator transaction log), but never actually true for
# microcode_ctl despite an earlier version of this same comment claiming
# otherwise (confirmed absent from that log). All four are listed
# explicitly now instead of relying on weak-dep luck - real bare-metal
# installs need working wifi firmware and CPU microcode regardless of
# what any one build happens to pull in transitively today - caught
# during bare-metal and installer parity checks. See
# findings/wifi-missing-on-bare-metal.md and findings/live-iso-installer-parity.md.
linux-firmware
# Intel Wi-Fi firmware is split out of linux-firmware on Azure Linux.
# linux-firmware alone does not ship iwlwifi-8000C and friends. The
# driver is out-of-tree (stock x86_64 has CONFIG_WLAN off) via
# azurelinux-desktop-policy / iwlwifi-kmod. Without firmware + the OOT
# modules, bare-metal Intel laptops get NM-wifi userspace and no wlan
# device. See findings/wifi-missing-on-bare-metal.md.
iwlwifi-mvm-firmware
iwlwifi-dvm-firmware
iwlwifi-mld-firmware
iwlegacy-firmware
bluez
# Audio/BT userspace for OOT sound + bluetooth kmods (Azure packages).
# intel-audio-firmware: SST/AVS blobs; alsa-ucm: UCM profiles; NM-bt: tethering.
intel-audio-firmware
alsa-ucm
NetworkManager-bluetooth
fwupd
microcode_ctl

# what's genuinely missing is the userspace power/laptop stack, pulled
# from Fedora 43:
upower
power-profiles-daemon
thermald
switcheroo-control
brightnessctl

# Intel hardware video acceleration (VAAPI) - the test host is Intel HD 520
# (Skylake-U GT2), and Azure Linux's own package set has nothing for this
# since it's not a concern for cloud VMs. Pulled from Fedora - matters for
# smooth, lower-power video playback in Totem/the browser rather than pure
# software decode.
libva
libva-intel-media-driver
intel-mediasdk

# Plymouth, for the boot splash - a plain kernel console with "quiet rhgb"
# on the cmdline but no plymouth package installed just gets a blank/mostly
# text screen and lets dracut's udev/module warnings (multipath, etc.)
# leak through before GDM starts, which is exactly the "boot noise" a real
# distro live image doesn't show. plymouth-plugin-script is the renderer
# our custom azurelinux theme actually needs (ModuleName=script in the
# .plymouth file below) - the default two-step/details plugins can't run
# a .script file.
plymouth
plymouth-plugin-script
plymouth-plugin-label

# libayatana-appindicator-gtk3: NOT a direct kickstart ask - it's the missing
# runtime dependency that silently broke the GitHub Copilot GUI side-load
# below (`rpm -i` on the Tauri "github" app's RPM failed with "Failed
# dependencies: libayatana-appindicator3.so.1()(64bit) is needed by
# github-0:1.0.24-1.x86_64", and %post has no `set -e` so the failure was
# swallowed and the build carried on with no /usr/bin/github, no desktop
# icon, no error surfaced anywhere except this post-install log). Listing
# it here as a real package (Fedora 43 ships it) means the RPM install can
# actually succeed instead of failing quietly.
libayatana-appindicator-gtk3

%end

# Regular (chrooted) %post has NO network access in livemedia-creator
# --no-virt builds - confirmed by a real build log ("curl: (6) Could not
# resolve host: api.github.com") even though the earlier %packages/dnf5
# phase (which installs everything else, including Fedora/Azure Linux repo
# packages) very much does have network. Anaconda tears down/doesn't
# forward DNS into the chrooted %post environment the way it does for its
# own payload backend. `%post --nochroot` runs in the *build host*
# environment instead (same one dnf5 used), with the installed system
# just mounted at /mnt/sysimage rather than chrooted into - so it has
# real network. Do all the curl/GitHub-API side-loading here, staging
# files under /mnt/sysimage so the later chrooted %post can install them
# as plain local files with no network dependency at all.
%post --nochroot --log=/mnt/sysimage/var/log/azl-desktop-post-nochroot.log
set -x
mkdir -p /mnt/sysimage/root/thirdparty

# Our own small static assets (icons, .desktop launchers for edit/pwsh)
# are just checked into the repo - no need to curl these from anywhere,
# copy them straight out of the build workspace that's already mounted
# into this container (this %post --nochroot phase runs in the same
# container livemedia-creator itself is running in, so /workspace is the
# real repo checkout, same as what dnf5 saw during %packages).
mkdir -p /mnt/sysimage/usr/share/pixmaps /mnt/sysimage/usr/share/applications /mnt/sysimage/usr/share/dbus-1/services
install -m 0644 /workspace/assets/icons/edit.svg /mnt/sysimage/usr/share/pixmaps/edit.svg
install -m 0644 /workspace/assets/icons/powershell.png /mnt/sysimage/usr/share/pixmaps/powershell.png
install -m 0644 /workspace/assets/icons/dotnet.svg /mnt/sysimage/usr/share/pixmaps/dotnet.svg
install -m 0644 /workspace/assets/desktop/edit.desktop /mnt/sysimage/usr/share/applications/edit.desktop
install -m 0755 /workspace/assets/bin/azl-powershell-terminal /mnt/sysimage/usr/local/bin/azl-powershell-terminal
install -m 0755 /workspace/assets/bin/azl-dotnet-terminal /mnt/sysimage/usr/local/bin/azl-dotnet-terminal
install -m 0644 /workspace/assets/desktop/org.azurelinux.PowerShell.desktop /mnt/sysimage/usr/share/applications/org.azurelinux.PowerShell.desktop
install -m 0644 /workspace/assets/dbus/org.azurelinux.PowerShell.service /mnt/sysimage/usr/share/dbus-1/services/org.azurelinux.PowerShell.service
install -m 0644 /workspace/assets/desktop/dotnet.desktop /mnt/sysimage/usr/share/applications/dotnet.desktop
install -m 0755 /workspace/assets/bluetooth/azurelinux-desktop-bt-usb-reset /mnt/sysimage/usr/libexec/azurelinux-desktop-bt-usb-reset
install -m 0644 /workspace/assets/systemd/azurelinux-desktop-bt-recover.service /mnt/sysimage/usr/lib/systemd/system/azurelinux-desktop-bt-recover.service
install -m 0644 /workspace/assets/systemd/azurelinux-desktop-bt-recover-late.service /mnt/sysimage/usr/lib/systemd/system/azurelinux-desktop-bt-recover-late.service
install -m 0644 /workspace/assets/systemd/80-azurelinux-desktop-pipewire.preset /mnt/sysimage/usr/lib/systemd/user-preset/80-azurelinux-desktop-pipewire.preset
install -d -m 0755 /mnt/sysimage/etc/udev/rules.d
install -m 0644 /workspace/assets/udev/80-azurelinux-desktop-bt-power.rules /mnt/sysimage/etc/udev/rules.d/80-azurelinux-desktop-bt-power.rules
# First-boot prepare: keep Plymouth up during SELinux relabel / disk grow.
install -d -m 0755 /mnt/sysimage/usr/libexec/azurelinux-desktop \
    /mnt/sysimage/usr/lib/systemd/system/selinux-autorelabel.service.d
install -m 0755 /workspace/assets/bin/azl-first-boot-prepare \
    /mnt/sysimage/usr/libexec/azurelinux-desktop/azl-first-boot-prepare
install -m 0644 /workspace/assets/systemd/selinux-autorelabel.service.d/10-azurelinux-desktop.conf \
    /mnt/sysimage/usr/lib/systemd/system/selinux-autorelabel.service.d/10-azurelinux-desktop.conf

# Lorax builds the boot initramfs from this target root after %post. Patch the
# target's older livenet hook, not the Fedora build container's dracut copy.
install -D -m 0755 /workspace/scripts/patch-dracut-livenet-hook.sh \
    /mnt/sysimage/usr/local/libexec/patch-dracut-livenet-hook.sh
chroot /mnt/sysimage /usr/local/libexec/patch-dracut-livenet-hook.sh
rm -f /mnt/sysimage/usr/local/libexec/patch-dracut-livenet-hook.sh

# Same story for the plymouth boot splash - it's just our own static
# theme files checked into the repo (assets/plymouth/azurelinux/), plus
# the Azure Linux logo PNG, copied straight into the target root's
# plymouth themes dir. plymouth itself gets installed from %packages;
# this only drops the theme content in place, chrooted %post below picks
# the theme as default.
mkdir -p /mnt/sysimage/usr/share/plymouth/themes/azurelinux
install -m 0644 /workspace/assets/plymouth/azurelinux/azurelinux.plymouth /mnt/sysimage/usr/share/plymouth/themes/azurelinux/azurelinux.plymouth
install -m 0644 /workspace/assets/plymouth/azurelinux/azurelinux.script /mnt/sysimage/usr/share/plymouth/themes/azurelinux/azurelinux.script
install -m 0644 /workspace/assets/plymouth/azurelinux/dot.png /mnt/sysimage/usr/share/plymouth/themes/azurelinux/dot.png
install -m 0644 /workspace/assets/plymouth/azurelinux/dot-glow.png /mnt/sysimage/usr/share/plymouth/themes/azurelinux/dot-glow.png
install -m 0644 /workspace/assets/branding/AzureLinuxLogo.png /mnt/sysimage/usr/share/plymouth/themes/azurelinux/azurelinuxlogo.png
# GDM login badge (same asset + path as kiwi/azl-install.ks.in). Live
# autologin hides it most of the time; logout and disk-image boots still
# hit GDM.
install -m 0644 /workspace/assets/branding/azurelinux-gdm-logo.png \
    /mnt/sysimage/usr/share/pixmaps/azurelinux-logo.png
mkdir -p /mnt/sysimage/usr/share/backgrounds/azurelinux
install -m 0644 /workspace/assets/wallpapers/adwaita-l.jpg /mnt/sysimage/usr/share/backgrounds/azurelinux/adwaita-l.jpg
install -m 0644 /workspace/assets/wallpapers/adwaita-d.jpg /mnt/sysimage/usr/share/backgrounds/azurelinux/adwaita-d.jpg

# Side-load Copilot GUI/CLI, microsoft/edit, and Flathub from *latest*
# upstream releases each build. No pinned version numbers. Fail the
# build if any required asset is missing (warnings used to ship ISOs
# without edit/Copilot). Shared helper: scripts/fetch-latest-thirdparty.sh
# (GITHUB_TOKEN/GH_TOKEN used when set for API rate limits).
# Flathub is staged here because chrooted %post has no network under
# livemedia-creator --no-virt (historical empty-remote GNOME Software).
if [ ! -x /workspace/scripts/fetch-latest-thirdparty.sh ]; then
    echo "error: /workspace/scripts/fetch-latest-thirdparty.sh missing" >&2
    exit 1
fi
/workspace/scripts/fetch-latest-thirdparty.sh /mnt/sysimage/root/thirdparty
install -m 0755 /workspace/scripts/install-dotnet-sdk-tarball.sh /mnt/sysimage/root/thirdparty/install-dotnet-sdk-tarball.sh

# Microsoft Copilot GTK Flatpak (updatable Pages remote). Needs host
# network + flatpak CLI in the build container; chrooted %post has neither
# under livemedia-creator --no-virt. System install into the target root
# so every live/qcow user gets the app and can `flatpak update` later.
if [ ! -x /workspace/scripts/install-copilot-desktop-flatpak.sh ]; then
    echo "error: /workspace/scripts/install-copilot-desktop-flatpak.sh missing" >&2
    exit 1
fi
/workspace/scripts/install-copilot-desktop-flatpak.sh /mnt/sysimage \
    /mnt/sysimage/root/thirdparty/flathub.flatpakrepo
%end

%post --log=/var/log/azl-desktop-post.log
set -x

# Persist the same repo priority policy post-install, so `dnf install
# <whatever>` next year still prefers Azure Linux first and only falls back
# to Fedora 43 when Azure Linux has no package. Known soname landmines get an
# exclude here as they're discovered - add to this list, don't fight it.
FEDORA_EXCLUDES="audit,audit-libs,audit-rules,bash,bluez,bluez-libs,bluez-obexd,bzip2,ca-certificates,chrony,coreutils,coreutils-common,cryptsetup,cryptsetup-libs,dbus,dbus-broker,dbus-common,dbus-daemon,dbus-libs,dbus-tools,device-mapper,device-mapper-event,device-mapper-event-libs,device-mapper-libs,device-mapper-persistent-data,diffutils,dosfstools,e2fsprogs,e2fsprogs-libs,efibootmgr,findutils,firewalld,firewalld-filesystem,gawk,gawk-all-langpacks,grep,gzip,hwdata,iproute,iputils,kbd,kbd-legacy,kbd-misc,kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra,kmod,less,less-color,libaio,libblkid,libcom_err,libfdisk,liblastlog2,libmount,libnm,libsmartcols,libuuid,linux-firmware,linux-firmware-whence,lvm2,lvm2-libs,microcode_ctl,ModemManager-glib,mtools,ncurses,ncurses-base,ncurses-libs,NetworkManager,NetworkManager-libnm,NetworkManager-team,NetworkManager-tui,NetworkManager-wifi,NetworkManager-bluetooth,alsa-ucm,alsa-lib,openssh,openssh-clients,openssh-server,patch,polkit,polkit-libs,procps-ng,python3-audit,python3-firewall,python3-libmount,sed,setup,shadow-utils,sudo,sudo-python-plugin,systemd,systemd-boot-unsigned,systemd-container,systemd-libs,systemd-networkd,systemd-pam,systemd-resolved,systemd-shared,systemd-sysusers,systemd-udev,tar,util-linux,util-linux-core,vim-data,vim-minimal,xz,xz-libs,amd-gpu-firmware,amd-ucode-firmware,atheros-firmware,brcmfmac-firmware,cirrus-audio-firmware,intel-audio-firmware,intel-gpu-firmware,mt7xxx-firmware,nvidia-gpu-firmware,nxpwireless-firmware,qcom-wwan-firmware,realtek-firmware,tiwilink-firmware,iwlegacy-firmware,iwlwifi-dvm-firmware,iwlwifi-mld-firmware,iwlwifi-mvm-firmware"
cat > /etc/yum.repos.d/azl-desktop-fedora.repo << EOF
[fedora43]
name=Fedora 43 (GNOME desktop stack)
baseurl=https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/
enabled=1
gpgcheck=0
priority=50
excludepkgs=$FEDORA_EXCLUDES

[fedora43-updates]
name=Fedora 43 Updates
baseurl=https://dl.fedoraproject.org/pub/fedora/linux/updates/43/Everything/x86_64/
enabled=1
gpgcheck=0
priority=50
excludepkgs=$FEDORA_EXCLUDES
EOF

# The kickstart `repo --name=...` lines above (ms-prod, vscode, edge-canary,
# gh-cli, github-desktop, rpmfusion-free/nonfree) only exist for Anaconda's
# own install-time transaction - none of them get written to the installed
# system's /etc/yum.repos.d automatically, unlike the Azure Linux repos (shipped by
# the azurelinux-repos package itself) and fedora43/fedora43-updates (just
# persisted above). Left as-is, that meant PowerShell, .NET, VS Code
# Insiders, Edge Canary, GitHub CLI, GitHub Desktop, and the RPMFusion
# ffmpeg/gstreamer1-plugin-libav codec packages would all be frozen at whatever
# version was current on the day this ISO was built, with no `dnf upgrade`
# path afterward. Persist their real upstream repos too so they keep
# receiving updates same as everything else.
cat > /etc/yum.repos.d/azl-desktop-microsoft-github.repo << 'EOF'
[ms-prod]
name=Microsoft RHEL 9 prod (PowerShell, .NET)
baseurl=https://packages.microsoft.com/rhel/9/prod/
enabled=1
gpgcheck=0
priority=1

[vscode]
name=Visual Studio Code Insiders
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=0
priority=1

[edge-canary]
name=Microsoft Edge Canary
baseurl=https://packages.microsoft.com/yumrepos/edge-canary
enabled=1
gpgcheck=0
priority=1

[gh-cli]
name=GitHub CLI
baseurl=https://cli.github.com/packages/rpm
enabled=1
gpgcheck=0
priority=1

[github-desktop]
name=GitHub Desktop (shiftkey/desktop Linux fork)
baseurl=https://mirror.mwt.me/shiftkey-desktop/rpm
enabled=1
gpgcheck=0
priority=1
EOF

cat > /etc/yum.repos.d/azl-desktop-rpmfusion.repo << 'EOF'
[rpmfusion-free]
name=RPM Fusion for Fedora 43 - Free
baseurl=https://download1.rpmfusion.org/free/fedora/releases/43/Everything/x86_64/os/
enabled=1
gpgcheck=0
priority=50

[rpmfusion-nonfree]
name=RPM Fusion for Fedora 43 - Nonfree
baseurl=https://download1.rpmfusion.org/nonfree/fedora/releases/43/Everything/x86_64/os/
enabled=1
gpgcheck=0
priority=50
EOF

# Known conflicts as of this writing (see findings/fedora-azl-repo-mixing.md).
# hunspell-en: Fedora and Azure Linux both ship it, identical file paths, no version
# skew - just pick one. grub2/shim family: Azure Linux's own
# grub2-tools-minimal links against libfuse3.so.3, Fedora's
# flatpak/xdg-desktop-portal need libfuse3.so.4 - can't have both, so hand
# the *whole* bootloader family to Fedora rather than cherry-picking fuse3
# out from under Azure Linux grub2 (that just moves the same conflict one
# layer down). gsettings-desktop-schemas: Azure Linux ships an older build
# than current gnome-shell needs - plain version floor, no ABI risk, let
# Fedora's copy win.
sed -i '/^\[azl-base\]/,/^\[/ s/^enabled=1/enabled=1\nexclude=hunspell-en grub2 grub2-pc grub2-pc-modules grub2-efi-x64 grub2-efi-x64-modules grub2-tools grub2-tools-minimal grub2-common shim shim-x64 gsettings-desktop-schemas dnf5 dnf5daemon-server dnf5daemon-server-polkit libdnf5 libdnf5-cli libdnf5-plugin-actions libdnf5-plugin-appstream libdnf5-plugin-expired-pgp-keys libdnf5-plugin-local/' /etc/yum.repos.d/azurelinux.repo 2>/dev/null || true
sed -i '/^\[azl-microsoft\]/,/^\[/ s/^enabled=1/enabled=1\nexclude=hunspell-en grub2 grub2-pc grub2-pc-modules grub2-efi-x64 grub2-efi-x64-modules grub2-tools grub2-tools-minimal grub2-common shim shim-x64 gsettings-desktop-schemas/' /etc/yum.repos.d/azurelinux.repo 2>/dev/null || true
# Keep the version-locked Fedora GRUB family together during later updates.
sed -i '/^\[azl-base\]/,/^\[/ s/^exclude=/&grub2-tools-extra /' /etc/yum.repos.d/azurelinux.repo 2>/dev/null || true
sed -i '/^\[azl-microsoft\]/,/^\[/ s/^exclude=/&grub2-tools-extra /' /etc/yum.repos.d/azurelinux.repo 2>/dev/null || true

cat > /etc/yum.repos.d/azl-desktop-kmods.repo << 'EOF'
[azl-desktop-kmods]
name=Azure Linux Desktop kernel modules
baseurl=https://sirredbeard.github.io/azurelinux-desktop/repo
enabled=1
gpgcheck=0
cost=1
EOF

systemctl set-default graphical.target
systemctl enable gdm.service

# Fedora's livesys-scripts package is desktop-agnostic by design - it
# doesn't know GNOME got installed, so /etc/sysconfig/livesys ships with
# livesys_session="" out of the box. livesys-main only sources
# sessions.d/livesys-${livesys_session} when that variable is non-empty,
# so leaving it blank means livesys-gnome (dock/favorites override,
# gnome-initial-setup suppression, Anaconda branding, welcome screen)
# NEVER RUNS AT ALL - confirmed by inspecting a real built image where
# the favorite-apps override was correctly written into livesys-gnome
# itself but never took effect on boot. This one-liner is the actual fix.
sed -i 's/^livesys_session=.*/livesys_session="gnome"/' /etc/sysconfig/livesys

# Plymouth boot splash: theme content was already staged into place by
# the %post --nochroot block above (plymouth itself came from %packages).
# plymouth-set-default-theme (no -R) just flips /etc/plymouth/plymouthd.conf
# to point at it - lorax runs its own dracut pass against this same
# install root after %post finishes to build the actual boot initrd, so
# that later dracut run picks up this config and the plymouth dracut
# module on its own; we don't need (and can't usefully) rebuild an
# initrd ourselves in here.
if [ -x /usr/sbin/plymouth-set-default-theme ]; then
    plymouth-set-default-theme azurelinux || true
fi

# The "boot noise" the user actually saw was harmless Device Mapper
# multipath warnings from dracut's 70multipath module scanning for
# multipath-capable disks - completely irrelevant for a live ISO (no
# multipath storage involved at all), and printed to the console before
# plymouth/GDM take over. Omitting the module outright removes the noise
# at the source instead of just hoping the splash covers it in time.
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/no-multipath.conf << 'EOF'
omit_dracutmodules+=" multipath "
EOF

# The other visible boot artifact - the custom plymouth splash working
# fine, then briefly dropping to plain systemd console text before GDM
# takes over - is GDM's own responsibility to avoid (gdm.service ships
# with Conflicts=/After=plymouth-quit.service specifically so it quits
# the splash itself once its compositor is ready to paint, not the
# generic plymouth-quit-wait.service timing), so it isn't a GDM
# ordering problem we introduced. What it looks like instead is the
# well-known virtio-gpu/KMS driver mode-switch flicker: dracut's initrd
# only loads virtio-gpu's real KMS driver on demand by default, so
# there's a brief window right at switch-root where the console falls
# back to a plain text framebuffer before the driver (and the real
# root's plymouthd) come back up. Forcing virtio_gpu into the initrd's
# module list up front (instead of loading it late) shrinks that window.
cat > /etc/dracut.conf.d/early-kms.conf << 'EOF'
add_drivers+=" virtio_gpu hyperv_drm bochs_drm "
EOF

# plymouth-quit-wait.service fires when systemd decides the boot is
# "done enough" - on fast hardware or a lightweight live session that
# reaches basic.target in under a second, that window closes before
# the animation loop has run more than a handful of frames. Adding
# After=multi-user.target keeps the splash alive until the full service
# graph is up, giving the animation its intended boot-duration run
# instead of a one-second flash before the static logo.
mkdir -p /etc/systemd/system/plymouth-quit-wait.service.d
cat > /etc/systemd/system/plymouth-quit-wait.service.d/wait-for-boot.conf << 'EOF'
[Unit]
After=multi-user.target
EOF

# System-wide dark mode and background defaults. /etc/dconf/db/local.d is the
# standard "default value, but still user-overridable" mechanism - liveuser
# (or anyone else) can still change these from Settings. Pin the background
# to images gnome-backgrounds ships so a fresh live session never depends on
# an unset upstream default. Needs a matching
# /etc/dconf/profile/user pointing at the local db, and
# `dconf update` to compile db/local.d/* into db/local once, at build time.
mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
cat > /etc/dconf/db/local.d/00-dark-mode << 'EOF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
gtk-theme='Adwaita-dark'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/azurelinux/adwaita-l.jpg'
picture-uri-dark='file:///usr/share/backgrounds/azurelinux/adwaita-d.jpg'
picture-options='zoom'

# Microsoft Copilot hardware key: firmware emits LeftMeta+LeftShift+F23
# (KEY_F23). Bind that chord to the Microsoft Copilot GTK Flatpak. Newer
# xkeyboard-config maps the same chord to XF86Assistant; the Super+Shift+F23
# form works across older stacks without that mapping.
[org/gnome/settings-daemon/plugins/media-keys]
custom-keybindings=['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']

[org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0]
name='Microsoft Copilot'
command='flatpak run com.github.sirredbeard.copilot-desktop-gtk'
binding='<Shift><Super>F23'
EOF
cat > /etc/dconf/profile/user << 'EOF'
user-db:user
system-db:local
EOF
dconf update || true

# GDM login-screen logo: same override as kiwi/azl-install.ks.in. Autologin
# skips the greeter on live boots; logout and non-autologin disk boots still
# use GDM. fedora-logos points org.gnome.login-screen logo at the Fedora
# badge; this system-db replaces it without editing the schema file.
mkdir -p /etc/dconf/db/gdm.d
cat > /etc/dconf/profile/gdm << 'EOF'
user-db:user
system-db:gdm
EOF
cat > /etc/dconf/db/gdm.d/00-azl-login-screen << 'EOF'
[org/gnome/login-screen]
logo='/usr/share/pixmaps/azurelinux-logo.png'
EOF
dconf update || true

# Install Copilot GUI/CLI and microsoft/edit from files staged by
# %post --nochroot (no network here under livemedia-creator --no-virt).
# Required assets must exist - the fetch helper fails the build earlier
# if latest release resolution fails.
test -s /root/thirdparty/github-copilot.rpm
test -s /root/thirdparty/copilot-linux-x64.tar.gz
test -s /root/thirdparty/edit.tar.gz
rpm -i /root/thirdparty/github-copilot.rpm
tar -xzf /root/thirdparty/copilot-linux-x64.tar.gz -C /usr/local/bin copilot
chmod 0755 /usr/local/bin/copilot
test -x /usr/local/bin/copilot
tar -xzf /root/thirdparty/edit.tar.gz -C /tmp
install -m 0755 /tmp/edit /usr/local/bin/edit
rm -f /tmp/edit
test -x /usr/local/bin/edit

# .NET 11 SDK from Microsoft linux-x64 tarball (always latest 11.x from
# release-metadata / download page / aka.ms). Not a yum package.
test -s /root/thirdparty/dotnet-sdk-linux-x64.tar.gz
/root/thirdparty/install-dotnet-sdk-tarball.sh / /root/thirdparty/dotnet-sdk-linux-x64.tar.gz
test -x /usr/share/dotnet/dotnet
test -x /usr/bin/dotnet || test -L /usr/bin/dotnet
# Keep the resolved-versions note for support/debug of this ISO build.
if [ -f /root/thirdparty/thirdparty-versions.txt ]; then
    install -m 0644 /root/thirdparty/thirdparty-versions.txt \
        /var/log/azl-desktop-thirdparty-versions.txt
fi

# flatpak is installed but ships with zero remotes configured out of the
# box - without this, GNOME Software shows no flatpak apps at all (the
# "no flatpaks in gnome-software" nit). The .flatpakrepo file (which
# embeds Flathub's real signing key, so there's no need to hand-copy key
# material here) was already fetched over real network in the
# %post --nochroot block above and staged at
# /root/thirdparty/flathub.flatpakrepo - add it from there instead of
# hitting the network again from this chrooted %post, which doesn't have
# any (same reasoning as the Copilot/edit installs right above - has to
# run before the rm -rf /root/thirdparty a few lines down). System-wide
# (--system, the default with no --user) so it's there for every user
# from first boot. (Testing actual flatpak installs needs real disk
# space for the OSTree-style deduplicated storage under /var/lib/flatpak
# - undersized live/VM disks will fill up fast once apps start pulling
# runtimes, that's an environment sizing issue, not a config issue.)
if [ -s /root/thirdparty/flathub.flatpakrepo ]; then
    flatpak remote-add --if-not-exists flathub /root/thirdparty/flathub.flatpakrepo 2>&1 || true
else
    echo "WARNING: flathub.flatpakrepo wasn't staged by %post --nochroot - flathub remote not added" >&2
fi
rm -rf /root/thirdparty

# GNOME Software: Fedora's gschema override prefers only Fedora Flatpak
# remotes and requires fedora/updates repos. This image uses Flathub +
# Azure Linux DNF. Our override filename sorts after the Fedora one so these
# keys win after glib-compile-schemas.
cat > /usr/share/glib-2.0/schemas/org.gnome.software.gschema.override << 'EOF'
[org.gnome.software]
allow-updates=false
download-updates=false
packaging-format-preference=['flatpak:flathub', 'flatpak', 'rpm']
required-repos=[]
official-repos=['azl-base', 'azl-microsoft', 'azl-desktop-kmods']
EOF
rm -f /etc/xdg/autostart/org.gnome.Software.desktop
cat >> /usr/share/gnome-shell/search-providers/org.gnome.Software-search-provider.ini << 'EOF'
DefaultDisabled=true
EOF
glib-compile-schemas /usr/share/glib-2.0/schemas

# Live/install %post is offline for appstream; refresh once network is up.
cat > /usr/lib/systemd/system/azl-flatpak-appstream.service << 'EOF'
[Unit]
Description=Refresh Flathub appstream on first boot
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/bin/flatpak
ConditionPathExists=!/var/lib/flatpak/appstream/flathub/x86_64/active

[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak update --appstream
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable azl-flatpak-appstream.service

# Bluetooth: never force-load btusb before platform rfkill (ThinkPad).
# USB device often enumerates before thinkpad_acpi unblocks radio; recover
# with a USB authorize cycle before bluetooth.service (see findings).
# See findings/bluetooth-hci-timeout-thinkpad.md.
cat > /etc/modules-load.d/azurelinux-desktop-bluetooth.conf << 'EOF'
# btusb is loaded by udev when a Bluetooth controller appears.
EOF
cat > /etc/modprobe.d/azurelinux-desktop-bluetooth.conf << 'EOF'
softdep btusb pre: thinkpad_acpi
options btusb reset=1
options btusb enable_autosuspend=0
EOF
if [ -x /usr/libexec/azurelinux-desktop-bt-usb-reset ]; then
    systemctl enable azurelinux-desktop-bt-recover.service 2>/dev/null || true
    systemctl enable azurelinux-desktop-bt-recover-late.service 2>/dev/null || true
fi
# PipeWire user sockets: Azure Linux presets only enable D-Bus; GNOME screencast needs these.
mkdir -p /etc/systemd/user/sockets.target.wants /etc/systemd/user/pipewire.service.wants
ln -sfn /usr/lib/systemd/user/pipewire.socket /etc/systemd/user/sockets.target.wants/pipewire.socket
ln -sfn /usr/lib/systemd/user/pipewire-pulse.socket /etc/systemd/user/sockets.target.wants/pipewire-pulse.socket
ln -sfn /usr/lib/systemd/user/wireplumber.service /etc/systemd/user/pipewire.service.wants/wireplumber.service
ln -sfn /usr/lib/systemd/user/wireplumber.service /etc/systemd/user/pipewire-session-manager.service

# Anaconda/localed can leave /etc/locale.conf mode 600. Fedora lang.sh
# (sourced on every interactive bash) runs sed against it, so pwsh->bash
# prints: /usr/bin/sed: can't read /etc/locale.conf: Permission denied
if [ -f /etc/locale.conf ]; then
    chmod 644 /etc/locale.conf || true
fi

cat > /etc/profile.d/default-editor.sh << 'EOF'
export EDITOR=/usr/local/bin/edit
export VISUAL=/usr/local/bin/edit
EOF

# PowerShell as the default login shell - this is a genuine departure from
# every other Linux spin out there, but that's the point of this whole
# proof of concept. bash stays installed and available (chsh back any time).
#
# root's shell can just be usermod'd here at build time, but "liveuser"
# doesn't exist yet - livesys-main's own useradd (see /usr/libexec/livesys/
# livesys-main) runs at every boot, with no -s flag, so it picks up
# whatever /etc/default/useradd's SHELL= says. Fixing that default is what
# actually makes gnome-terminal (and any other login-shell spawn) launch
# pwsh for liveuser too, not just root.
if [ -x /usr/bin/pwsh ]; then
    if ! grep -q '^/usr/bin/pwsh$' /etc/shells; then
        echo /usr/bin/pwsh >> /etc/shells
    fi
    usermod --shell /usr/bin/pwsh root 2>/dev/null || true
    sed -i 's|^SHELL=.*|SHELL=/usr/bin/pwsh|' /etc/default/useradd
fi

# Microsoft Edge Canary as the default browser, system-wide, for both the
# GNOME "Default Applications" panel and anything that shells out to
# xdg-open/xdg-settings.
mkdir -p /etc/xdg
cat > /etc/xdg/mimeapps.list << 'EOF'
[Default Applications]
text/html=microsoft-edge-canary.desktop
x-scheme-handler/http=microsoft-edge-canary.desktop
x-scheme-handler/https=microsoft-edge-canary.desktop
x-scheme-handler/about=microsoft-edge-canary.desktop
x-scheme-handler/unknown=microsoft-edge-canary.desktop
EOF

# GNOME Shell dock/favorites: the real fix has to happen in livesys-gnome
# itself, not just a build-time glib schema override file. livesys-gnome
# (part of livesys-scripts, runs at every live boot as root via
# livesys.service) unconditionally APPENDS its own hardcoded favorite-apps
# list (Firefox/Calendar/Rhythmbox/Photos/Nautilus/anaconda) to
# org.gnome.shell.gschema.override and then runs glib-compile-schemas -
# any override we drop in here at image-build time would just get
# clobbered by that later append (last key wins after compile-schemas).
# So: patch livesys-gnome's own favorite-apps= line in place instead of
# fighting it with a second override file. Desktop IDs confirmed against
# the actual installed .desktop files:
# com.github.sirredbeard.copilot-desktop-gtk.desktop (Microsoft Copilot
# Flatpak, far left), microsoft-edge-canary.desktop, code-insiders.desktop,
# org.azurelinux.PowerShell.desktop (our own launcher, see assets/desktop/),
# "GitHub Copilot.desktop" (the Tauri GitHub Copilot app really does ship
# it with a literal space in the filename/ID), and org.gnome.Nautilus.desktop.
# Terminal stays installed and in the app grid, just not pinned.
#
# Important: that whole favorite-apps override only gets written by
# livesys-gnome inside its own `if [ -f /usr/share/applications/
# liveinst.desktop ]` gate - the same gate it also uses to decide whether
# to show the "Install to Hard Drive" icon and the Fedora/Anaconda
# welcome popup. An earlier version of this kickstart deleted
# liveinst.desktop outright at build time to silence the installer
# icon/popup, which also silently starved the favorite-apps override of
# ever running, and the dock fell back to GNOME Shell's own upstream
# default favorites (Nautilus, Software, Text Editor, Calculator). The
# previous fix here just left liveinst.desktop in place so the gate
# would still fire - that assumption turned out to be fragile: a GH
# Actions build (run 29580742319) shipped with liveinst.desktop
# genuinely absent from the tree (`rpm -V anaconda-live` reports it
# "missing" even though the package still owns it in the rpmdb - not
# anything this kickstart deletes; anaconda's own --dirinstall payload
# appears to drop it under some builds and not others), and the dock
# fell right back to the GNOME upstream defaults again. Rather than
# chase why anaconda sometimes ships the file and sometimes doesn't,
# stop depending on it: flip the gate itself to `if true` a few lines
# down (after the mv/NoDisplay/welcome-loop lines specific to the
# liveinst.desktop dance are already stripped out of the block below),
# so the favorite-apps override, welcome-dialog suppression, and branding
# copy always run regardless of whether that one file exists this boot.
if [ -f /usr/libexec/livesys/sessions.d/livesys-gnome ]; then
    sed -i "s|^favorite-apps=.*|favorite-apps=['com.github.sirredbeard.copilot-desktop-gtk.desktop', 'microsoft-edge-canary.desktop', 'code-insiders.desktop', 'org.azurelinux.PowerShell.desktop', 'GitHub Copilot.desktop', 'org.gnome.Nautilus.desktop']|" \
        /usr/libexec/livesys/sessions.d/livesys-gnome
fi

# The "Welcome to Azure Linux" / "Install Azure Linux..." popup that
# opens automatically on first login, and the "Install to Hard Drive"
# launcher in the app grid, both come from the same `if [ -f
# liveinst.desktop ]` block inside livesys-gnome (not gnome-initial-setup,
# already suppressed above, and not anaconda-live's own liveinst-setup
# autostart entry, removed below): livesys-gnome itself flips
# liveinst.desktop's NoDisplay to false and renames it to
# anaconda.desktop to put it in the app grid, and separately copies
# Anaconda's own welcome-screen .desktop file into the live user's
# autostart folder at every boot. Nothing here is ready to drive a real
# install yet, so both are turned off by removing just those specific
# lines from livesys-gnome, leaving the favorite-apps override, the
# GNOME welcome tour suppression, and the branding copy untouched.
if [ -f /usr/libexec/livesys/sessions.d/livesys-gnome ]; then
    sed -i \
        -e "\|sed -i -e 's/NoDisplay=true/NoDisplay=false/' /usr/share/applications/liveinst.desktop|d" \
        -e '\|mv /usr/share/applications/liveinst.desktop /usr/share/applications/anaconda.desktop|d' \
        -e '/for deskname in org.fedoraproject.welcome-screen.desktop fedora-welcome.desktop; do/,/^    done$/d' \
        /usr/libexec/livesys/sessions.d/livesys-gnome
fi

# With the anaconda-icon-specific lines gone from the block above, all
# that's left inside it is the favorite-apps override, the welcome-tour
# suppression, and the branding copy - none of which have anything to do
# with liveinst.desktop anymore. Flip the gate itself so that remainder
# always runs, instead of staying at the mercy of whether anaconda-live
# happened to ship that one file this build.
if [ -f /usr/libexec/livesys/sessions.d/livesys-gnome ]; then
    sed -i 's|^if \[ -f /usr/share/applications/liveinst.desktop \]; then$|if true; then # liveinst.desktop presence is unreliable across anaconda-live builds - always apply favorite-apps/welcome-dialog/branding|' \
        /usr/libexec/livesys/sessions.d/livesys-gnome
fi

# anaconda-live's own separate autostart trigger for the same welcome
# popup (fires independent of livesys-gnome, straight from the
# anaconda-live package's own .desktop file) - anaconda-live has to stay
# installed (it provides the actual live-boot infrastructure lorax needs
# to build this ISO in the first place), only this one autostart entry
# needs to go.
rm -f /etc/xdg/autostart/liveinst-setup.desktop

# Live session user: livesys-scripts creates "liveuser" at runtime (passwd -d,
# usermod -aG wheel) - no static build-time account is embedded. Add the
# one thing livesys does not: passwordless sudo for wheel and GDM autologin
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-wheel-nopasswd
chmod 0440 /etc/sudoers.d/90-wheel-nopasswd
mkdir -p /etc/gdm
cat > /etc/gdm/custom.conf << 'EOF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=liveuser
EOF

# GNOME Keyring "Choose password for new keyring" prompt: root-caused
# properly this time - the previous fix here (a second, unskippable
# "auth optional pam_gnome_keyring.so" line past pam_gdm.so's
# "[success=ok default=1]" skip) turned out to be a no-op even when it
# does run, confirmed straight from gnome-keyring's own PAM module source
# (GNOME/gnome-keyring pam/gkr-pam-module.c, pam_sm_authenticate): on
# autologin PAM_AUTHTOK is NULL (no password was ever typed), so the
# module just logs "no password is available for user" and returns
# PAM_SUCCESS without touching the keyring - it doesn't matter whether
# pam_gdm.so's default=1 skips that line or not, the outcome is
# identical either way. The session-stack line ("session optional
# pam_gnome_keyring.so auto_start") has the same NULL-password problem:
# gnome-keyring-daemon's --login mode reads a password off stdin, PAM
# closes that stream with zero bytes written (EOF, not even an empty
# string), gkd-main.c's read_login_password() returns NULL for that, and
# gkd_login_unlock(NULL) is an explicit no-op guard in gnome-keyring's own
# source (daemon/login/gkd-login.c: "we don't support null as master
# password"). Net effect: neither the auth phase nor the session phase of
# PAM ever seeds or unlocks a login keyring on autologin, no matter how
# the pam_gnome_keyring.so lines are ordered - the daemon just starts
# with nothing to unlock, and the first app that calls
# org.freedesktop.Secret.Service.CreateCollection (Edge Canary, in our
# case) pops the interactive dialog instead of silently getting an empty
# keyring.
#
# The one thing gnome-keyring's own source confirms *does* work is
# calling gkd_login_unlock("") - a real empty string, not NULL - which
# unlock_or_create_login() (daemon/login/gkd-login.c) treats as a valid
# blank password and uses to create the login keyring if none exists yet,
# or unlock it if it does. Nothing in PAM (auth or session stack) ever
# makes that call with an actual empty string instead of NULL, on any
# Fedora release - Fedora Workstation Live has the identical gap, it's
# just less likely to be *noticed* there because a stock live session
# doesn't have anything eagerly calling CreateCollection the way Edge
# Canary does here. So: stop trying to fix this from the PAM side (kept
# below anyway since it's harmless and matches real kiosk-autologin
# configs), and instead make the actual unlock-with-empty-string call
# ourselves, once per session. `gnome-keyring-daemon --unlock` reads a
# password off stdin the same way `--login` does - a single NUL byte
# (not a newline, which would make the password "\n" instead of "") is
# read as a zero-length-but-non-NULL C string, which is exactly the ""
# gkd_login_unlock() needs.
AUTOLOGIN_PAM="/etc/pam.d/gdm-autologin"
if [ -f "$AUTOLOGIN_PAM" ]; then
    if ! grep -qP '^auth\s+optional\s+pam_gnome_keyring' "$AUTOLOGIN_PAM"; then
        sed -i '/^auth.*pam_permit/i auth       optional    pam_gnome_keyring.so' "$AUTOLOGIN_PAM"
    fi
    if ! grep -q 'pam_gnome_keyring.*auto_start' "$AUTOLOGIN_PAM"; then
        sed -i '/^session.*postlogin/i session    optional    pam_gnome_keyring.so auto_start' "$AUTOLOGIN_PAM"
    fi
fi

# First attempt at making the actual unlock-with-"" call was a systemd
# --user drop-in on gnome-keyring-daemon.service - wrong target, verified
# against this very ISO's own rootfs: gnome-keyring-daemon.service and
# .socket exist under /usr/lib/systemd/user, but neither is enabled (no
# default.target.wants or sockets.target.wants symlink anywhere), so
# systemd --user never starts that unit at all in this session and the
# drop-in's ExecStartPost never fires. The daemon that's actually running
# in a live GNOME session comes from three plain XDG autostart entries
# instead - /etc/xdg/autostart/gnome-keyring-{pkcs11,secrets,ssh}.desktop,
# each independently running `gnome-keyring-daemon --start
# --components=...` - completely bypassing systemd user units. Confirmed
# by re-testing GH Actions run 29602968279's ISO in QEMU: Edge Canary
# still popped the "Choose password for new keyring" dialog (for
# "Default Keyring", not "Login" - the tell that no collection was ever
# aliased "default" yet, i.e. the unlock-with-"" call genuinely never
# ran) even with the drop-in staged.
#
# Real fix: add our own XDG autostart entry that races the same way the
# three stock ones do, waiting on the actual control socket path
# ($XDG_RUNTIME_DIR/keyring/control, not systemd's %t specifier - this
# runs as a plain autostart process, not a systemd unit) and then firing
# the same NUL-byte --unlock call. NoDisplay + OnlyShowIn=GNOME keeps it
# out of the app grid; it's idempotent so running once per session
# alongside whichever of the three actually wins the daemon-start race is
# fine.
cat > /usr/libexec/azl-keyring-empty-unlock << 'EOF'
#!/bin/sh
# Wait for gnome-keyring-daemon's control socket - whichever of the three
# gnome-keyring-*.desktop autostart entries gets there first - then send
# a single NUL byte as the "password": a zero-length C string, not a
# NULL pointer and not "\n", which gnome-keyring's own login-unlock code
# (gkd_login_unlock("")) accepts as a real blank password and uses to
# create the login keyring if it doesn't exist yet, or unlock it if it
# does. Runs once per session start; a no-op after the login keyring
# already exists and is aliased "default".
i=0
control="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/keyring/control"
while [ ! -S "$control" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
done
[ -S "$control" ] || exit 0
printf '\0' | /usr/bin/gnome-keyring-daemon --unlock \
    --control-directory="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/keyring" \
    >/dev/null 2>&1 || true
EOF
chmod 0755 /usr/libexec/azl-keyring-empty-unlock

mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/azl-keyring-empty-unlock.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Azure Linux Desktop keyring auto-unlock
Comment=Silently creates/unlocks the login keyring with an empty password so autologin sessions never see the "Choose password for new keyring" prompt
Exec=/usr/libexec/azl-keyring-empty-unlock
OnlyShowIn=GNOME;
NoDisplay=true
X-GNOME-Autostart-Notify=false
EOF
# Belt-and-suspenders: make sure there's no leftover keyring file with a
# real (non-empty) password baked in from image-build time. In practice
# liveuser doesn't exist yet at %post time (livesys-main creates it at
# first boot), so this is a no-op on a fresh build - it only matters if
# this kickstart is ever re-run against an already-populated tree. With
# the autostart entry above unlocking with a real empty string on first
# login, gnome-keyring-daemon creates a fresh login.keyring itself with
# an empty password, which then auto-unlocks on every subsequent login
# in that same live session.
rm -f /home/liveuser/.local/share/keyrings/login.keyring 2>/dev/null || true

# GNOME Software uses the DNF5 backend in this image; it may also use
# PackageKit on other dependency resolutions. Allow either backend only
# for the active local wheel user, who already has passwordless sudo.
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/49-azl-desktop-packagekit.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id.indexOf("org.freedesktop.packagekit.") == 0 ||
         action.id.indexOf("org.rpm.dnf.v0.") == 0) &&
        subject.isInGroup("wheel") && subject.local && subject.active) {
        return polkit.Result.YES;
    }
});
EOF

# Standard livemedia-creator housekeeping (same as lorax's own
# fedora-livemedia.ks %post) - tmpfs for /tmp, drop the machine-id/
# random-seed so the booted live image generates its own instead of
# reusing whatever the build chroot had.
systemctl enable tmp.mount
rm -f /var/lib/systemd/random-seed
rm -f /etc/machine-id
touch /etc/machine-id

# azl-growroot.service: grows the root partition and its xfs filesystem
# to fill whatever the actual disk turns out to be, once, on first real
# boot. Written unconditionally here (shared %post, same as everything
# else in this file) but NOT enabled here - only the disk-image variant
# turns it on, via a sed rule in the "Build disk-image kickstart variant"
# step in .github/workflows/build-live-iso.yml. The live ISO's root is a
# read-only squashfs with nothing to grow, so this unit is written but
# stays inert (never enabled, never runs) on that variant - harmless
# either way, but there's no reason to actually run it there.
#
# Why this is needed at all: the disk-image kickstart's `part /
# --fstype=xfs --size=16384 --grow` only grows the root partition to
# fill whatever disk livemedia-creator's --make-disk auto-sized at
# install time (16GB partition + a small pad) - anaconda has no idea the
# GitHub Actions workflow is about to `qemu-img resize` that file up to
# 64G afterward, so the extra ~48GB just sits there as unpartitioned
# space in the qcow2/VHDX file until something grows into it. This is
# the same problem cloud images solve with cloud-init's growpart module;
# this project doesn't want full cloud-init (it's built for local
# QEMU/Hyper-V/VirtualBox/VMware boots, not just cloud datasources), so a
# small dedicated oneshot unit using the same `growpart` tool cloud-init
# itself calls underneath is enough on its own.
#
# findmnt/lsblk based device detection (not a hardcoded /dev/vda or
# /dev/sda) is deliberate: this same qcow2 gets converted to VHDX/VDI/
# VMDK and booted under different hypervisors (virtio-blk, SATA, IDE),
# each of which can present the root disk under a different device name.
cat > /usr/local/sbin/azl-growroot << 'EOF'
#!/bin/bash
# Grow the root partition (via growpart) and its filesystem to fill the
# real disk, once. Safe to re-run: growpart exits 1 with "NOCHANGE" once
# the partition is already at max size. Prefer xfs_growfs on disk images;
# fall back to resize2fs for ext*. Stamp short-circuits later boots.
set -uo pipefail

STAMP=/var/lib/azl-growroot.done
if [ -f "$STAMP" ]; then
    exit 0
fi

if [ -x /usr/bin/plymouth ] && plymouth --ping >/dev/null 2>&1; then
    plymouth show-splash >/dev/null 2>&1 || true
    plymouth display-message --text="Expanding disk and finishing setup. The system will reboot once more." >/dev/null 2>&1 || true
fi

root_src=$(findmnt -no SOURCE /)
root_dev=$(readlink -f "$root_src")
root_name=$(basename "$root_dev")

disk_name=$(lsblk -no PKNAME "$root_dev" 2>/dev/null)
part_num=$(cat "/sys/class/block/$root_name/partition" 2>/dev/null)

if [ -z "$disk_name" ] || [ -z "$part_num" ]; then
    echo "azl-growroot: couldn't resolve parent disk/partition number for $root_dev, skipping" >&2
    touch "$STAMP"
    exit 0
fi

growpart "/dev/$disk_name" "$part_num"
growpart_rc=$?
if [ "$growpart_rc" -ne 0 ] && [ "$growpart_rc" -ne 1 ]; then
    echo "azl-growroot: growpart /dev/$disk_name $part_num failed (exit $growpart_rc)" >&2
fi

fstype=$(findmnt -no FSTYPE / 2>/dev/null || true)
case "$fstype" in
    xfs)
        if ! xfs_growfs /; then
            echo "azl-growroot: xfs_growfs / failed" >&2
        fi
        ;;
    ext4|ext3|ext2)
        if command -v resize2fs >/dev/null 2>&1; then
            if ! resize2fs "$root_dev"; then
                echo "azl-growroot: resize2fs $root_dev failed" >&2
            fi
        fi
        ;;
esac

touch "$STAMP"
EOF
chmod 755 /usr/local/sbin/azl-growroot

cat > /usr/lib/systemd/system/azl-growroot.service << 'EOF'
[Unit]
Description=Grow root partition and filesystem to fill the real disk (first boot only)
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target
ConditionPathExists=!/var/lib/azl-growroot.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/azl-growroot
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
# Deliberately NOT enabled here - see comment above. The line below is a
# stable sed anchor for the disk-image kickstart variant to replace with
# `systemctl enable azl-growroot.service` - it has to be a marker line
# like this, not an `/pattern/a` insert-after-tmp.mount sed rule (which
# is what the first attempt at this used): `systemctl enable` needs the
# unit file to already exist on disk by the time it runs, and the
# service file above isn't written until this point in %post, well
# after `systemctl enable tmp.mount` further up. Inserting the enable
# call there ran it too early and failed with "Failed to enable unit:
# Unit azl-growroot.service does not exist" - confirmed in
# anaconda/dbus.log from the CI run that first tried it. Anchoring the
# sed substitution to this marker's own line, here, right after the
# service file is actually created, fixes that ordering problem.
# AZL_GROWROOT_ENABLE_MARKER

# Snapshot the real, final resolved package list (name-version-release.arch,
# one per line, sorted) from this exact build's actual rpmdb - not a podman
# dry-run from some earlier point in time. The GH Actions workflow pulls
# this file back out of the built ISO afterward and republishes it as
# findings/live-package-list.txt, so that file always reflects what
# actually got installed in the most recent real build instead of going
# stale every time %packages changes.
rpm -qa --qf '%{name}-%{version}-%{release}.%{arch}\n' | sort > /var/log/azl-desktop-package-list.txt

%end
