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
dnf5 install -y --refresh \
    kernel azurelinux-desktop-policy \
    | tee "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-policy" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-usbhid-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-usb-storage-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-iwlwifi-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-sound-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-bluetooth-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-uvc-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-thinkpad-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
grep -Fq "azurelinux-desktop-typec-kmod" "$LOG_DIR/desktop-kmod-resolve.log"
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
# ALSA controller module name uses hyphens from upstream
test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/snd-hda-intel.ko" \
    || test -f "/usr/lib/modules/$kver/extra/azurelinux-desktop/snd_hda_intel.ko"
for name in usbhid usb-storage uas iwlwifi iwlmvm iwldvm iwlmld \
    bluetooth btusb uvcvideo thinkpad_acpi typec typec_ucsi ucsi_acpi; do
    modinfo -F vermagic "/usr/lib/modules/$kver/extra/azurelinux-desktop/$name.ko" \
        | grep -Fq "$kver"
done
test -f /etc/dracut.conf.d/90-azurelinux-desktop-usb-storage.conf
test -f /etc/modules-load.d/azurelinux-desktop-sound.conf
test -f /etc/modules-load.d/azurelinux-desktop-bluetooth.conf
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
test -x /usr/local/bin/azl-powershell-terminal
test -f /usr/share/applications/org.azurelinux.PowerShell.desktop
grep -Fxq 'StartupWMClass=org.azurelinux.PowerShell' /usr/share/applications/org.azurelinux.PowerShell.desktop

{
    echo '=== RPM versions ==='
    rpm -q \
        azurelinux-release dnf5 flatpak glib2 gtk4 dconf \
        gnome-backgrounds gnome-terminal \
        microsoft-edge-canary code-insiders gh github-desktop \
        powershell azure-cli plymouth
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
    flatpak list --system --app --columns=application,version,origin \
        | grep -F 'com.github.sirredbeard.copilot-desktop-gtk'
    flatpak remotes --system --columns=name | grep -qx 'copilot-desktop-gtk'
    flatpak remotes --system --columns=name | grep -qx 'flathub'
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
