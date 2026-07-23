# Azure Linux 4.0 Desktop - LIVE ISO BUILD kickstart
#
# This is the only kickstart in the repo right now - the live bootable ISO
# is the sole current deliverable. There used to be a second,
# installable-variant kickstart (azurelinux-desktop.ks, real-disk
# partitioning/bootloader/reboot instead of the live-build-only bits below)
# but it was deleted for now to keep this repo focused on one thing at a
# time; it'll come back once the live ISO itself is in good shape. Built
# with native Fedora tooling (lorax + livemedia-creator --no-virt), not a
# hand-modified Azure Linux installer ISO - see
# findings/live-iso-and-bare-metal.md for why (AZL's own installer wants a
# custom kickstart fetched over the network at install time, which is the
# right path for the eventual bare-metal installer, but is the wrong tool
# for "give me a live GNOME desktop to poke at in a VM").
#
# Bare-metal follow-up to the WSL wslc/WinUI Reactor demo
# (https://www.boxofcables.dev/azure-linux-desktop-a-build-2026-mashup-of-wslc-winui-reactor-and-azure-linux-4-0/).
# Azure Linux 4.0 is a snapshot of Fedora 43 (confirmed: glibc-2.42-10.azl4 vs
# glibc-2.42-4.fc43, systemd-258.4 vs systemd-258 - same upstream versions,
# different build tags). It ships no desktop packages at all: it's a server
# and cloud-native distro. This kickstart installs the real Azure Linux 4.0
# base, then layers GNOME 49 in from Fedora 43 stable, which is only one
# Fedora release ahead of AZL4's own lineage. That one-release gap is the
# whole trick: Fedora rawhide (45) needs glibc symbols AZL4 doesn't have yet,
# Fedora 43 mostly doesn't.
#
# Repo priority policy (dnf5 supports `priority=` natively, no plugin needed):
#   - azl-base / azl-microsoft: priority=1 (win whenever they can satisfy a
#     requirement - this is what keeps /etc/os-release, systemd, and most of
#     the base system genuinely Azure Linux)
#   - fedora / fedora-updates: priority=50 (fill in anything AZL doesn't ship,
#     starting with the entire desktop/GNOME/media stack)
# See ../findings/investigation.md for how this was tested in podman and
# where it breaks down (short version: fine for GNOME plus a normal day-to-day
# app list, NOT fine if you blindly `dnf group install workstation-product-environment`
# in one shot - LibreOffice, NetworkManager plugins, and qemu-desktop all pull
# in soname bumps that fight AZL's frozen packages).

# xconfig/startxonboot + rootpw are lorax/livemedia-creator conventions,
# not needed on the real installable variant since that one boots to
# GDM via services/systemctl directly. url is the primary install source
# livemedia-creator's anaconda --dirinstall wants in addition to the repo
# lines below; azl-base is as good a choice as any since it's cost=1 too.
xconfig --startxonboot
lang en_US.UTF-8
keyboard us
timezone America/New_York --utc
selinux --enforcing
firewall --enabled --ssh
url --url="https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64"
# --hostname matches the installer kickstart's own
# --hostname=azurelinux-desktop (azl-install.ks.in) - this line
# previously had no --hostname at all, which meant the live ISO and the
# installer disagreed on hostname (live fell back to whatever
# NetworkManager/systemd-hostnamed default to, typically "localhost");
# caught during the three-way ISO comparison against the official
# installer, see findings/gh-actions-installer-iso-build.md.
network --bootproto=dhcp --device=link --activate --hostname=azurelinux-desktop
rootpw --lock
# NetworkManager only, not systemd-networkd - matches lorax's own
# fedora-livemedia.ks template; running both on a live image invites the
# exact "which one actually configured the interface" confusion that ate a
# chunk of time on the AZL-installer network debugging above.
# ModemManager dropped from --enabled: it's not in %packages (no cellular/
# WWAN modem support requested), and anaconda hard-fails
# ("NonCriticalInstallationError: Cannot enable ... ModemManager") trying
# to enable a systemd unit for a service that was never installed - only
# list services here for units that are actually part of %packages.
services --disabled=sshd --enabled=gdm,NetworkManager,livesys,livesys-late

