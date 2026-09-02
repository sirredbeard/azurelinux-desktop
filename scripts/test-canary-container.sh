#!/usr/bin/env bash
# test-canary-container.sh
#
# Purpose: Policy tests against a canary OCI image: DNF update, Azure vs
#   Fedora origins, project tools, preinstalled Microsoft Copilot Flatpak
#   plus Pages remote reachability, sample Flatpak, Plymouth package policy.
# Usage:   ./scripts/test-canary-container.sh IMAGE_REF
# Needs:   podman/docker; network for some checks.
# CI:      Yes. release.yml canary job.

set -euo pipefail

LOG_DIR="${AZL_CANARY_TEST_LOG_DIR:-${AZL_HYBRID_TEST_LOG_DIR:-/logs}}"
mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_DIR/test-canary-container.log") 2>&1

run_dnf() {
    local name="$1"
    shift
    dnf5 "$@" | tee "$LOG_DIR/$name.log"
}

assert_rpm_source() {
    local package="$1"
    local expected_release="$2"
    local release
    release="$(rpm -q --qf '%{RELEASE}\n' "$package")"
    printf '%s %s\n' "$package" "$release" | tee -a "$LOG_DIR/package-origins.log"
    [[ "$release" == *"$expected_release"* ]] || {
        echo "error: $package has release $release, expected $expected_release" >&2
        exit 1
    }
}

dnf5 repolist --enabled | tee "$LOG_DIR/enabled-repositories.log"
# Install policy only; Requires pull every sibling at the kernel EVR.
dnf5 install -y --refresh \
    kernel azurelinux-desktop-policy \
    | tee "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-policy" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-usbhid-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-storage-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-intel-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-sound-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-bluetooth-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-uvc-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-thinkpad-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-typec-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-surface-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-sensors-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-performance-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
kver="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/usbhid.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/usb-storage.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/uas.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/iwlwifi.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/iwlmvm.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/iwldvm.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/iwlmld.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/bluetooth.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/btusb.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/uvcvideo.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/thinkpad_acpi.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/typec.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/typec_ucsi.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/ucsi_acpi.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/serdev.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/surface_aggregator.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/hid-microsoft.ko"
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/hid-multitouch.ko"
# ALSA controller module name uses hyphens from upstream
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/snd-hda-intel.ko" \
    || test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/snd_hda_intel.ko"
for name in usbhid usb-storage uas iwlwifi iwlmvm iwldvm iwlmld \
    bluetooth btusb uvcvideo thinkpad_acpi typec typec_ucsi ucsi_acpi \
    serdev surface_aggregator; do
    modinfo -F vermagic "/usr/lib/modules/$kver/extra/azurelinux-desktop/$name.ko" \
        | grep -Fq "$kver"
done
# Hyphenated Surface HID module names
for name in hid-microsoft hid-multitouch; do
    modinfo -F vermagic "/usr/lib/modules/$kver/extra/azurelinux-desktop/$name.ko" \
        | grep -Fq "$kver"
done
# storage-kmod ships both new + legacy dracut drop-in names
test -f /etc/dracut.conf.d/90-azurelinux-desktop-storage.conf \
    || test -f /etc/dracut.conf.d/90-azurelinux-desktop-usb-storage.conf
test -f /etc/modules-load.d/azurelinux-desktop-sound.conf
test -f /etc/modules-load.d/azurelinux-desktop-bluetooth.conf
test -f /etc/modules-load.d/azurelinux-desktop-sensors.conf
test -f /etc/modules-load.d/azurelinux-desktop-performance.conf
test -f /etc/sysctl.d/99-azurelinux-desktop-performance.conf
grep -Eq '^[[:space:]]*vm\.swappiness[[:space:]]*=[[:space:]]*10[[:space:]]*$' \
    /etc/sysctl.d/99-azurelinux-desktop-performance.conf
grep -Eq '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$' \
    /etc/sysctl.d/99-azurelinux-desktop-performance.conf
