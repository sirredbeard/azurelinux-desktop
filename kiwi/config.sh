#!/bin/bash
# KIWI config.sh - post-bootstrap configuration for the Azure Linux
# Desktop offline Anaconda installer ISO.
#
# Adapted from Microsoft's vm-iso-installer/config.sh (microsoft/azurelinux,
# commit pinned in reference/azl-installer/README.md): offline repo download
# and validate, @@PACKAGES@@ kickstart templating, welcome banner / autologin.
# INSTALL_PKGS is the full GNOME desktop plus Microsoft/GitHub tooling from
# the mixed Azure Linux + Fedora repos (not a minimal base). Side-loads
# (GitHub Copilot GUI/CLI, microsoft/edit, Flathub remote, .NET 11 tarball,
# Microsoft Copilot GTK Flatpak OSTree) and branding assets stage here
# because this is the only networked step in the KIWI pipeline. Keep the
# list aligned with kickstart/azurelinux-desktop-live.ks %packages (minus
# live-only packages).
set -euo pipefail

echo "=== Architecture: x86_64 (this project only ever builds x86_64) ==="

#----------------------------------------------------------------------
# Single source of truth for target-install packages.
# Same GNOME desktop + Microsoft/GitHub tooling stack as
# kickstart/azurelinux-desktop-live.ks's %packages - see that file for
# the full per-package reasoning, not repeated here. Live-only packages
# (livesys-scripts, anaconda-live, dracut-config-generic,
# glibc-all-langpacks) are left out; this is a real disk install.
#
# Anaconda adds grub2-tools-extra to every UEFI bootloader transaction even
# though it is not a kickstart package. Keep it in the offline support set
# with its matching Fedora GRUB dependency family.
#----------------------------------------------------------------------
INSTALL_PKGS=(
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
    tar
    ncurses
    ca-certificates
    openssl
    setup
    shadow-utils
    util-linux
    selinux-policy-targeted
    audit
    chrony
    cryptsetup
    firewalld
    iproute
    NetworkManager
    # NetworkManager-wifi/wpa_supplicant: same "no CI build-time
    # evidence either way, so list it explicitly" story as linux-
    # firmware/bluez/fwupd/microcode_ctl below (see that block's
    # comment for the full reasoning) - the live ISO's lorax/
    # livemedia-creator build pulls both in as weak deps of
    # NetworkManager automatically (confirmed in its build log), so
    # without listing them explicitly here a real Anaconda-driven
    # install could plausibly end up with no way to see or associate to
    # any WiFi network at all, not even an unencrypted one. Caught
    # during the three-way ISO comparison; see
    # findings/kiwi-ng-installer-build.md.
    NetworkManager-wifi
    wpa_supplicant

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
    # flatpak conditionally requires its matching policy module whenever
    # the target includes selinux-policy-targeted. Listing it explicitly
    # makes dnf download its Azure policy-utility closure into the offline
    # repo instead of leaving Anaconda to discover a missing provider.
    flatpak-selinux
    gnome-software
    # RPM AppStream + curated chrome; Flathub catalog is baked into the
    # prestaged flatpak-system tree (issue #6).
    appstream-data
    gnome-app-list

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
    # GTK3 Adwaita-dark theme files for gtk-theme='Adwaita-dark' dconf.
    gnome-themes-extra
    evolution
    evolution-ews

    # Hypervisor guest integration — same ship-all set as live kickstart.
    # One offline package set for every converted disk format.
    spice-vdagent
    qemu-guest-agent
    hyperv-daemons
    open-vm-tools
    open-vm-tools-desktop
    virtualbox-guest-additions

    adwaita-sans-fonts
    adwaita-mono-fonts
    liberation-fonts-all
    dejavu-sans-fonts
    google-noto-fonts-common
    # Color emoji for Edge/Chromium and web UIs (GitHub reactions, etc.).
    google-noto-color-emoji-fonts
    default-fonts-core-emoji

    # Full multimedia + GPU stack (parity with live). See
    # findings/h264-intel-media-stack.md.
    gstreamer1-plugins-good
    gstreamer1-plugins-bad-free
    gstreamer1-plugins-ugly-free
    gstreamer1-plugins-ugly
    gstreamer1-plugins-bad-freeworld
    gstreamer1-plugin-openh264
    gstreamer1-plugin-libav
    gstreamer1-vaapi
    ffmpeg
    mesa-dri-drivers
    mesa-vulkan-drivers
    mesa-va-drivers
    vulkan-loader
    libvdpau
    # VDPAU→VA-API bridge for Intel (no native VDPAU / no mesa-vdpau on 25.3).
    libvdpau-va-gl

    microsoft-edge-canary
    powershell
    azure-cli
    code-insiders
    gh
    github-desktop


    upower
    power-profiles-daemon
    thermald
    switcheroo-control
    brightnessctl

    # linux-firmware/bluez/fwupd/microcode_ctl: all four ship straight
    # from azl-base (confirmed via dnf5 repoquery against
    # packages.microsoft.com/azurelinux/4.0/beta/base/x86_64 - not a
    # Fedora fallback), and ride along as weak/Recommends-level deps of
    # kernel/NetworkManager on the live ISO's lorax/livemedia-creator
    # build (confirmed present in that build's own transaction log; see
    # kickstart/azurelinux-desktop-live.ks's comment on the same four
    # packages). This installer ISO's actual on-disk install happens
    # later, at real install time, via Anaconda executing this
    # kickstart's %packages against the offline repo kiwi/config.sh
    # bundles onto the ISO - a step this project's CI build never
    # exercises (CI only builds the ISO itself, it does not boot and
    # run Anaconda against it), so there is no build-log evidence
    # either way for whether Anaconda's own dnf/libdnf would resolve
    # these four as weak deps the way lorax's did. Rather than leave
    # that as an open question a real hardware install could get bitten
    # by, all four are listed explicitly here - caught during the
    # three-way ISO comparison against the official installer and our
    # own live ISO, see findings/kiwi-ng-installer-build.md.
    # microcode_ctl is listed explicitly on the live ISO too now for
    # the same real-hardware reason (CPU microcode updates, not a VM/
    # USB concern) - it turned out the live ISO's own prior "ships
    # microcode_ctl already" comment was never actually true; confirmed
    # absent from that build's own transaction log.
    linux-firmware
    # Intel WiFi: AZL splits iwlwifi firmware out of linux-firmware;
    # iwlwifi.ko ships via azurelinux-desktop-intel-kmod (policy pull).
    # Explicit list so Anaconda offline installs get a wlan device on
    # Intel laptops - see findings/wifi-missing-on-bare-metal.md.
    iwlwifi-mvm-firmware
    iwlwifi-dvm-firmware
    iwlwifi-mld-firmware
    iwlegacy-firmware
    bluez
    # Audio/BT userspace for OOT sound + bluetooth kmods (AZL).
    intel-audio-firmware
    alsa-ucm
    NetworkManager-bluetooth
    fwupd
    microcode_ctl

    libva
    # RPM Fusion nonfree full iHD (H.264/HEVC). Not Fedora's free-only
    # libva-intel-media-driver. See findings/intel-hw-video-accel.md.
    intel-media-driver
    intel-mediasdk

    plymouth
    plymouth-plugin-script
    plymouth-plugin-label

    libayatana-appindicator-gtk3

    # System git for GitHub Copilot GUI (LOCAL_GIT_DIRECTORY=/usr). Bundled
    # dugite git needs libcurl-gnutls, which AZL/Fedora do not ship.
    git

    # Fedora's live-media Anaconda stack requires fedora-logos on the
    # supported package baseline. The live ISO already resolves that
    # dependency, so the installer deliberately follows it rather than
    # adding an installer-only generic-logos conflict.
)