# Live-build-only disk layout - livemedia-creator installs into a single
# ext4 filesystem that gets squashed, no real bootloader/EFI/swap/LVM
# needed since none of that persists past the squashfs capture.
bootloader
clearpart --all --initlabel
reqpart
part / --fstype=xfs --size=16384 --grow

# livemedia-creator captures the image once %post finishes and the system
# shuts down cleanly - "shutdown" here, not "reboot" (that's for the real
# installable variant only).
shutdown

# azl-microsoft carries its own real Microsoft-built dotnet packages,
# including a rolling .NET 11 preview channel - going bleeding edge on
# purpose here (same spirit as Edge Canary and VS Code Insiders below), so
# dotnet-sdk-11.0/dotnet-runtime-11.0 (preview) is what's in %packages, not
# the 10.0 LTS-ish line. No excludes needed: installing the matched 11.0
# SDK + 11.0 host pair (not mixing SDK 10 with host 11) avoids the
# /usr/bin/dnx file collision entirely (see findings/investigation.md).
#
# dnf5/libdnf5/dnf5daemon-server: AZL ships its own dnf5 stack
# (libdnf5-5.2.18.0-2.azl4), but Fedora's gnome-software-50.3 has a hard
# floor of dnf5daemon-server(x86-64) >= 5.4.2, which AZL's older build
# can't satisfy - can't cherry-pick just dnf5daemon-server up to Fedora's
# version without dragging its matching libdnf5 with it. Since
# gnome-software has to come from Fedora anyway (AZL doesn't ship it at
# all), hand the whole dnf5/libdnf5 family to Fedora too rather than
# splitting it - same "don't split a coupled family across repos"
# reasoning as the grub2/shim/fuse3 fix above.
repo --name=azl-base --baseurl=https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64 --cost=1 --excludepkgs=hunspell-en,grub2,grub2-pc,grub2-pc-modules,grub2-efi-x64,grub2-efi-x64-modules,grub2-efi-x64-cdboot,grub2-tools,grub2-tools-extra,grub2-tools-minimal,grub2-common,shim,shim-x64,gsettings-desktop-schemas,dnf5,dnf5daemon-server,dnf5daemon-server-polkit,libdnf5,libdnf5-cli,libdnf5-plugin-actions,libdnf5-plugin-appstream,libdnf5-plugin-expired-pgp-keys,libdnf5-plugin-local
repo --name=azl-microsoft --baseurl=https://packages.microsoft.com/azurelinux/4.0/beta/microsoft/x86_64 --cost=1 --excludepkgs=hunspell-en,grub2,grub2-pc,grub2-pc-modules,grub2-efi-x64,grub2-efi-x64-modules,grub2-efi-x64-cdboot,grub2-tools,grub2-tools-extra,grub2-tools-minimal,grub2-common,shim,shim-x64,gsettings-desktop-schemas
# Claw-back excludepkgs: forces these specific base/system packages back
# onto Azure Linux's own build instead of Fedora's, on top of the cost=
# tie-break above - cost= only decides between mirrors offering the exact
# same NEVRA, it has no opinion on which repo "owns" a package name when
# the two repos offer genuinely different versions, and Fedora 43 was
# winning nearly everything, not just the GNOME/GUI stack it's actually
# needed for. Same list, same reasoning, and the same verified-with-a-
# real-dnf5-resolve process as kiwi/config.sh's FEDORA_EXCLUDES - see the
# comment there for the full rationale, including why glibc, wpa_supplicant,
# fwupd/fwupd-efi, and fuse3-libs are deliberately NOT on this list despite
# looking like obvious candidates (real ABI/version floors, or a silent-
# drop risk with no AZL fallback at all).
repo --name=fedora43 --baseurl=https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/ --cost=50 --excludepkgs=audit,audit-libs,audit-rules,bash,bluez,bluez-libs,bluez-obexd,bzip2,ca-certificates,chrony,coreutils,coreutils-common,cryptsetup,cryptsetup-libs,dbus,dbus-broker,dbus-common,dbus-daemon,dbus-libs,dbus-tools,device-mapper,device-mapper-event,device-mapper-event-libs,device-mapper-libs,device-mapper-persistent-data,diffutils,dosfstools,e2fsprogs,e2fsprogs-libs,efibootmgr,findutils,firewalld,firewalld-filesystem,gawk,gawk-all-langpacks,grep,gzip,hwdata,iproute,iputils,kbd,kbd-legacy,kbd-misc,kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra,kmod,less,less-color,libaio,libblkid,libcom_err,libfdisk,liblastlog2,libmount,libnm,libsmartcols,libuuid,linux-firmware,linux-firmware-whence,lvm2,lvm2-libs,microcode_ctl,ModemManager-glib,mtools,ncurses,ncurses-base,ncurses-libs,NetworkManager,NetworkManager-libnm,NetworkManager-team,NetworkManager-tui,NetworkManager-wifi,openssh,openssh-clients,openssh-server,patch,polkit,polkit-libs,procps-ng,python3-audit,python3-firewall,python3-libmount,sed,selinux-policy,selinux-policy-targeted,setup,shadow-utils,sudo,sudo-python-plugin,systemd,systemd-boot-unsigned,systemd-container,systemd-libs,systemd-networkd,systemd-pam,systemd-resolved,systemd-shared,systemd-sysusers,systemd-udev,tar,util-linux,util-linux-core,vim-data,vim-minimal,xz,xz-libs,amd-gpu-firmware,amd-ucode-firmware,atheros-firmware,brcmfmac-firmware,cirrus-audio-firmware,intel-audio-firmware,intel-gpu-firmware,mt7xxx-firmware,nvidia-gpu-firmware,nxpwireless-firmware,qcom-wwan-firmware,realtek-firmware,tiwilink-firmware
repo --name=fedora43-updates --baseurl=https://dl.fedoraproject.org/pub/fedora/linux/updates/43/Everything/x86_64/ --cost=50 --excludepkgs=audit,audit-libs,audit-rules,bash,bluez,bluez-libs,bluez-obexd,bzip2,ca-certificates,chrony,coreutils,coreutils-common,cryptsetup,cryptsetup-libs,dbus,dbus-broker,dbus-common,dbus-daemon,dbus-libs,dbus-tools,device-mapper,device-mapper-event,device-mapper-event-libs,device-mapper-libs,device-mapper-persistent-data,diffutils,dosfstools,e2fsprogs,e2fsprogs-libs,efibootmgr,findutils,firewalld,firewalld-filesystem,gawk,gawk-all-langpacks,grep,gzip,hwdata,iproute,iputils,kbd,kbd-legacy,kbd-misc,kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra,kmod,less,less-color,libaio,libblkid,libcom_err,libfdisk,liblastlog2,libmount,libnm,libsmartcols,libuuid,linux-firmware,linux-firmware-whence,lvm2,lvm2-libs,microcode_ctl,ModemManager-glib,mtools,ncurses,ncurses-base,ncurses-libs,NetworkManager,NetworkManager-libnm,NetworkManager-team,NetworkManager-tui,NetworkManager-wifi,openssh,openssh-clients,openssh-server,patch,polkit,polkit-libs,procps-ng,python3-audit,python3-firewall,python3-libmount,sed,selinux-policy,selinux-policy-targeted,setup,shadow-utils,sudo,sudo-python-plugin,systemd,systemd-boot-unsigned,systemd-container,systemd-libs,systemd-networkd,systemd-pam,systemd-resolved,systemd-shared,systemd-sysusers,systemd-udev,tar,util-linux,util-linux-core,vim-data,vim-minimal,xz,xz-libs,amd-gpu-firmware,amd-ucode-firmware,atheros-firmware,brcmfmac-firmware,cirrus-audio-firmware,intel-audio-firmware,intel-gpu-firmware,mt7xxx-firmware,nvidia-gpu-firmware,nxpwireless-firmware,qcom-wwan-firmware,realtek-firmware,tiwilink-firmware
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

