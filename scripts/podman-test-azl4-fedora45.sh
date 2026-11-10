#!/usr/bin/env bash
# podman-test-azl4-fedora45.sh
#
# Purpose: ARM64 package-resolution harness for the Fedora 45 rebase
#   experiment. Resolves the live kickstart package set against Azure
#   Linux 4.0 (aarch64) + Fedora (aarch64) repos inside a Fedora podman
#   container and prints an origin census. Adapted from
#   podman-test-azl4-fedora.sh, which is x86_64-only as written (repo
#   URLs, grub/shim package names, and the container arch all assume
#   an x86_64 host).
# Usage: FEDORA_VER=43 ./scripts/podman-test-azl4-fedora45.sh
#        FEDORA_VER=45 ./scripts/podman-test-azl4-fedora45.sh
#   AZL_FEDORA_EXCLUDES_FILE=/path/list.txt overrides the claw-back list.
# Needs: podman (rootful via sudo), network.
# CI:    No. Experiment harness for the rebase/fedora-45 branch.
#
# ARM64 adaptations, none of which change the dependency question:
#   - Fedora, Azure Linux, and RPM Fusion repos use their aarch64 trees.
#   - grub2-efi-x64* and shim become grub2-efi-aa64* and shim-aa64.
#   - azurelinux-desktop-policy is x86_64 itself and hard-requires
#     27 version-pinned x86_64 kmod packages plus
#     kernel-core-uname-r, so it cannot install on aarch64 at all.
#   - Dropped as x86_64-only leaves: microsoft-edge-canary,
#     microcode_ctl, intel-media-driver, intel-mediasdk, thermald.
#   - Dropped with their x86_64-only or leaf repos: powershell
#     (ms-prod), code-insiders (vscode), gh (gh-cli), github-desktop,
#     and the azl-desktop-kmods repo (x86_64 only by construction).

set -uo pipefail

VER="${FEDORA_VER:-45}"
ARCH=aarch64
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KS="$REPO_ROOT/kickstart/azurelinux-desktop-live.ks"
PKGSRC="${PKGSRC:-kickstart}"
WORKDIR="${AZL_PODMAN_WORKDIR:-$HOME/azl-work/podman-test-f${VER}-${PKGSRC}-arm64}"
mkdir -p "$WORKDIR/cache"

# Claw-back list: same packages as kiwi/config.sh FEDORA_EXCLUDES at
# the start of the experiment. Arch swap x64 -> aa64 applied below.
FEDORA_EXCLUDES="audit,audit-libs,audit-rules,bash,bluez,bluez-libs,bluez-obexd,bzip2,ca-certificates,chrony,coreutils,coreutils-common,cryptsetup,cryptsetup-libs,dbus,dbus-broker,dbus-common,dbus-daemon,dbus-libs,dbus-tools,device-mapper,device-mapper-event,device-mapper-event-libs,device-mapper-libs,device-mapper-persistent-data,diffutils,dosfstools,e2fsprogs,e2fsprogs-libs,efibootmgr,findutils,firewalld,firewalld-filesystem,gawk,gawk-all-langpacks,grep,gzip,hwdata,iproute,iputils,kbd,kbd-legacy,kbd-misc,kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra,kernel-devel,kernel-headers,kernel-tools,kernel-tools-libs,kmod,less,less-color,libaio,libblkid,libblkid-devel,libcom_err,libfdisk,liblastlog2,libmount,libmount-devel,libnm,libsmartcols,libuuid,linux-firmware,linux-firmware-whence,lvm2,lvm2-libs,microcode_ctl,ModemManager-glib,mtools,ncurses,ncurses-base,ncurses-libs,NetworkManager,NetworkManager-libnm,NetworkManager-team,NetworkManager-tui,NetworkManager-wifi,NetworkManager-bluetooth,NetworkManager-wwan,perl,perl-libs,perl-interpreter,perl-Errno,perl-Socket,alsa-ucm,alsa-lib,openssh,openssh-clients,openssh-server,patch,polkit,polkit-libs,procps-ng,python3-audit,python3-firewall,python3-libmount,sed,setup,shadow-utils,sudo,sudo-python-plugin,systemd,systemd-boot-unsigned,systemd-container,systemd-libs,systemd-networkd,systemd-pam,systemd-resolved,systemd-shared,systemd-sysusers,systemd-udev,systemd-rpm-macros,tar,util-linux,util-linux-core,vim-data,vim-minimal,xz,xz-libs,amd-gpu-firmware,amd-ucode-firmware,atheros-firmware,brcmfmac-firmware,cirrus-audio-firmware,intel-audio-firmware,intel-gpu-firmware,mt7xxx-firmware,nvidia-gpu-firmware,nxpwireless-firmware,qcom-wwan-firmware,realtek-firmware,tiwilink-firmware,iwlegacy-firmware,iwlwifi-dvm-firmware,iwlwifi-mld-firmware,iwlwifi-mvm-firmware"
if [ -n "${AZL_FEDORA_EXCLUDES_FILE:-}" ]; then
    if [ ! -r "$AZL_FEDORA_EXCLUDES_FILE" ]; then
        echo "AZL_FEDORA_EXCLUDES_FILE is set but not readable: $AZL_FEDORA_EXCLUDES_FILE" >&2
        exit 1
    fi
    FEDORA_EXCLUDES="$(tr -d ' \n' < "$AZL_FEDORA_EXCLUDES_FILE")"
    echo "Using FEDORA_EXCLUDES override from $AZL_FEDORA_EXCLUDES_FILE"