# Extra packages needed in the offline repo for anaconda's own
# runtime/bootloader deps but not listed directly in the kickstart
# %packages (upstream's own EXTRA_REPO_PKGS pattern).
EXTRA_REPO_PKGS=(
    grub2-efi-x64-cdboot
    grub2-tools-extra
    lvm2
    e2fsprogs
    dosfstools
    device-mapper-persistent-data
    mtools
    libaio
    # Blivet marks NVMeNamespaceDevice as needing nvme-cli. Anaconda then
    # adds it via Storage.collect_requirements() during package resolve.
    # Without it in the offline repo, offline NVMe installs warn/fail with
    # NonCriticalInstallationError: No match for argument: nvme-cli.
    # Package exists in Azure Linux base (same name as Fedora).
    nvme-cli
)

#----------------------------------------------------------------------
# Download every target-install package + all transitive deps, from
# every repo this project's live ISO already uses, into one offline
# repo directory. Mirrors upstream's single dnf5 download call, just
# fanned out across repos instead of one, with the same repo cost the
# live kickstart's own `repo --cost=` lines use (azl-base/azl-microsoft
# =1, Fedora/RPM Fusion=50), enforced here via --setopt=<repo>.cost=
# instead of a kickstart `repo` line's --cost flag, since this is a
# `dnf5 download`, not an install. See the note further down explaining
# why this has to be cost=, not priority= - priority= turned out to be
# a much stronger, and here actively harmful, mechanism.
#----------------------------------------------------------------------
OFFLINE_REPO="/opt/azl-offline-repo"
mkdir -p "$OFFLINE_REPO"

# Same excludes as the live ISO's per-repo `--excludepkgs=` (see
# kickstart/azurelinux-desktop-live.ks's repo lines) - keeps AZL's own
# grub2/shim/dnf5 family and gsettings-desktop-schemas out of the way
# on the AZL repos specifically, so Fedora's copies (which the desktop
# stack actually needs, see the live ISO's own comments on the fuse3/
# grub2 ABI fork and gnome-software's dnf5daemon-server version floor)
# win instead. This has to be scoped per-repo with --setopt=<repo>.
# excludepkgs=..., NOT the blanket `dnf5 download --exclude=` flag -
# that flag excludes a package from every repo in the transaction, which
# would have dropped grub2/shim/dnf5/gsettings-desktop-schemas from the
# offline repo entirely (Fedora's copies excluded right along with
# AZL's), instead of just making AZL's copies lose to Fedora's. Same
# reasoning for ms-prod's aznfs/mdatp exclude - scoped to that repo only,
# matching the live ISO's `repo --name=ms-prod --excludepkgs=aznfs,mdatp`
# line exactly instead of a global exclude.
AZL_BASE_EXCLUDES="hunspell-en,grub2,grub2-pc,grub2-pc-modules,grub2-efi-x64,grub2-efi-x64-modules,grub2-efi-x64-cdboot,grub2-tools,grub2-tools-extra,grub2-tools-minimal,grub2-common,shim,shim-x64,gsettings-desktop-schemas,dnf5,dnf5daemon-server,dnf5daemon-server-polkit,libdnf5,libdnf5-cli,libdnf5-plugin-actions,libdnf5-plugin-appstream,libdnf5-plugin-expired-pgp-keys,libdnf5-plugin-local"
AZL_MICROSOFT_EXCLUDES="hunspell-en,grub2,grub2-pc,grub2-pc-modules,grub2-efi-x64,grub2-efi-x64-modules,grub2-efi-x64-cdboot,grub2-tools,grub2-tools-extra,grub2-tools-minimal,grub2-common,shim,shim-x64,gsettings-desktop-schemas"
MS_PROD_EXCLUDES="aznfs,mdatp"