# --nocore: the AZL repo has no comps groups so @core is meaningless here.
# GNOME 49 group comes from fedora43
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
# whether the EFI section actually ran. See
# findings/live-iso-and-bare-metal.md for the full root-cause writeup and
# how the first ISO build was hand-recovered without redoing the ~40-minute
# mksquashfs step.
grub2-efi-x64-cdboot
grub2-tools-extra

# GNOME 49 desktop (Fedora 43) - core session only, not the whole
# workstation-product-environment comps group. See investigation.md for why.
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

# The rest of "a normal GNOME 49 desktop" - default viewers, a handful of
# core apps, nothing that pulls in an office suite or a docs/tour/parental-
# controls stack we don't want. Loupe/Papers are the GNOME 49-era renames
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
# findings/live-iso-and-bare-metal.md's "Dependency leak" section. The
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
# findings/final-package-list.txt: fedora-logos-42.0.1-3.fc43.noarch was
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
code-insiders
gh
github-desktop

# .NET - going with the bleeding-edge 11.0 preview line straight from
# azl-microsoft (Microsoft's own build), matching the "stay bleeding edge"
# choice made for Edge Canary and VS Code Insiders elsewhere in this list.
dotnet-sdk-11.0
dotnet-runtime-11.0

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
# during the three-way ISO comparison against the official installer
# and our own installer ISO, see
# findings/gh-actions-installer-iso-build.md.
linux-firmware
bluez
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
# (Skylake-U GT2), and AZL's own package set has nothing for this since it's
# not a concern for cloud VMs. Pulled from Fedora - matters for smooth,
# lower-power video playback in Totem/the browser rather than pure
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
# phase (which installs everything else, including Fedora/AZL repo
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
mkdir -p /mnt/sysimage/usr/share/pixmaps /mnt/sysimage/usr/share/applications
install -m 0644 /workspace/assets/icons/edit.svg /mnt/sysimage/usr/share/pixmaps/edit.svg
install -m 0644 /workspace/assets/icons/powershell.png /mnt/sysimage/usr/share/pixmaps/powershell.png
install -m 0644 /workspace/assets/icons/dotnet.svg /mnt/sysimage/usr/share/pixmaps/dotnet.svg
install -m 0644 /workspace/assets/desktop/edit.desktop /mnt/sysimage/usr/share/applications/edit.desktop
install -m 0755 /workspace/assets/bin/azl-powershell-terminal /mnt/sysimage/usr/local/bin/azl-powershell-terminal
install -m 0644 /workspace/assets/desktop/org.azurelinux.PowerShell.desktop /mnt/sysimage/usr/share/applications/org.azurelinux.PowerShell.desktop
install -m 0644 /workspace/assets/desktop/dotnet.desktop /mnt/sysimage/usr/share/applications/dotnet.desktop

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
mkdir -p /mnt/sysimage/usr/share/backgrounds/azurelinux
install -m 0644 /workspace/assets/wallpapers/adwaita-l.jpg /mnt/sysimage/usr/share/backgrounds/azurelinux/adwaita-l.jpg
install -m 0644 /workspace/assets/wallpapers/adwaita-d.jpg /mnt/sysimage/usr/share/backgrounds/azurelinux/adwaita-d.jpg
# GitHub Copilot's desktop app (the "github" Tauri app) has a real,
# versioned release asset on GitHub but no public yum repo - side-load it
# instead of pretending it belongs in a repo definition. Always grab
# whatever the latest release actually is instead of hand-pinning a
# version number - there's no feed to track otherwise, so ask the GitHub
# API each build.
COPILOT_GUI_URL=$(curl -fsSL https://api.github.com/repos/github/app/releases/latest \
    | grep -o '"browser_download_url": *"[^"]*linux-x64\.rpm"' \
    | head -1 | cut -d'"' -f4)