fi
AZL_BASE_EXCLUDES="hunspell-en,avahi,avahi-autoipd,avahi-compat-howl,avahi-compat-howl-devel,avahi-compat-libdns_sd,avahi-compat-libdns_sd-devel,avahi-devel,avahi-dnsconfd,avahi-glib,avahi-glib-devel,avahi-gobject,avahi-gobject-devel,avahi-libs,avahi-tools,grub2,grub2-pc,grub2-pc-modules,grub2-efi-aa64,grub2-efi-aa64-modules,grub2-efi-aa64-cdboot,grub2-tools,grub2-tools-extra,grub2-tools-minimal,grub2-common,shim,shim-aa64,gsettings-desktop-schemas,dnf5,dnf5daemon-server,dnf5daemon-server-polkit,libdnf5,libdnf5-cli,libdnf5-plugin-actions,libdnf5-plugin-appstream,libdnf5-plugin-expired-pgp-keys,libdnf5-plugin-local,pinentry"
AZL_MS_EXCLUDES="hunspell-en,grub2,grub2-pc,grub2-pc-modules,grub2-efi-aa64,grub2-efi-aa64-modules,grub2-efi-aa64-cdboot,grub2-tools,grub2-tools-extra,grub2-tools-minimal,grub2-common,shim,shim-aa64,gsettings-desktop-schemas,pinentry"

# Package list: one of the three product package sets, with the ARM64
# swaps and drops documented in the header. PKGSRC=kickstart uses the
# live kickstart %packages block, PKGSRC=kiwi uses the <packages> list
# in kiwi/azl-desktop-installer.kiwi, PKGSRC=canary uses
# assets/canary/pkglist.txt.
DROPS='^(virtualbox-guest-additions|microsoft-edge-canary|microcode_ctl|intel-media-driver|intel-mediasdk|thermald|powershell|code-insiders|gh|github-desktop|azurelinux-desktop-policy)$'
if [ "$VER" = "45" ]; then
    # Removed in Fedora 45 (gnome-themes-extra, libvdpau-va-gl:
    # deleted upstream, nothing obsoletes them) or uninstallable
    # while python3 stays Azure Linux 3.14 (anaconda-live needs
    # the Fedora-only python3-dbus-next at python 3.15, totem
    # needs libpeas1-loader-python3 linked to libpython 3.15).
    DROPS="$DROPS|^(gnome-themes-extra|libvdpau-va-gl)$"
    if [ -z "${F45_KEEP_INSTALLER:-}" ]; then
        DROPS="$DROPS|^(anaconda-live|totem)$"
    fi
fi
case "$PKGSRC" in
    kickstart)
        mapfile -t PKGS < <(awk '/^%packages/{f=1;next}/^%end/{if(f){exit}}f' "$KS"             | sed -e 's/#.*$//' -e '/^\s*$/d' -e '/^@/d' -e '/^-/d' -e 's/^\s*//;s/\s*$//')
        ;;
    kiwi)
        mapfile -t PKGS < <(grep -oE '<package name="[^"]+"' "$REPO_ROOT/kiwi/azl-desktop-installer.kiwi"             | sed -e 's/<package name="//' -e 's/"$//' | sort -u)
        ;;
    canary)
        mapfile -t PKGS < <(grep -vE '^(#|$)' "$REPO_ROOT/assets/canary/pkglist.txt")
        ;;
    *) echo "unknown PKGSRC=$PKGSRC" >&2; exit 2 ;;
esac
mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}"     | sed -e 's/^grub2-efi-x64/grub2-efi-aa64/' -e 's/^shim$/shim-aa64/' -e 's/^shim-x64$/shim-aa64/'     | grep -vE "$DROPS")
printf '%s\n' "${PKGS[@]}" > "$WORKDIR/pkglist.txt"
echo "=== ${#PKGS[@]} packages, Fedora $VER, arch $ARCH ==="