# Claw-back list: forces these specific base/system packages to resolve
# to Azure Linux's own build instead of Fedora's, on top of the cost=
# tie-break above. cost= only decides between mirrors offering the exact
# same NEVRA - it has no opinion on which repo "owns" a package name when
# the two repos offer genuinely different versions, and Fedora 43 is
# currently ahead of Azure Linux 4.0's frozen beta base for almost every package
# they both ship, so left alone, cost= let Fedora win nearly everything,
# not just the GNOME/GUI stack it's actually needed for. This list is
# scoped to fedora43/fedora43-updates only (excludepkgs on THOSE repos,
# not a blanket dnf5 --exclude=), the same mechanism as the AZL-side
# excludes above, just pointed the other direction: it makes AZL's copy
# the only candidate for these names while leaving Fedora free to win
# everything else, GNOME/GTK/glibc included.
#
# Every package on this list was verified with a real `dnf5 download
# --resolve --alldeps` reproduction (scripts/podman-test-azl4-fedora43.sh)
# before landing here - some real, non-negotiable ABI/version floors
# forced exclusions from this list even though they looked like obvious
# candidates at first:
#   - glibc (and glibc-common/-minimal-langpack/-gconv-extra/-all-
#     langpacks/-langpack-en): gtk4 (a hard dependency of gnome-shell)
#     requires GLIBC_2.43 symbol versioning Azure Linux 4.0's glibc build doesn't
#     provide - confirmed via dnf5's own resolver conflict output. This
#     is the same "hand the whole family to whichever repo can keep it
#     internally consistent" call already made for grub2/shim/fuse3.
#   - wpa_supplicant: has no Azure Linux build at all. Excluding it from
#     Fedora with no AZL fallback doesn't produce a hard failure with
#     --skip-unavailable in play - it just silently disappears from the
#     offline repo, which would have broken WiFi WPA/WPA2 auth. Verified
#     by listing the resulting offline repo directly, not by trusting a
#     clean dnf5 exit code.
#   - fwupd/fwupd-efi: Azure Linux 4.0's fwupd build is ELF-linked against
#     libcbor.so.0.12; gnome-connections (a directly-installed GUI app)
#     pulls in Fedora's freerdp-libs, which is linked against
#     libcbor.so.0.13 - two incompatible sonames of a same-named
#     "libcbor" package can't both be installed at once. Fedora's fwupd
#     build is fully functional (firmware updates aren't laptop-model-
#     specific to who built the package), so it stays on Fedora rather
#     than break gnome-connections. fwupd-efi has no Fedora build at
#     all and resolves to Azure Linux 4.0 either way.
# Sibling library packages that share an exact version-locked NEVRA with
# an already-clawed-back package (util-linux's libblkid/libmount/libuuid/
# libfdisk/libsmartcols, e2fsprogs's libcom_err, xz's xz-libs) are
# included here too - leaving them off this list while clawing back their
# parent package produces the same class of failure fwupd/libcbor did:
# the parent hard-requires its own exact sibling version, but cost= would
# have let Fedora's newer sibling win the tie on its own, breaking the
# parent's dependency. Confirmed ABI-compatible (identical max symbol
# versions in both builds) before adding, unlike the fuse3/libfuse3.so.3-
# vs-.so.4 case, which is a genuine soname fork and is deliberately left
# off this list so both builds can coexist for their respective
# consumers.
FEDORA_EXCLUDES="audit,audit-libs,audit-rules,bash,bluez,bluez-libs,bluez-obexd,bzip2,ca-certificates,chrony,coreutils,coreutils-common,cryptsetup,cryptsetup-libs,dbus,dbus-broker,dbus-common,dbus-daemon,dbus-libs,dbus-tools,device-mapper,device-mapper-event,device-mapper-event-libs,device-mapper-libs,device-mapper-persistent-data,diffutils,dosfstools,e2fsprogs,e2fsprogs-libs,efibootmgr,findutils,firewalld,firewalld-filesystem,gawk,gawk-all-langpacks,grep,gzip,hwdata,iproute,iputils,kbd,kbd-legacy,kbd-misc,kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra,kmod,less,less-color,libaio,libblkid,libcom_err,libfdisk,liblastlog2,libmount,libnm,libsmartcols,libuuid,linux-firmware,linux-firmware-whence,lvm2,lvm2-libs,microcode_ctl,ModemManager-glib,mtools,ncurses,ncurses-base,ncurses-libs,NetworkManager,NetworkManager-libnm,NetworkManager-team,NetworkManager-tui,NetworkManager-wifi,NetworkManager-bluetooth,alsa-ucm,alsa-lib,openssh,openssh-clients,openssh-server,patch,polkit,polkit-libs,procps-ng,python3-audit,python3-firewall,python3-libmount,sed,setup,shadow-utils,sudo,sudo-python-plugin,systemd,systemd-boot-unsigned,systemd-container,systemd-libs,systemd-networkd,systemd-pam,systemd-resolved,systemd-shared,systemd-sysusers,systemd-udev,tar,util-linux,util-linux-core,vim-data,vim-minimal,xz,xz-libs,amd-gpu-firmware,amd-ucode-firmware,atheros-firmware,brcmfmac-firmware,cirrus-audio-firmware,intel-audio-firmware,intel-gpu-firmware,mt7xxx-firmware,nvidia-gpu-firmware,nxpwireless-firmware,qcom-wwan-firmware,realtek-firmware,tiwilink-firmware,iwlegacy-firmware,iwlwifi-dvm-firmware,iwlwifi-mld-firmware,iwlwifi-mvm-firmware"