if [ -n "$COPILOT_GUI_URL" ]; then
    curl -Lo /mnt/sysimage/root/thirdparty/github-copilot.rpm "$COPILOT_GUI_URL"
    if [ ! -s /mnt/sysimage/root/thirdparty/github-copilot.rpm ]; then
        echo "WARNING: github-copilot.rpm download failed or is empty" >&2
        rm -f /mnt/sysimage/root/thirdparty/github-copilot.rpm
    fi
else
    echo "WARNING: could not resolve a linux-x64.rpm asset URL for github/app latest release" >&2
fi

# GitHub Copilot CLI is a standalone binary archive. Stage the archive and
# verify its published checksum while network access exists; the later
# chrooted post only extracts the verified local payload.
COPILOT_ARCHIVE="copilot-linux-x64.tar.gz"
curl -fL --retry 3 -o "/mnt/sysimage/root/thirdparty/$COPILOT_ARCHIVE" \
    "https://github.com/github/copilot-cli/releases/latest/download/$COPILOT_ARCHIVE"
curl -fL --retry 3 -o /mnt/sysimage/root/thirdparty/copilot-SHA256SUMS.txt \
    https://github.com/github/copilot-cli/releases/latest/download/SHA256SUMS.txt
(
    cd /mnt/sysimage/root/thirdparty
    grep -E " [*]?$COPILOT_ARCHIVE$" copilot-SHA256SUMS.txt | sha256sum -c -
)