# Repo file for the experiment.
REPO_FILE="$WORKDIR/azl-test.repo"
{
    echo '[azl-base]'; echo 'name=azl-base'
    echo "baseurl=https://packages.microsoft.com/azurelinux/4.0/beta/base/$ARCH"
    echo 'enabled=1'; echo 'gpgcheck=0'; echo 'cost=1'
    echo "excludepkgs=$AZL_BASE_EXCLUDES"; echo
    echo '[azl-microsoft]'; echo 'name=azl-microsoft'
    echo "baseurl=https://packages.microsoft.com/azurelinux/4.0/beta/microsoft/$ARCH"
    echo 'enabled=1'; echo 'gpgcheck=0'; echo 'cost=1'
    echo "excludepkgs=$AZL_MS_EXCLUDES"; echo
    echo "[fedora$VER]"; echo "name=fedora$VER"
    echo "baseurl=https://dl.fedoraproject.org/pub/fedora/linux/releases/$VER/Everything/$ARCH/os/"
    echo 'enabled=1'; echo 'gpgcheck=0'; echo 'cost=50'
    echo "excludepkgs=$FEDORA_EXCLUDES"; echo
    echo "[fedora$VER-updates]"; echo "name=fedora$VER-updates"
    echo "baseurl=https://dl.fedoraproject.org/pub/fedora/linux/updates/$VER/Everything/$ARCH/"
    echo 'enabled=1'; echo 'gpgcheck=0'; echo 'cost=50'
    echo "excludepkgs=$FEDORA_EXCLUDES"; echo
    echo '[azl-desktop]'; echo 'name=azl-desktop'
    echo "baseurl=https://sirredbeard.github.io/azurelinux-desktop/repo"
    echo 'enabled=1'; echo 'gpgcheck=0'; echo 'cost=1'; echo
    echo '[rpmfusion-free]'; echo 'name=rpmfusion-free'
    echo "baseurl=https://download1.rpmfusion.org/free/fedora/releases/$VER/Everything/$ARCH/os/"
    echo 'enabled=1'; echo 'gpgcheck=0'; echo 'cost=50'; echo
    echo '[rpmfusion-nonfree]'; echo 'name=rpmfusion-nonfree'
    echo "baseurl=https://download1.rpmfusion.org/nonfree/fedora/releases/$VER/Everything/$ARCH/os/"
    echo 'enabled=1'; echo 'gpgcheck=0'; echo 'cost=50'
} > "$REPO_FILE"

# Weak dependencies: the canary rootfs install disables them
# (containers/canary/Dockerfile); the kickstart and kiwi installs
# leave them on. Match the install each package set belongs to.
WEAK_DEPS=True
if [ "$PKGSRC" = "canary" ]; then
    WEAK_DEPS=False
fi

cat > "$WORKDIR/inner.sh" <<'INNER'
#!/bin/bash
VER="$1"
WEAK_DEPS="$2"
mkdir -p /mnt/azl/etc/yum.repos.d
cp /work/azl-test.repo /mnt/azl/etc/yum.repos.d/azl-test.repo
dnf5 install -y \
    --setopt=reposdir=/mnt/azl/etc/yum.repos.d \
    --setopt=cachedir=/work/cache \
    --installroot=/mnt/azl --releasever="$VER" \
    --setopt=install_weak_deps=$WEAK_DEPS \
    $(cat /work/pkglist.txt) > /work/dnf.log 2>&1
DNF_RC=$?
echo "dnf exit: $DNF_RC"
tail -60 /work/dnf.log
if [ "$DNF_RC" -ne 0 ]; then
    echo "dnf failed; no census for this run" >&2
    exit "$DNF_RC"
fi
echo "=== CENSUS ==="
if [ -d /mnt/azl/usr/lib/sysimage/rpm ] || [ -d /mnt/azl/var/lib/rpm ]; then
    chroot /mnt/azl rpm -qa --qf "%{name}-%{version}-%{release}.%{arch}\n" 2>/dev/null | sort > /work/pkglist_result.txt
    TOTAL=$(wc -l < /work/pkglist_result.txt)
    AZL=$(grep -c "\.azl" /work/pkglist_result.txt || true)
    FC=$(grep -c "\.fc$VER" /work/pkglist_result.txt || true)
    echo "azl=$AZL fc$VER=$FC other=$((TOTAL-AZL-FC)) total=$TOTAL"
    echo "=== KEY ORIGINS ==="
    for p in glibc glib2 libicu libxml2 systemd NetworkManager gnome-shell mutter gdm gtk4 libadwaita openssl-libs python3 dnf5 kernel pipewire mesa-libGL webkitgtk6.0 evolution-data-server tinysparql localsearch gnome-keyring; do
        chroot /mnt/azl rpm -q --qf "$p %{version}-%{release}\n" "$p" 2>/dev/null || echo "$p NOT-INSTALLED"
    done
fi
INNER
chmod +x "$WORKDIR/inner.sh"

sudo podman run --rm \
    --security-opt label=disable \
    -v "$WORKDIR:/work:Z" \
    "registry.fedoraproject.org/fedora:$VER" bash /work/inner.sh "$VER" "$WEAK_DEPS" 2>&1 | tee "$WORKDIR/result.log"
RUN_RC=${PIPESTATUS[0]}
sudo chown -R "$(id -u):$(id -g)" "$WORKDIR" 2>/dev/null || true
echo "Full log: $WORKDIR/result.log ; dnf log: $WORKDIR/dnf.log ; census: $WORKDIR/pkglist_result.txt"
exit "$RUN_RC"