# RPMFusion is where the real (patent-encumbered) ffmpeg/h264/aac
# gstreamer plugins come from - Fedora's own gstreamer1-plugins-* builds
# are patent-clean only, same reasoning kickstart/azurelinux-desktop-
# live.ks documents. The live ISO's repo --mirrorlist= form can't be used
# here: `dnf5 download --repofrompath=id,PATH` takes a real baseurl, not
# a mirrorlist redirector (confirmed against dnf5's own --help text), so
# this points straight at a real RPMFusion mirror's release tree instead
# of the mirrorlist CGI. Missing this entirely was the first real gap
# found in a deep-dive comparison against the live ISO: ffmpeg and
# gstreamer1-plugin-libav are both in INSTALL_PKGS but neither Fedora nor Azure
# Linux's own repos carry them, so without this the offline-repo
# download would have silently dropped them and the dry-run validation
# below would have failed the whole build on missing packages.
#
# multilib_policy=best alone did not stop `dnf5 download --alldeps` from
# still pulling in i686 siblings of multilib-capable packages (alldeps
# appears to walk every arch's dependency chain regardless of that
# setopt) - e.g. libpeas1-gtk-1.36.0-13.fc43.i686 next to the .x86_64
# build totem actually needs, which then conflict with each other
# ("has inferior architecture" / "conflicts with libpeas-gtk < 2.0").
# --arch=x86_64,noarch is dnf5 download's own hard architecture filter
# and is what actually keeps i686 packages out (despite the "ARCH,..."
# in dnf5's own --help text, a single comma-joined value is parsed as
# one literal unknown arch string - confirmed it has to be repeated,
# --arch=x86_64 --arch=noarch, to filter to both). This project only
# ever builds/targets x86_64 (see the architecture banner at the top of
# this file) - there's no multilib use case here to keep both arches for.
#
# cost=, not priority=: the live kickstart's own repo lines use `repo
# --cost=1` (AZL/Microsoft repos) and `--cost=50` (Fedora/RPMFusion) -
# cost only breaks ties between repos offering the exact same NEVRA
# (e.g. mirrors), it does not stop dnf from considering a different repo
# entirely for a differently-versioned build of the same package name.
# `--setopt=<repo>.priority=` is a much stronger, different mechanism:
# it excludes every lower-priority repo's candidates outright once a
# higher-priority repo offers a package of that name at all - which,
# combined with excludepkgs on azl-base/azl-microsoft, turned into a
# real bug here. grub2-efi-x64-cdboot and grub2-tools-extra are each
# tightly version-pinned to sibling packages (grub2-common, grub2-tools-
# minimal) from their own build; with azl-base pinned to priority=1,
# dnf5 insisted on azl-base's own grub2-efi-x64-cdboot candidate and
# then hard-failed on its excluded sibling dependency instead of falling
# through to Fedora's self-consistent grub2 family, which never has
# that problem since all of Fedora's grub2 packages are excluded/
# included as one full set. Switching these setopts to cost=, matching
# the live kickstart's own repo config exactly, resolves the same way
# the live ISO's real anaconda install does: azl-base/azl-microsoft
# candidates are still tried first for anything not excluded, but a
# whole-family exclude on one repo cleanly falls through to the other
# repo's complete, self-consistent set instead of that repo's partial
# candidate list hard-failing the transaction.
echo "=== Downloading target-install packages + dependencies ==="
download_offline_rpms() {
# --refresh + metadata_expire=0: always re-fetch repodata so Microsoft /
# GitHub / Fedora package NEVRAs are whatever is latest at build time,
# not a stale cache from an earlier layer or retry.
dnf5 download \
    --refresh \
    --setopt=reposdir=/dev/null \
    --setopt=metadata_expire=0 \
    --setopt=multilib_policy=best \
    --arch=x86_64 \
    --arch=noarch \
    --repofrompath=azl-base,https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64 \
    --repofrompath=azl-microsoft,https://packages.microsoft.com/azurelinux/4.0/beta/microsoft/x86_64 \
    --repofrompath=azl-desktop-kmods,https://sirredbeard.github.io/azurelinux-desktop/repo \
    --repofrompath=fedora43,https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/ \
    --repofrompath=fedora43-updates,https://dl.fedoraproject.org/pub/fedora/linux/updates/43/Everything/x86_64/ \
    --repofrompath=ms-prod,https://packages.microsoft.com/rhel/9/prod/ \
    --repofrompath=vscode,https://packages.microsoft.com/yumrepos/vscode \
    --repofrompath=edge-canary,https://packages.microsoft.com/yumrepos/edge-canary \
    --repofrompath=gh-cli,https://cli.github.com/packages/rpm \
    --repofrompath=github-desktop,https://mirror.mwt.me/shiftkey-desktop/rpm \
    --repofrompath=rpmfusion-free,https://download1.rpmfusion.org/free/fedora/releases/43/Everything/x86_64/os/ \
    --repofrompath=rpmfusion-nonfree,https://download1.rpmfusion.org/nonfree/fedora/releases/43/Everything/x86_64/os/ \
    --setopt=azl-base.cost=1 \
    --setopt=azl-microsoft.cost=1 \
    --setopt=azl-desktop-kmods.cost=1 \
    --setopt=ms-prod.cost=1 \
    --setopt=vscode.cost=1 \
    --setopt=edge-canary.cost=1 \
    --setopt=gh-cli.cost=1 \
    --setopt=github-desktop.cost=1 \
    --setopt=fedora43.cost=50 \
    --setopt=fedora43-updates.cost=50 \
    --setopt=rpmfusion-free.cost=50 \
    --setopt=rpmfusion-nonfree.cost=50 \
    --setopt=azl-base.excludepkgs="$AZL_BASE_EXCLUDES" \
    --setopt=azl-microsoft.excludepkgs="$AZL_MICROSOFT_EXCLUDES" \
    --setopt=ms-prod.excludepkgs="$MS_PROD_EXCLUDES" \
    --setopt=fedora43.excludepkgs="$FEDORA_EXCLUDES" \
    --setopt=fedora43-updates.excludepkgs="$FEDORA_EXCLUDES" \
    --repo=azl-base --repo=azl-microsoft --repo=azl-desktop-kmods --repo=fedora43 --repo=fedora43-updates \
    --repo=ms-prod --repo=vscode --repo=edge-canary --repo=gh-cli --repo=github-desktop \
    --repo=rpmfusion-free --repo=rpmfusion-nonfree \
    --resolve \
    --alldeps \
    --destdir="$OFFLINE_REPO" \
    "${INSTALL_PKGS[@]}" "${EXTRA_REPO_PKGS[@]}"
}