# microsoft/edit - Microsoft's small modeless terminal text editor. No
# RPM, ships as a tar.gz per-arch on GitHub releases. Same "ask the API
# for the latest" approach as Copilot GUI above.
EDIT_URL=$(curl -fsSL https://api.github.com/repos/microsoft/edit/releases/latest \
    | grep -o '"browser_download_url": *"[^"]*x86_64-linux-gnu\.tar\.gz"' \
    | head -1 | cut -d'"' -f4)
if [ -n "$EDIT_URL" ]; then
    curl -Lo /mnt/sysimage/root/thirdparty/edit.tar.gz "$EDIT_URL"
    if [ ! -s /mnt/sysimage/root/thirdparty/edit.tar.gz ]; then
        echo "WARNING: edit.tar.gz download failed or is empty" >&2
        rm -f /mnt/sysimage/root/thirdparty/edit.tar.gz
    fi
else
    echo "WARNING: could not resolve a x86_64-linux-gnu.tar.gz asset URL for microsoft/edit latest release" >&2
fi

# Flathub's .flatpakrepo file, staged here for the same reason as the
# GitHub side-loads above: the regular chrooted %post has no network in
# livemedia-creator --no-virt builds, so a plain `flatpak remote-add
# https://dl.flathub.org/...` down there silently no-ops (the `|| true`
# on that line was masking a `curl: (6) Could not resolve host` failure
# on every build so far - confirmed by run 29580742319 shipping with
# /var/lib/flatpak/repo/refs/remotes completely empty and no [remote
# "flathub"] section in its config, i.e. GNOME Software has and always
# had zero flatpak apps to show). Fetch the real file here instead,
# where network works, and let the chrooted %post add it from local
# disk with no network dependency at all.
curl -fsSL https://dl.flathub.org/repo/flathub.flatpakrepo -o /mnt/sysimage/root/thirdparty/flathub.flatpakrepo
if [ ! -s /mnt/sysimage/root/thirdparty/flathub.flatpakrepo ]; then
    echo "WARNING: flathub.flatpakrepo download failed or is empty" >&2
    rm -f /mnt/sysimage/root/thirdparty/flathub.flatpakrepo
fi
%end

%post --log=/var/log/azl-desktop-post.log
set -x