grep -Eq '^[[:space:]]*kernel\.sched_autogroup_enabled[[:space:]]*=[[:space:]]*1[[:space:]]*$' \
    /etc/sysctl.d/99-azurelinux-desktop-performance.conf
grep -Eq '^[[:space:]]*zram[[:space:]]*$' /etc/modules-load.d/azurelinux-desktop-performance.conf
grep -Eq '^[[:space:]]*tcp_bbr[[:space:]]*$' /etc/modules-load.d/azurelinux-desktop-performance.conf
grep -Eq '^[[:space:]]*sch_fq[[:space:]]*$' /etc/modules-load.d/azurelinux-desktop-performance.conf
test -f /etc/systemd/zram-generator.conf \
    || test -f /usr/lib/systemd/zram-generator.conf
# Project journal/iosched assets (staged at canary build; not from the kmod RPM).
test -f /etc/systemd/journald.conf.d/50-azurelinux-desktop.conf
grep -Fq 'SystemMaxUse=200M' /etc/systemd/journald.conf.d/50-azurelinux-desktop.conf
test -f /etc/udev/rules.d/60-azurelinux-desktop-iosched.rules
grep -Fq 'rotational' /etc/udev/rules.d/60-azurelinux-desktop-iosched.rules
# Do not force-load HDA or btusb at boot (VM -ENODEV / ThinkPad HCI race).
! grep -qE '^[[:space:]]*snd-hda-intel[[:space:]]*$' /etc/modules-load.d/azurelinux-desktop-sound.conf
! grep -qE '^[[:space:]]*btusb[[:space:]]*$' /etc/modules-load.d/azurelinux-desktop-bluetooth.conf
test -f /etc/modprobe.d/azurelinux-desktop-bluetooth.conf
grep -q 'softdep btusb pre: thinkpad_acpi' /etc/modprobe.d/azurelinux-desktop-bluetooth.conf
# AZL has no snd-seq; override Fedora dist-alsa install hook.
test -f /etc/modprobe.d/azurelinux-desktop-alsa.conf
grep -q 'ignore-install snd-pcm' /etc/modprobe.d/azurelinux-desktop-alsa.conf
run_dnf dnf-update update --refresh -y
run_dnf dnf-upgrade upgrade -y
run_dnf dnf-install-samples install -y \
    ovfenv telegraf \
    dconf-editor gnome-sudoku idle3

: > "$LOG_DIR/package-origins.log"
assert_rpm_source ovfenv '.azl4'
assert_rpm_source telegraf '.azl4'
assert_rpm_source dconf-editor '.fc43'
assert_rpm_source gnome-sudoku '.fc43'
assert_rpm_source python3-idle '.fc43'
assert_rpm_source gnome-backgrounds '.fc43'
assert_rpm_source gnome-terminal '.fc43'
test -s /etc/dconf/db/local
DCONF_PROFILE=user dconf read /org/gnome/desktop/background/picture-uri-dark \
    | grep -Fq "file:///usr/share/backgrounds/azurelinux/adwaita-d.jpg"
DCONF_PROFILE=user dconf read /org/gnome/shell/keybindings/show-screenshot-ui \
    | grep -Fq "<Shift><Super>s"
grep -Fq "show-screenshot-ui=['Print', '<Shift><Super>s']" \
    /etc/dconf/db/local.d/00-azl-desktop-defaults
grep -Fq "command='flatpak run com.tomjwatson.Emote'" \
    /etc/dconf/db/local.d/00-azl-desktop-defaults
grep -Fq "binding='<Super>period'" \
    /etc/dconf/db/local.d/00-azl-desktop-defaults
test -x /usr/local/bin/azl-powershell-terminal
test -f /usr/share/applications/org.azurelinux.PowerShell.desktop
grep -Fxq 'StartupWMClass=org.azurelinux.PowerShell' /usr/share/applications/org.azurelinux.PowerShell.desktop

