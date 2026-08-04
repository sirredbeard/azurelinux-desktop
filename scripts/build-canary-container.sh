#!/usr/bin/env bash
# build-canary-container.sh
#
# Purpose: Build the package-policy canary OCI image from kickstart repo
#   rules and a small asset set (including Microsoft Copilot GTK Flatpak).
#   Not a full GNOME desktop container.
# Usage:   ./scripts/build-canary-container.sh [tag]
# Needs:   podman or docker; network for base image and repos.
# CI:      Yes. release.yml canary job.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KS="$REPO_ROOT/kickstart/azurelinux-desktop-live.ks"
IMAGE_REF="${1:-localhost/azurelinux-desktop-canary:latest}"

if [ ! -f "$KS" ]; then
    echo "error: $KS not found - run this from a checkout of the repo" >&2
    exit 1
fi

# Same repo-parsing awk as podman-test-azl4-fedora.sh - see that
# script for a line-by-line explanation of why each field is handled
# the way it is (mirrorlist vs baseurl, the quote() escaping, etc).
# shellcheck disable=SC1003
REPO_SETUP=$(awk '
function quote(s) { gsub(/'"'"'/, "'"'"'\\'"'"''"'"'", s); return "'"'"'" s "'"'"'" }
/^repo --name=/ {
    name=""; url=""; cost=""; excl=""; incl="";
    n=split($0, parts, " --");
    for (i=1;i<=n;i++) {
        p=parts[i];
        if (p ~ /^name=/) { name=substr(p,6) }
        else if (p ~ /^baseurl=/) { url=substr(p,9) }
        else if (p ~ /^mirrorlist=/) { url=substr(p,12); ismirror=1 }
        else if (p ~ /^cost=/) { cost=substr(p,6) }
        else if (p ~ /^excludepkgs=/) { excl=substr(p,13) }
        else if (p ~ /^includepkgs=/) { incl=substr(p,13) }
    }
    printf "REPO_NAMES+=(%s)\n", quote(name);
    printf "REPO_URLS+=(%s)\n", quote(url);
    printf "REPO_COSTS+=(%s)\n", quote(cost);
    printf "REPO_EXCLUDES+=(%s)\n", quote(excl == "" ? "-" : excl);
    printf "REPO_INCLUDES+=(%s)\n", quote(incl == "" ? "-" : incl);
    printf "REPO_MIRROR+=(%s)\n", quote(ismirror == 1 ? "1" : "0");
    ismirror=0;
}
' "$KS")

declare -a REPO_NAMES REPO_URLS REPO_COSTS REPO_EXCLUDES REPO_INCLUDES REPO_MIRROR
eval "$REPO_SETUP"

echo "=== ${#REPO_NAMES[@]} repos parsed: ${REPO_NAMES[*]} ==="

# The canary contains the complete project-specific tooling boundary:
# mixed-source packages, the boot-splash package family, and the two
# side-loaded command-line tools. Their dependency closure may include
# some GTK libraries, which is useful coverage, but it deliberately
# excludes the session/compositor/desktop groups (GNOME, GDM, Mutter,
# systemd) that cannot run meaningfully in an OCI image. If any of these
# packages stop resolving with the intended repo policy, this fast build
# should fail before an ISO build finds it the hard way.
PKGS=(
    filesystem
    bash
    azurelinux-release
    azurelinux-repos
    dnf5
    glib2
    gtk4
    dconf
    gsettings-desktop-schemas
    gnome-backgrounds
    gnome-terminal
    curl
    tar
    flatpak
    plymouth
    plymouth-plugin-script
    plymouth-plugin-label
    microsoft-edge-canary
    powershell
    azure-cli
    code-insiders
    gh
    github-desktop
    libayatana-appindicator-gtk3
)

WORKDIR="${AZL_CONTAINER_WORKDIR:-$HOME/azl-work/build-canary-container}"
# podman unshare, not a plain rm - a previous run's rootfs may contain
# files created under rootless podman's mapped root user namespace
# (mode 000 files, directories only that mapped root can traverse),
# which a bare host-user `rm -rf` can't remove.
podman unshare rm -rf "$WORKDIR" 2>/dev/null || rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
printf '%s\n' "${PKGS[@]}" > "$WORKDIR/pkglist.txt"

REPO_FILE="$WORKDIR/azl-canary.repo"
: > "$REPO_FILE"
for i in "${!REPO_NAMES[@]}"; do
    {
        echo "[${REPO_NAMES[$i]}]"
        echo "name=${REPO_NAMES[$i]}"
        if [ "${REPO_MIRROR[$i]}" = "1" ]; then
            echo "mirrorlist=${REPO_URLS[$i]}"
        else
            echo "baseurl=${REPO_URLS[$i]}"
        fi
        echo "enabled=1"
        # Desktop kmod Pages RPMs are project-signed (shared OpenPGP key).
        if [ "${REPO_NAMES[$i]}" = "azl-desktop-kmods" ]; then
            echo "gpgcheck=1"
            echo "gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop"
        else
            echo "gpgcheck=0"
        fi
        echo "cost=${REPO_COSTS[$i]}"
        if [ "${REPO_EXCLUDES[$i]}" != "-" ]; then
            echo "excludepkgs=${REPO_EXCLUDES[$i]}"
        fi
        if [ "${REPO_INCLUDES[$i]}" != "-" ]; then
            echo "includepkgs=${REPO_INCLUDES[$i]}"
        fi
        echo
    } >> "$REPO_FILE"
done

ROOTFS="$WORKDIR/rootfs"
REPO_DIR="$WORKDIR/repos"
mkdir -p "$ROOTFS/etc/yum.repos.d" "$ROOTFS/etc/pki/rpm-gpg"
cp "$REPO_FILE" "$ROOTFS/etc/yum.repos.d/azl-canary.repo"
if [ -f "$REPO_ROOT/assets/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop" ]; then
    install -m 0644 "$REPO_ROOT/assets/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop" \
        "$ROOTFS/etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop"
fi
mkdir -p "$REPO_DIR"
cp "$REPO_FILE" "$REPO_DIR/azl-canary.repo"

echo "=== Resolving canary package set into $ROOTFS ==="
# /mnt/azl has to be a bind mount of the host's $ROOTFS, not a path
# internal to this throwaway container - otherwise everything dnf5
# installs there vanishes the moment the container exits with --rm,
# and the later `tar -C "$ROOTFS"` on the host packages up nothing but
# the repo file copied in beforehand.
podman run --rm \
    -v "$WORKDIR:/work:Z" \
    -v "$ROOTFS:/mnt/azl:Z" \
    -v "$REPO_ROOT/assets:/assets:ro,Z" \
    -v "$REPO_ROOT/scripts:/scripts:ro,Z" \
    -e GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}" \
    -e GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" \
    registry.fedoraproject.org/fedora:43 bash -exo pipefail -c '
        # /mnt/azl/etc/yum.repos.d/azl-canary.repo already exists here -
        # it is the same bind-mounted $ROOTFS the host wrote it into
        # above, nothing to copy in.
        # Ensure curl/tar (and python3 when available) exist on the *host*
        # container before side-load fetch. Package installroot may not
        # put them on PATH for the outer shell.
        dnf5 install -y curl tar ca-certificates python3 >/dev/null
        # Import project RPM key into the installroot before gpgcheck=1
        # pulls from azl-desktop-kmods.
        if [ -s /mnt/azl/etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop ]; then
            rpm --root=/mnt/azl --import \
                /mnt/azl/etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop
        fi
        dnf5 install -y \
            --refresh \
            --setopt=reposdir=/work/repos \
            --installroot=/mnt/azl --releasever=43 \
            --setopt=metadata_expire=0 \
            --setopt=install_weak_deps=False \
            $(cat /work/pkglist.txt) 2>&1 | tail -60
        echo "=== Fetching and installing side-loaded project tools ==="
        # Always latest Copilot GUI/CLI + microsoft/edit via shared helper.
        test -x /scripts/fetch-latest-thirdparty.sh
        /scripts/fetch-latest-thirdparty.sh /work/thirdparty
        dnf5 install -y \
            --setopt=reposdir=/work/repos \
            --installroot=/mnt/azl --releasever=43 \
            --refresh \
            --setopt=metadata_expire=0 \
            /work/thirdparty/github-copilot.rpm

        install -Dm0755 /assets/bin/azl-powershell-terminal \
            /mnt/azl/usr/local/bin/azl-powershell-terminal
        install -Dm0644 /assets/desktop/org.azurelinux.PowerShell.desktop \
            /mnt/azl/usr/share/applications/org.azurelinux.PowerShell.desktop
        install -Dm0644 /assets/icons/powershell.png \
            /mnt/azl/usr/share/pixmaps/powershell.png
        install -Dm0644 /assets/wallpapers/adwaita-l.jpg \
            /mnt/azl/usr/share/backgrounds/azurelinux/adwaita-l.jpg
        install -Dm0644 /assets/wallpapers/adwaita-d.jpg \
            /mnt/azl/usr/share/backgrounds/azurelinux/adwaita-d.jpg
        install -Dm0644 /assets/plymouth/azurelinux/azurelinux.plymouth \
            /mnt/azl/usr/share/plymouth/themes/azurelinux/azurelinux.plymouth
        install -Dm0644 /assets/plymouth/azurelinux/azurelinux.script \
            /mnt/azl/usr/share/plymouth/themes/azurelinux/azurelinux.script
        install -Dm0644 /assets/plymouth/azurelinux/dot.png \
            /mnt/azl/usr/share/plymouth/themes/azurelinux/dot.png
        install -Dm0644 /assets/plymouth/azurelinux/dot-glow.png \
            /mnt/azl/usr/share/plymouth/themes/azurelinux/dot-glow.png
        install -Dm0644 /assets/branding/AzureLinuxLogo.png \
            /mnt/azl/usr/share/plymouth/themes/azurelinux/azurelinuxlogo.png

        mkdir -p /mnt/azl/etc/dconf/db/local.d /mnt/azl/etc/dconf/profile
        cat > /mnt/azl/etc/dconf/db/local.d/00-azl-desktop-defaults << "EOF"