# Persist the same repo priority policy post-install, so `dnf install
# <whatever>` next year still prefers Azure Linux first and only falls back
# to Fedora 43 when AZL has no package. Known soname landmines get an
# exclude here as they're discovered - add to this list, don't fight it.
FEDORA_EXCLUDES="audit,audit-libs,audit-rules,bash,bluez,bluez-libs,bluez-obexd,bzip2,ca-certificates,chrony,coreutils,coreutils-common,cryptsetup,cryptsetup-libs,dbus,dbus-broker,dbus-common,dbus-daemon,dbus-libs,dbus-tools,device-mapper,device-mapper-event,device-mapper-event-libs,device-mapper-libs,device-mapper-persistent-data,diffutils,dosfstools,e2fsprogs,e2fsprogs-libs,efibootmgr,findutils,firewalld,firewalld-filesystem,gawk,gawk-all-langpacks,grep,gzip,hwdata,iproute,iputils,kbd,kbd-legacy,kbd-misc,kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra,kmod,less,less-color,libaio,libblkid,libcom_err,libfdisk,liblastlog2,libmount,libnm,libsmartcols,libuuid,linux-firmware,linux-firmware-whence,lvm2,lvm2-libs,microcode_ctl,ModemManager-glib,mtools,ncurses,ncurses-base,ncurses-libs,NetworkManager,NetworkManager-libnm,NetworkManager-team,NetworkManager-tui,NetworkManager-wifi,openssh,openssh-clients,openssh-server,patch,polkit,polkit-libs,procps-ng,python3-audit,python3-firewall,python3-libmount,sed,selinux-policy,selinux-policy-targeted,setup,shadow-utils,sudo,sudo-python-plugin,systemd,systemd-boot-unsigned,systemd-container,systemd-libs,systemd-networkd,systemd-pam,systemd-resolved,systemd-shared,systemd-sysusers,systemd-udev,tar,util-linux,util-linux-core,vim-data,vim-minimal,xz,xz-libs,amd-gpu-firmware,amd-ucode-firmware,atheros-firmware,brcmfmac-firmware,cirrus-audio-firmware,intel-audio-firmware,intel-gpu-firmware,mt7xxx-firmware,nvidia-gpu-firmware,nxpwireless-firmware,qcom-wwan-firmware,realtek-firmware,tiwilink-firmware"
cat > /etc/yum.repos.d/azl-desktop-fedora.repo << EOF
[fedora43]
name=Fedora 43 (GNOME 49 desktop stack)
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
# system's /etc/yum.repos.d automatically, unlike the AZL repos (shipped by
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

# Known conflicts as of this writing (see findings/investigation.md).
# hunspell-en: Fedora and AZL both ship it, identical file paths, no version
# skew - just pick one. grub2/shim family: AZL's own grub2-tools-minimal
# links against libfuse3.so.3, Fedora's flatpak/xdg-desktop-portal need
# libfuse3.so.4 - can't have both, so hand the *whole* bootloader family to
# Fedora rather than cherry-picking fuse3 out from under AZL's grub2 (that
# just moves the same conflict one layer down). gsettings-desktop-schemas:
# AZL ships 49.1 (its Fedora-43 lineage), gnome-shell-50.3 needs >=50~alpha -
# plain version floor, no ABI risk, let Fedora's copy win.
sed -i '/^\[azl-base\]/,/^\[/ s/^enabled=1/enabled=1\nexclude=hunspell-en grub2 grub2-pc grub2-pc-modules grub2-efi-x64 grub2-efi-x64-modules grub2-tools grub2-tools-minimal grub2-common shim shim-x64 gsettings-desktop-schemas dnf5 dnf5daemon-server dnf5daemon-server-polkit libdnf5 libdnf5-cli libdnf5-plugin-actions libdnf5-plugin-appstream libdnf5-plugin-expired-pgp-keys libdnf5-plugin-local/' /etc/yum.repos.d/azurelinux.repo 2>/dev/null || true
sed -i '/^\[azl-microsoft\]/,/^\[/ s/^enabled=1/enabled=1\nexclude=hunspell-en grub2 grub2-pc grub2-pc-modules grub2-efi-x64 grub2-efi-x64-modules grub2-tools grub2-tools-minimal grub2-common shim shim-x64 gsettings-desktop-schemas/' /etc/yum.repos.d/azurelinux.repo 2>/dev/null || true
# Keep the version-locked Fedora GRUB family together during later updates.
sed -i '/^\[azl-base\]/,/^\[/ s/^exclude=/&grub2-tools-extra /' /etc/yum.repos.d/azurelinux.repo 2>/dev/null || true
sed -i '/^\[azl-microsoft\]/,/^\[/ s/^exclude=/&grub2-tools-extra /' /etc/yum.repos.d/azurelinux.repo 2>/dev/null || true

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