{
    echo '=== RPM versions ==='
    rpm -q \
        azurelinux-release dnf5 flatpak glib2 gtk4 dconf \
        gnome-backgrounds gnome-terminal \
        microsoft-edge-canary code-insiders gh github-desktop \
        powershell azure-cli plymouth git github \
        google-noto-color-emoji-fonts default-fonts-core-emoji \
        libva intel-media-driver intel-mediasdk ffmpeg \
        gstreamer1-plugin-libav gstreamer1-plugin-openh264 \
        gstreamer1-plugins-ugly gstreamer1-plugins-bad-freeworld \
        gstreamer1-vaapi mesa-dri-drivers mesa-vulkan-drivers \
        mesa-va-drivers vulkan-loader libvdpau libvdpau-va-gl
    echo
    echo '=== Intel media / H.264 stack (must be nonfree iHD, not free-only) ==='
    if rpm -q libva-intel-media-driver >/dev/null 2>&1; then
        echo "error: libva-intel-media-driver (Fedora free) must not be installed" >&2
        exit 1
    fi
    rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH} %{VENDOR}\n' intel-media-driver
    # RPM Fusion nonfree puts iHD in dri-nonfree/. Product post links it into
    # dri/ so Azure Linux libva (no dri-nonfree search path) can load it.
    test -e /usr/lib64/dri-nonfree/iHD_drv_video.so
    test -e /usr/lib64/dri/iHD_drv_video.so
    test -f /etc/environment.d/50-azurelinux-desktop-libva.conf
    grep -Fq 'dri-nonfree' /etc/environment.d/50-azurelinux-desktop-libva.conf
    test -d /usr/lib64/gstreamer-1.0
    # rpmdb should be world-readable for non-root queries
    if [[ -f /usr/lib/sysimage/rpm/rpmdb.sqlite ]]; then
        stat -c '%a' /usr/lib/sysimage/rpm/rpmdb.sqlite | grep -E '^[4567][4567][4567]$' >/dev/null \
            || { echo "error: rpmdb.sqlite not world-readable" >&2; exit 1; }
    fi
    echo
    echo '=== RPM GPG keys for gpgcheck=1 repos ==='
    for key in \
        RPM-GPG-KEY-fedora-43-primary \
        RPM-GPG-KEY-microsoft \
        RPM-GPG-KEY-githubcli \
        RPM-GPG-KEY-shiftkey-desktop \
        RPM-GPG-KEY-rpmfusion-free-fedora-2020 \
        RPM-GPG-KEY-rpmfusion-nonfree-fedora-2020 \
        RPM-GPG-KEY-azurelinux-desktop
    do
        test -e "/etc/pki/rpm-gpg/$key" || {
            echo "error: missing $key" >&2
            exit 1
        }
    done
    echo
    echo '=== GitHub Copilot GUI system-git override ==='
    test -f /etc/environment.d/50-azurelinux-desktop-github-copilot.conf
    grep -Fxq 'LOCAL_GIT_DIRECTORY=/usr' \
        /etc/environment.d/50-azurelinux-desktop-github-copilot.conf
    test -x /usr/local/bin/azl-github-copilot
    grep -Fq 'LOCAL_GIT_DIRECTORY=/usr' /usr/local/bin/azl-github-copilot
    if [[ -f '/usr/share/applications/GitHub Copilot.desktop' ]]; then
        grep -Fq 'Exec=/usr/local/bin/azl-github-copilot' \
            '/usr/share/applications/GitHub Copilot.desktop'
    fi
    echo
    echo '=== .NET 11 (side-loaded tarball, not yum) ==='
    if [[ -x /usr/share/dotnet/dotnet ]]; then
        /usr/share/dotnet/dotnet --version
    elif command -v dotnet >/dev/null 2>&1; then
        dotnet --version
    else
        echo "error: dotnet 11 host missing" >&2
        exit 1
    fi
    (dotnet --version 2>/dev/null || /usr/share/dotnet/dotnet --version) | grep -E '^11\.' || {
        echo "error: expected .NET 11.x SDK" >&2
        exit 1
    }
    echo
    echo '=== Side-loaded command versions ==='
    timeout 20 copilot --version </dev/null || echo 'copilot --version timed out or failed'
    timeout 20 edit --version </dev/null || echo 'edit --version timed out or failed'
} | tee "$LOG_DIR/software-versions.log"