# The offline repository pulls from several independently hosted package
# sources. A transient transfer failure must not discard an otherwise valid
# installer build, but a permanent failure needs its own diagnostic instead
# of only KIWI's generic "config.sh failed" wrapper.
DOWNLOAD_LOG="/var/log/azl-offline-repo-download.log"
for attempt in 1 2 3; do
    if download_offline_rpms 2>&1 | tee "$DOWNLOAD_LOG"; then
        break
    fi

    echo "Offline repository download attempt $attempt failed." >&2
    tail -200 "$DOWNLOAD_LOG" >&2
    if [ "$attempt" -eq 3 ]; then
        exit 1
    fi
    sleep $((attempt * 10))
done

RPM_COUNT=$(find "$OFFLINE_REPO" -maxdepth 1 -type f -name '*.rpm' | wc -l)
echo "=== Downloaded $RPM_COUNT RPMs ==="

createrepo_c "$OFFLINE_REPO"

#----------------------------------------------------------------------
# Validate offline repo completeness (dry-run install) - same check
# upstream runs, catches a missing package here instead of 20 minutes
# into a real anaconda install with no network to fall back on.
#----------------------------------------------------------------------
echo "=== Validating offline repo completeness ==="
DRYRUN_ROOT=$(mktemp -d "$OFFLINE_REPO/.dryrun.XXXXXX")
if ! DRYRUN_OUTPUT=$(dnf5 install \
    --assumeno \
    --installroot="$DRYRUN_ROOT" \
    --releasever=4.0 \
    --setopt=reposdir=/dev/null \
    --repofrompath=offline,"file://$OFFLINE_REPO" \
    --repo=offline \
    "${INSTALL_PKGS[@]}" "${EXTRA_REPO_PKGS[@]}" 2>&1); then
    # DNF returns nonzero after an --assumeno transaction even when it
    # resolved cleanly: it deliberately reports "Operation aborted by the
    # user." after printing the complete transaction. Only that specific
    # post-solver result is success for this dry-run check.
    if ! grep -Fq "Operation aborted by the user." <<<"$DRYRUN_OUTPUT"; then
        rm -rf "$DRYRUN_ROOT"
        echo "!!! FATAL: Offline repo cannot resolve the installer package set!"
        echo "$DRYRUN_OUTPUT"
        exit 1
    fi
fi
rm -rf "$DRYRUN_ROOT"

echo "=== Dry-run passed - all kickstart packages resolve from offline repo ==="

# The KIWI runtime uses the same archived assets as the target installer.
# Select the Azure theme before KIWI assembles its final boot initrd.
if [ -x /usr/sbin/plymouth-set-default-theme ] \
    && [ -f /opt/azl-desktop-assets/plymouth/azurelinux/azurelinux.plymouth ]; then
    install -d -m 0755 /usr/share/plymouth/themes/azurelinux
    install -m 0644 \
        /opt/azl-desktop-assets/plymouth/azurelinux/azurelinux.plymouth \
        /opt/azl-desktop-assets/plymouth/azurelinux/azurelinux.script \
        /opt/azl-desktop-assets/plymouth/azurelinux/dot.png \
        /opt/azl-desktop-assets/plymouth/azurelinux/dot-glow.png \
        /usr/share/plymouth/themes/azurelinux/
    install -m 0644 \
        /opt/azl-desktop-assets/branding/AzureLinuxLogo.png \
        /usr/share/plymouth/themes/azurelinux/azurelinuxlogo.png
    mkdir -p /etc/dracut.conf.d
    printf '%s\n' 'add_dracutmodules+=" plymouth "' > /etc/dracut.conf.d/50-azurelinux-plymouth.conf
    # KMS drivers for graphical Plymouth during the installer boot itself —
    # same set as the live ISO and installed target: virtio-gpu (QEMU virtio
    # VGA), hyperv_drm (Hyper-V Gen2), bochs_drm (QEMU std VGA/BIOS).
    printf '%s\n' 'add_drivers+=" virtio_gpu hyperv_drm bochs_drm "' \
        > /etc/dracut.conf.d/early-kms.conf
    # Same plymouth-quit-wait.service ordering fix as the live ISO
    # (kickstart/azurelinux-desktop-live.ks) - keeps the animation alive
    # for the full installer boot instead of just a second or two.
    mkdir -p /etc/systemd/system/plymouth-quit-wait.service.d
    printf '[Unit]\nAfter=multi-user.target\n' \
        > /etc/systemd/system/plymouth-quit-wait.service.d/wait-for-boot.conf
    plymouth-set-default-theme azurelinux
fi

# Hide cosmetic dracut livenet noise on the installer boot itself:
# parse-livenet.sh calls get_url_handler before the function is sourced.
# Same intent as scripts/patch-dracut-livenet-hook.sh on the live ISO.
# Inline here because KIWI only unpacks assets/ (not scripts/) into the
# image root. Must run before KIWI builds the final boot initrd.
for _hook in \
    /usr/lib/dracut/modules.d/90livenet/parse-livenet.sh \
    /usr/lib/dracut/modules.d/70livenet/parse-livenet.sh; do
    if [ -f "$_hook" ] && grep -Fxq 'get_url_handler' "$_hook"; then
        sed -i '/^get_url_handler$/d' "$_hook"
        echo "Patched stray get_url_handler in $_hook"
    fi
done

# Install Azure Linux Desktop wallpapers (Adwaita light/dark, CC-BY-SA-3.0,
# Jakub Steiner). Stored as JPEG because AZL's glycin build disables JXL.
if [ -f /opt/azl-desktop-assets/wallpapers/adwaita-l.jpg ]; then
    install -d -m 0755 /usr/share/backgrounds/azurelinux
    install -m 0644 \
        /opt/azl-desktop-assets/wallpapers/adwaita-l.jpg \
        /opt/azl-desktop-assets/wallpapers/adwaita-d.jpg \
        /usr/share/backgrounds/azurelinux/