# System-wide always-on dark mode. /etc/dconf/db/local.d is the standard
# "default value, but still user-overridable" mechanism - liveuser (or
# anyone else) can still flip back to light mode from Settings, this just
# changes what a fresh session starts with. Needs a matching
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
EOF
cat > /etc/dconf/profile/user << 'EOF'
user-db:user
system-db:local
EOF
dconf update || true

# Install the GitHub Copilot GUI RPM, Copilot CLI, and microsoft/edit from
# the local files staged by the earlier %post --nochroot block (see above
# - regular %post has no network in livemedia-creator --no-virt builds,
# confirmed via a real build log ("curl: (6) Could not resolve host:
# api.github.com"), so none of this can curl anything itself anymore).
if [ -f /root/thirdparty/github-copilot.rpm ]; then
    rpm -i /root/thirdparty/github-copilot.rpm || true
fi
tar -xzf /root/thirdparty/copilot-linux-x64.tar.gz -C /usr/local/bin copilot
chmod 0755 /usr/local/bin/copilot
test -x /usr/local/bin/copilot
if [ -f /root/thirdparty/edit.tar.gz ]; then
    tar -xzf /root/thirdparty/edit.tar.gz -C /tmp \
        && install -m 0755 /tmp/edit /usr/local/bin/edit \
        && rm -rf /tmp/edit
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
# the actual installed .desktop files: microsoft-edge-canary.desktop,
# code-insiders.desktop, org.azurelinux.PowerShell.desktop (our own launcher, see
# assets/desktop/), "GitHub Copilot.desktop" (the Tauri app really does
# ship it with a literal space in the filename/ID), and
# org.gnome.Nautilus.desktop. Five apps, matches the latest explicit dock
# list - Terminal dropped off this particular list (still installed,
# still in the app grid, just not pinned).
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
# so the favorite-apps override, welcome-tour suppression, and branding
# copy always run regardless of whether that one file exists this boot.
if [ -f /usr/libexec/livesys/sessions.d/livesys-gnome ]; then
    sed -i "s|^favorite-apps=.*|favorite-apps=['microsoft-edge-canary.desktop', 'code-insiders.desktop', 'org.azurelinux.PowerShell.desktop', 'GitHub Copilot.desktop', 'org.gnome.Nautilus.desktop']|" \
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
# Grow the root partition (via growpart) and its xfs filesystem (via
# xfs_growfs) to fill the real disk, once. Safe to re-run: growpart
# exits 1 with "NOCHANGE" once the partition is already at max size, and
# xfs_growfs is always safe to run against an already-full-size xfs
# filesystem. The stamp file below still short-circuits every boot after
# the first so this doesn't re-scan block devices forever.
set -uo pipefail

STAMP=/var/lib/azl-growroot.done
if [ -f "$STAMP" ]; then
    exit 0
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

if ! xfs_growfs /; then
    echo "azl-growroot: xfs_growfs / failed" >&2
fi

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
systemctl enable azl-growroot.service

# Snapshot the real, final resolved package list (name-version-release.arch,
# one per line, sorted) from this exact build's actual rpmdb - not a podman
# dry-run from some earlier point in time. The GH Actions workflow pulls
# this file back out of the built ISO afterward and republishes it as
# findings/final-package-list.txt, so that file always reflects what
# actually got installed in the most recent real build instead of going
# stale every time %packages changes.
rpm -qa --qf '%{name}-%{version}-%{release}.%{arch}\n' | sort > /var/log/azl-desktop-package-list.txt