# Microsoft Copilot GTK Flatpak must already be on the image from the
# canary build (system install + Pages remote). Fail hard if missing.
{
    echo '=== Copilot desktop Flatpak (preinstalled) ==='
    flatpak info --system com.github.sirredbeard.copilot-desktop-gtk
    flatpak info --system com.tomjwatson.Emote
    flatpak list --system --app --columns=application,version,origin \
        | grep -F 'com.github.sirredbeard.copilot-desktop-gtk'
    flatpak list --system --app --columns=application,version,origin \
        | grep -F 'com.tomjwatson.Emote'
    flatpak remotes --system --columns=name | grep -qx 'copilot-desktop-gtk'
    flatpak remotes --system --columns=name | grep -qx 'flathub'
    # Flathub AppStream baked at image build (GNOME Software catalog; issue #6).
    echo '=== Flathub AppStream (preseeded) ==='
    test -e /var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml \
        || test -e /var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml.gz
    test -d /var/lib/flatpak/appstream/flathub/x86_64/active/icons
    du -sh /var/lib/flatpak/appstream/flathub 2>/dev/null || true
    # Pages stream is GPG-signed; system remote must verify signatures.
    # Pure bash: the canary image is minimal and does not ship gawk/awk.
    if [[ -f /var/lib/flatpak/repo/config ]]; then
        insec=0
        found=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == '[remote "copilot-desktop-gtk"]' ]]; then
                insec=1
                continue
            fi
            if [[ "$line" == \[* ]]; then
                insec=0
                continue
            fi
            if (( insec )) && [[ "$line" == gpg-verify=true || "$line" == gpg-verify=1 ]]; then
                found=1
                break
            fi
        done < /var/lib/flatpak/repo/config
        if (( ! found )); then
            echo 'error: copilot-desktop-gtk missing gpg-verify=true in /var/lib/flatpak/repo/config' >&2
            exit 1
        fi
        echo 'OK: copilot-desktop-gtk gpg-verify=true'
    else
        echo 'error: missing /var/lib/flatpak/repo/config' >&2
        exit 1
    fi
} | tee "$LOG_DIR/copilot-flatpak-info.log"

# Pages OSTree must be reachable for updates (not just present on disk).
{
    echo '=== Copilot Flatpak remote reachability ==='
    curl -fsSL --retry 3 --retry-all-errors -o /dev/null \
        https://sirredbeard.github.io/copilot-desktop-gtk/repo/config
    curl -fsSL --retry 3 --retry-all-errors -o /dev/null \
        https://sirredbeard.github.io/copilot-desktop-gtk/com.github.sirredbeard.copilot-desktop-gtk.flatpakref
    # remote-ls talks to the registered remote over the network.
    flatpak remote-ls --system copilot-desktop-gtk \
        | grep -F 'com.github.sirredbeard.copilot-desktop-gtk'
} | tee "$LOG_DIR/copilot-flatpak-remote.log"

flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo
if flatpak install --system --noninteractive -y flathub \
    org.mozilla.firefox com.github.tchx84.Flatseal org.gnome.Polari \
    | tee "$LOG_DIR/flatpak-install.log"; then
    flatpak list --system --app --columns=application,version,origin \
        | tee "$LOG_DIR/flatpak-versions.log"
else
    echo "WARN: sample Flatpak install failed in canary container test environment; Copilot preinstall checks above remain authoritative." \
        | tee "$LOG_DIR/flatpak-install-warning.log"
fi