fi

# Bluetooth USB recover helper + PipeWire user presets for the installed
# target (also written by azl-install.ks.in %post). Staged here so the
# offline installer tree already carries them before kickstart runs.
if [ -f /opt/azl-desktop-assets/bluetooth/azurelinux-desktop-bt-usb-reset ]; then
    install -d -m 0755 /usr/libexec /usr/lib/systemd/system \
        /usr/lib/systemd/user-preset
    install -m 0755 \
        /opt/azl-desktop-assets/bluetooth/azurelinux-desktop-bt-usb-reset \
        /usr/libexec/azurelinux-desktop-bt-usb-reset
    install -m 0644 \
        /opt/azl-desktop-assets/systemd/azurelinux-desktop-bt-recover.service \
        /usr/lib/systemd/system/azurelinux-desktop-bt-recover.service
    install -m 0644 \
        /opt/azl-desktop-assets/systemd/azurelinux-desktop-bt-recover-late.service \
        /usr/lib/systemd/system/azurelinux-desktop-bt-recover-late.service
    install -m 0644 \
        /opt/azl-desktop-assets/systemd/80-azurelinux-desktop-pipewire.preset \
        /usr/lib/systemd/user-preset/80-azurelinux-desktop-pipewire.preset
    if [ -f /opt/azl-desktop-assets/udev/80-azurelinux-desktop-bt-power.rules ]; then
        install -d -m 0755 /etc/udev/rules.d
        install -m 0644 \
            /opt/azl-desktop-assets/udev/80-azurelinux-desktop-bt-power.rules \
            /etc/udev/rules.d/80-azurelinux-desktop-bt-power.rules
    fi
    systemctl enable azurelinux-desktop-bt-recover.service 2>/dev/null || true
    systemctl enable azurelinux-desktop-bt-recover-late.service 2>/dev/null || true
fi

# First-boot prepare override for the installed target tree. Also staged
# by azl-install.ks.in; keep both paths so offline media and %post agree.
if [ -f /opt/azl-desktop-assets/polkit-1/rules.d/10-azurelinux-desktop-flatpak.rules ]; then
    install -d -m 0755 /etc/polkit-1/rules.d
    install -m 0644 \
        /opt/azl-desktop-assets/polkit-1/rules.d/10-azurelinux-desktop-flatpak.rules \
        /etc/polkit-1/rules.d/10-azurelinux-desktop-flatpak.rules
fi