%end

# --make-disk produces a normal installed system, not a live-media
# environment. livesys-scripts therefore never creates the live ISO's
# liveuser account at boot, even though the shared kickstart's GDM
# configuration still autologins that account. Create it in the
# disk-image variant after the shared kickstart's %post sections run.
%post --log=/var/log/azl-disk-image-user-post.log
if ! id liveuser >/dev/null 2>&1; then
    useradd --create-home --groups wheel liveuser
    passwd -d liveuser
fi
if [ -x /usr/bin/pwsh ]; then
    usermod --shell /usr/bin/pwsh liveuser
fi

# livesys-gnome writes this list at live-media boot. A normal
# installed disk does not run that service, so provide the same
# defaults through the persistent system dconf database.
cat > /etc/dconf/db/local.d/01-azl-desktop-favorites << 'DCONF'
[org/gnome/shell]
favorite-apps=['microsoft-edge-canary.desktop', 'code-insiders.desktop', 'org.azurelinux.PowerShell.desktop', 'GitHub Copilot.desktop', 'org.gnome.Nautilus.desktop']
welcome-dialog-last-shown-version='4294967295'
DCONF
dconf update

# Apply the live session's GNOME Software behavior persistently.
# Software remains available on demand, but it does not launch or
# download updates in the background for the passwordless account.
cat >> /usr/share/glib-2.0/schemas/org.gnome.software.gschema.override << 'GSETTINGS'
[org.gnome.software]
allow-updates=false
download-updates=false
GSETTINGS
rm -f /etc/xdg/autostart/org.gnome.Software.desktop
cat >> /usr/share/gnome-shell/search-providers/org.gnome.Software-search-provider.ini << 'SEARCH'
DefaultDisabled=true
SEARCH
glib-compile-schemas /usr/share/glib-2.0/schemas

# livesys-gnome marks its ephemeral live account as initialized.
# The disk account is persistent, so create the same marker once.
install -d -o liveuser -g liveuser /home/liveuser/.config
touch /home/liveuser/.config/gnome-initial-setup-done
chown liveuser:liveuser /home/liveuser/.config/gnome-initial-setup-done

# --make-disk creates the initramfs before the shared kickstart
# finishes installing the custom theme. Rebuild it after all
# post-install configuration so the disk boots through Plymouth.
if [ -x /usr/sbin/plymouth-set-default-theme ]; then
    plymouth-set-default-theme azurelinux --rebuild-initrd
fi

# The privileged build container exposes the GitHub runner's
# block devices to Anaconda. Disable GRUB's OS probe before
# regenerating its config so the runner's Ubuntu installation
# cannot become boot-menu entries in this image.
cat >> /etc/default/grub << 'GRUBDEF'
GRUB_DISABLE_OS_PROBER=true
GRUB_DISTRIBUTOR="Azure Linux Desktop"
GRUBDEF
grub2-mkconfig -o /boot/grub2/grub.cfg

# BLS entries use PRETTY_NAME from Azure Linux's own os-release,
# which correctly remains Azure Linux. Apply desktop branding
# only to the menu title, both for the installed kernel and
# every kernel added later.
install -d /etc/kernel/install.d
cat > /etc/kernel/install.d/99-azl-desktop-title.install << 'TITLEHOOK'
#!/bin/sh
if [ "$1" = add ]; then
    for entry in /boot/loader/entries/*-"$2".conf; do
        [ -f "$entry" ] || continue
        sed -i 's/^title .*/title Azure Linux Desktop/' "$entry"
    done
fi
TITLEHOOK
chmod 0755 /etc/kernel/install.d/99-azl-desktop-title.install
for entry in /boot/loader/entries/*.conf; do
    [ -f "$entry" ] || continue
    sed -i 's/^title .*/title Azure Linux Desktop/' "$entry"
done
%end