[org/gnome/desktop/interface]
color-scheme="prefer-dark"
gtk-theme="Adwaita-dark"

[org/gnome/desktop/background]
picture-uri="file:///usr/share/backgrounds/azurelinux/adwaita-l.jpg"
picture-uri-dark="file:///usr/share/backgrounds/azurelinux/adwaita-d.jpg"
picture-options="zoom"
EOF
        cat > /mnt/azl/etc/dconf/profile/user << "EOF"
user-db:user
system-db:local
EOF
        chroot /mnt/azl dconf update
        test -s /mnt/azl/etc/dconf/db/local

        tar -xzf /work/thirdparty/copilot-linux-x64.tar.gz -C /mnt/azl/usr/local/bin copilot
        chmod 0755 /mnt/azl/usr/local/bin/copilot
        tar -xzf /work/thirdparty/edit.tar.gz -C /tmp
        install -m 0755 /tmp/edit /mnt/azl/usr/local/bin/edit
        rm -f /tmp/edit
        if [ -f /work/thirdparty/thirdparty-versions.txt ]; then
            install -m 0644 /work/thirdparty/thirdparty-versions.txt \
                /mnt/azl/var/log/azl-desktop-thirdparty-versions.txt
        fi

        test -x /mnt/azl/usr/local/bin/copilot
        test -x /mnt/azl/usr/local/bin/edit
        test -s /work/thirdparty/dotnet-sdk-linux-x64.tar.gz
        /scripts/install-dotnet-sdk-tarball.sh /mnt/azl /work/thirdparty/dotnet-sdk-linux-x64.tar.gz
        test -x /mnt/azl/usr/share/dotnet/dotnet
        rpm --root=/mnt/azl -q gh github-desktop

        # Microsoft Copilot GTK Flatpak + Pages update remote (system).
        # Host flatpak CLI targets the installroot via FLATPAK_SYSTEM_DIR.
        dnf5 install -y flatpak >/dev/null
        test -x /scripts/install-copilot-desktop-flatpak.sh
        if [ -s /work/thirdparty/flathub.flatpakrepo ]; then
            /scripts/install-copilot-desktop-flatpak.sh /mnt/azl \
                /work/thirdparty/flathub.flatpakrepo
        else
            /scripts/install-copilot-desktop-flatpak.sh /mnt/azl
        fi

        # Confirm the priority split held: azl-base (cost=1) should win
        # for azurelinux-release, fedora43 (cost=50) for gtk4/glib2.
        # Query with the host rpm --root=, not chroot - the installroot
        # only has rpm librpm shared objects, not necessarily the rpm
        # CLI binary itself (nothing in the package list pulls it in).
        rpm --root=/mnt/azl -qa --qf "%{name} %{arch} (from repo priority test)\n" \
            azurelinux-release glib2 gtk4 2>/dev/null
        # Strip dnf/rpm caches and docs the same way container-base
        # style images do - this is a proof-of-repo-priority image, not
        # a working package-management environment.
        # Keep thirdparty-versions.txt under /var/log for canary inspection;
        # wipe the rest of caches/logs and the staged downloads.
        rm -rf /mnt/azl/var/cache/* /work/thirdparty \
               /mnt/azl/usr/share/doc/* /mnt/azl/usr/share/man/*
        find /mnt/azl/var/log -mindepth 1 -maxdepth 1 \
            ! -name azl-desktop-thirdparty-versions.txt -exec rm -rf {} +
    '

echo "=== Importing rootfs as $IMAGE_REF ==="
# Reading these files (e.g. root-owned, mode 000 /etc/shadow) needs to
# happen inside the same user namespace rootless podman used to create
# them - a plain host-side `tar` gets "Permission denied" on them, even
# though it owns the enclosing directory. `podman unshare` enters that
# same mapped namespace.
IMPORT_ID=$(podman unshare tar -C "$ROOTFS" -cf - . | podman import \
    --change 'WORKDIR /' \
    --change 'CMD ["/bin/bash"]' \
    - "$IMAGE_REF")

echo "Built $IMAGE_REF ($IMPORT_ID)"
podman images "$IMAGE_REF"

if [ "${PUSH:-0}" = "1" ]; then
    echo "=== Pushing $IMAGE_REF ==="
    podman push "$IMAGE_REF"
fi