# Full RPM OpenPGP key set for gpgcheck=1 on Fedora / MS / GitHub /
# RPM Fusion / project kmods (see assets/pki/rpm-gpg/). Preserve relative
# symlinks (AZL releasever/basearch names). Fail if a required key is absent.
install -d -m 0755 /etc/pki/rpm-gpg
if [ -d /opt/azl-desktop-assets/pki/rpm-gpg ]; then
    for path in /opt/azl-desktop-assets/pki/rpm-gpg/*; do
        [ -e "$path" ] || continue
        base="$(basename "$path")"
        case "$base" in
            *.md|README*) continue ;;
        esac
        if [ -L "$path" ]; then
            ln -sfn "$(readlink "$path")" "/etc/pki/rpm-gpg/$base"
        elif [ -f "$path" ]; then
            install -m 0644 "$path" "/etc/pki/rpm-gpg/$base"
        fi
    done
fi
for key in \
    RPM-GPG-KEY-azurelinux-4.0-primary \
    RPM-GPG-KEY-azurelinux-desktop \
    RPM-GPG-KEY-fedora-43-primary \
    RPM-GPG-KEY-microsoft \
    RPM-GPG-KEY-githubcli \
    RPM-GPG-KEY-shiftkey-desktop \
    RPM-GPG-KEY-rpmfusion-free-fedora-2020 \
    RPM-GPG-KEY-rpmfusion-nonfree-fedora-2020
do
    if [ ! -e "/etc/pki/rpm-gpg/$key" ]; then
        echo "error: required RPM GPG key missing on installer image: $key" >&2
        ls -la /etc/pki/rpm-gpg >&2 || true
        exit 1
    fi
    rpm --import "/etc/pki/rpm-gpg/$key" 2>/dev/null || true
done
if [ -f /opt/azl-desktop-assets/gpg/signing-key.asc ]; then
    install -d -m 0755 /usr/share/azurelinux-desktop/gpg
    install -m 0644 \
        /opt/azl-desktop-assets/gpg/signing-key.asc \
        /usr/share/azurelinux-desktop/gpg/signing-key.asc
elif [ -f /etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop ]; then
    install -d -m 0755 /usr/share/azurelinux-desktop/gpg
    install -m 0644 \
        /etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop \
        /usr/share/azurelinux-desktop/gpg/signing-key.asc
fi

if [ -f /opt/azl-desktop-assets/bin/azl-first-boot-prepare ]; then
    install -d -m 0755 /usr/libexec/azurelinux-desktop \
        /usr/lib/systemd/system/selinux-autorelabel.service.d
    install -m 0755 \
        /opt/azl-desktop-assets/bin/azl-first-boot-prepare \
        /usr/libexec/azurelinux-desktop/azl-first-boot-prepare
    install -m 0644 \
        /opt/azl-desktop-assets/systemd/selinux-autorelabel.service.d/10-azurelinux-desktop.conf \
        /usr/lib/systemd/system/selinux-autorelabel.service.d/10-azurelinux-desktop.conf
fi

#----------------------------------------------------------------------
# Side-load GitHub Copilot GUI/CLI, microsoft/edit, and Flathub's repo
# file the same way the live ISO does - always *latest* release, no
# pinned versions. Shared helper is packed into assets.tar.gz as
# build-helpers/fetch-latest-thirdparty.sh (see build-installer-iso.yml).
# Staged under /opt/azl-offline-extras/ for azl-install.ks.in %post.
#----------------------------------------------------------------------
EXTRAS="/opt/azl-offline-extras"
mkdir -p "$EXTRAS"

echo "=== Staging latest Copilot GUI/CLI, microsoft/edit, Flathub ==="
STAGED="/opt/azl-desktop-assets/thirdparty-latest"
if [ -s "$STAGED/github-copilot.rpm" ] \
    && [ -s "$STAGED/copilot-linux-x64.tar.gz" ] \
    && [ -s "$STAGED/edit.tar.gz" ] \
    && [ -s "$STAGED/dotnet-sdk-linux-x64.tar.gz" ]; then
    # Preferred path: CI pre-fetched on the runner with GITHUB_TOKEN.
    cp -a "$STAGED"/. "$EXTRAS"/
    echo "using pre-fetched thirdparty from assets/thirdparty-latest"
    if [ -f "$EXTRAS/thirdparty-versions.txt" ]; then
        cat "$EXTRAS/thirdparty-versions.txt"
    fi
else
    # Fallback: fetch inside the image (needs network + curl).
    FETCH_HELPER=""
    for cand in \
        /opt/azl-desktop-assets/build-helpers/fetch-latest-thirdparty.sh \
        /workspace/scripts/fetch-latest-thirdparty.sh
    do
        if [ -x "$cand" ]; then
            FETCH_HELPER="$cand"
            break
        fi
    done
    [ -n "$FETCH_HELPER" ] || {
        echo "error: no staged thirdparty and fetch-latest-thirdparty.sh missing" >&2
        exit 1
    }
    "$FETCH_HELPER" "$EXTRAS"
fi
test -s "$EXTRAS/github-copilot.rpm"
test -s "$EXTRAS/copilot-linux-x64.tar.gz"
test -s "$EXTRAS/edit.tar.gz"
test -s "$EXTRAS/dotnet-sdk-linux-x64.tar.gz"
# Install helpers for the target system %%post (azl-install.ks.in).
for cand in \
    /opt/azl-desktop-assets/build-helpers/install-dotnet-sdk-tarball.sh \
    /workspace/scripts/install-dotnet-sdk-tarball.sh
do
    if [ -x "$cand" ]; then
        install -m 0755 "$cand" "$EXTRAS/install-dotnet-sdk-tarball.sh"
        break
    fi
done
test -x "$EXTRAS/install-dotnet-sdk-tarball.sh"
for cand in \
    /opt/azl-desktop-assets/build-helpers/configure-github-copilot-system-git.sh \
    /workspace/scripts/configure-github-copilot-system-git.sh
do
    if [ -x "$cand" ]; then
        install -m 0755 "$cand" "$EXTRAS/configure-github-copilot-system-git.sh"
        break
    fi
done
test -x "$EXTRAS/configure-github-copilot-system-git.sh"

#----------------------------------------------------------------------
# Microsoft Copilot GTK Flatpak (system install + Pages update remote).
# Prefer CI-prestaged OSTree under assets (flatpak-system-latest). Fall
# back to network install via the shared helper when missing (local kiwi).
#----------------------------------------------------------------------
echo "=== Staging Copilot desktop Flatpak for offline target install ==="
rm -rf "$EXTRAS/flatpak-system"
mkdir -p "$EXTRAS/flatpak-system"
PRESTAGE_FP=""
for cand in \
    /opt/azl-desktop-assets/flatpak-system-latest \
    /workspace/prestage/flatpak-system
do
    if [ -f "$cand/repo/config" ]; then
        PRESTAGE_FP="$cand"
        break
    fi
done
if [ -n "$PRESTAGE_FP" ]; then
    echo "using pre-staged Flatpak tree from $PRESTAGE_FP"
    cp -a "$PRESTAGE_FP"/. "$EXTRAS/flatpak-system"/
else
    echo "no prestage tree; installing Flatpak over the network"
    FLATPAK_STAGE="$EXTRAS/flatpak-system-root"
    rm -rf "$FLATPAK_STAGE"
    mkdir -p "$FLATPAK_STAGE"
    INSTALL_COPILOT=""
    for cand in \
        /opt/azl-desktop-assets/build-helpers/prestage-copilot-flatpak-system.sh \
        /opt/azl-desktop-assets/build-helpers/install-copilot-desktop-flatpak.sh \
        /workspace/scripts/prestage-copilot-flatpak-system.sh \
        /workspace/scripts/install-copilot-desktop-flatpak.sh
    do
        if [ -x "$cand" ]; then
            INSTALL_COPILOT="$cand"
            break
        fi
    done
    [ -n "$INSTALL_COPILOT" ] || {
        echo "error: no prestaged Flatpak and no install/prestage helper" >&2
        exit 1
    }
    case "$INSTALL_COPILOT" in
        *prestage-copilot-flatpak-system.sh)
            if [ -s "$EXTRAS/flathub.flatpakrepo" ]; then
                "$INSTALL_COPILOT" "$EXTRAS/flatpak-system" "$EXTRAS/flathub.flatpakrepo"
            else
                "$INSTALL_COPILOT" "$EXTRAS/flatpak-system"
            fi
            ;;
        *)
            if [ -s "$EXTRAS/flathub.flatpakrepo" ]; then
                "$INSTALL_COPILOT" "$FLATPAK_STAGE" "$EXTRAS/flathub.flatpakrepo"
            else
                "$INSTALL_COPILOT" "$FLATPAK_STAGE"
            fi
            cp -a "$FLATPAK_STAGE/var/lib/flatpak"/. "$EXTRAS/flatpak-system"/
            rm -rf "$FLATPAK_STAGE"
            ;;
    esac
fi
test -f "$EXTRAS/flatpak-system/repo/config"
test -d "$EXTRAS/flatpak-system/app/com.github.sirredbeard.copilot-desktop-gtk"
ls "$EXTRAS/flatpak-system/app" | grep -F 'com.github.sirredbeard.copilot-desktop-gtk'
# Flathub AppStream for GNOME Software first-open catalog (issue #6).
test -e "$EXTRAS/flatpak-system/appstream/flathub/x86_64/active/appstream.xml" \
    || test -e "$EXTRAS/flatpak-system/appstream/flathub/x86_64/active/appstream.xml.gz"
test -d "$EXTRAS/flatpak-system/appstream/flathub/x86_64/active/icons"

#----------------------------------------------------------------------
# Anaconda launcher symlink (script deployed via kiwi <file>) - same
# convention as upstream.
#----------------------------------------------------------------------
ln -sf /usr/local/bin/anaconda-launcher.sh /usr/local/bin/install-azl

#----------------------------------------------------------------------
# Welcome banner + auto-install-on-cmdline-flag logic, copied verbatim
# from upstream's own config.sh (byte-for-byte, only the banner text
# says "Azure Linux Desktop" instead of "Azure Linux 4.0") - this is
# the actual mechanism (not anaconda-launcher.sh itself) that decides
# whether to auto-run the installer, so it has to match upstream
# exactly for azl.autoinstall to keep working the same way.
#----------------------------------------------------------------------
cat > /root/.bash_profile << 'PROFILEEOF'
if grep -q 'azl\.autoinstall' /proc/cmdline 2>/dev/null; then
    MY_TTY=$(tty 2>/dev/null)
    VIRT=$(systemd-detect-virt 2>/dev/null)
    LAUNCH=false
    if [ "$VIRT" = "microsoft" ]; then
        [ "$MY_TTY" = "/dev/tty1" ] && LAUNCH=true
    else
        case "$MY_TTY" in
            /dev/ttyS0)
                LAUNCH=true
                ;;
            /dev/tty1|/dev/hvc0)
                if ! grep -q 'console=ttyS' /proc/cmdline 2>/dev/null; then
                    LAUNCH=true
                fi
                ;;
        esac
    fi
    if [ "$LAUNCH" = true ]; then
        echo ""
        echo "========================================"
        echo "  Azure Linux Desktop - Offline Installer"
        echo "========================================"
        echo ""
        echo "  Starting installer automatically..."
        echo ""
        exec /usr/local/bin/anaconda-launcher.sh
    fi
fi
echo ""
echo "========================================"
echo "  Azure Linux Desktop - Offline Installer"
echo "========================================"
echo ""
echo "  To start the installer, run:"
echo ""
echo "    install-azl"
echo ""
echo "========================================"
echo ""
PROFILEEOF

cat > /root/.bashrc << 'RCEOF'
if [[ $- == *i* ]] && [ ! -f /tmp/.azl-banner-shown ]; then
    touch /tmp/.azl-banner-shown
    source /root/.bash_profile
fi
RCEOF

mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf << 'AUTOEOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
AUTOEOF

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTOEOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
AUTOEOF

#----------------------------------------------------------------------
# Generate the real kickstarts from the @@PACKAGES@@ template, same
# substitution mechanism upstream uses. Both the standard and LUKS-
# encrypted variants share the exact same package list - they only
# differ in the disk-layout section, which is why the same
# generate_packages_section() output gets spliced into both. Renders
# to /root/azl-install.ks and /root/azl-install-encrypted.ks - the
# exact paths anaconda-launcher.sh (kept byte-for-byte identical to
# upstream, see reference/azl-installer/README.md) already cp's from
# for its "1) Standard installation" / "2) Encrypted disk (LUKS)"
# menu, so this can't silently drift out of sync with what that
# unmodified upstream script expects again (see findings/
# findings/kiwi-ng-installer-build.md for the incident that happened
# when these names didn't match: anaconda-launcher.sh failed with
# "Kickstart file /run/install/ks.cfg is missing" for both menu
# choices, since neither /root/azl-install.ks nor
# /root/azl-install-encrypted.ks existed under the old
# azl-desktop-install.ks naming).
#----------------------------------------------------------------------
generate_packages_section() {
    echo "# Packages - Azure Linux Desktop (GNOME + Microsoft/GitHub tooling)"
    echo "# --nocore: AZL repo has no comps groups, so @core would fail"
    echo "%packages --nocore --excludedocs"
    for pkg in "${INSTALL_PKGS[@]}"; do
        echo "$pkg"
    done
    # Same exclusions as kickstart/azurelinux-desktop-live.ks's
    # %packages - GNOME Tour, Help, and Malcontent can ride along as weak
    # deps of the base GNOME session/shell packages even with --nocore.
    # None belongs on this build: no welcome tour, Help application, or
    # parental-controls stack. mdatp is excluded at the repo
    # level already (ms-prod's --exclude in the dnf5 download call
    # above), listed here too for the same belt-and-suspenders reason
    # the live ISO's %packages does it. Do not exclude fedora-logos:
    # anaconda-live requires it and the live ISO includes it too.
    for pkg in gnome-tour gnome-user-docs yelp yelp-libs malcontent-control mdatp; do
        echo "-$pkg"
    done
    echo "%end"
}

render_kickstart() {
    local ks_in="$1"
    local ks_out="$2"

    {
        sed '/@@PACKAGES@@/,$d' "$ks_in"
        generate_packages_section
        sed '1,/@@PACKAGES@@/d' "$ks_in"
    } > "$ks_out"
    rm -f "$ks_in"
}

render_kickstart /root/azl-install.ks.in /root/azl-install.ks
# The encrypted variant is now identical to the standard one: storage is
# fully interactive (no autopart/clearpart directives), so the user sets
# up LUKS themselves in Anaconda's TUI regardless of which launcher option
# they choose. Keep the file so anaconda-launcher.sh (upstream, unmodified)
# still finds /root/azl-install-encrypted.ks for its option-2 path.
cp /root/azl-install.ks /root/azl-install-encrypted.ks


echo "=== kiwi/config.sh complete ==="
