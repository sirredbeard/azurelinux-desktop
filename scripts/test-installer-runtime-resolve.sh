#!/usr/bin/env bash
# test-installer-runtime-resolve.sh
#
# Purpose: Resolve the installer offline package set (runtime + target list)
#   without building a full ISO.
# Usage:   ./scripts/test-installer-runtime-resolve.sh
# Needs:   dnf/network; mirrors Azure Linux + Fedora as configured.
# CI:      No. Local preflight; related resolve runs in installer CI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKDIR="${1:?usage: $0 /path/under/azl-work/work-directory}"

case "$WORKDIR" in
    "$HOME"/azl-work/*) ;;
    *)
        echo "work directory must be under $HOME/azl-work" >&2
        exit 1
        ;;
esac

if [ -e "$WORKDIR" ]; then
    echo "work directory already exists: $WORKDIR" >&2
    exit 1
fi

mkdir -p "$WORKDIR"
awk '
    /<packages type="image">/ { image_packages = 1; next }
    /<\/packages>/ { image_packages = 0 }
    image_packages && match($0, /<package name="[^"]+"/) {
        package = substr($0, RSTART, RLENGTH)
        sub(/^<package name="/, "", package)
        sub(/"$/, "", package)
        print package
    }
' "$REPO_DIR/kiwi/azl-desktop-installer.kiwi" > "$WORKDIR/packages.txt"

podman run --rm \
    -v "$WORKDIR:/work:Z" \
    -v "$REPO_DIR/assets/pki/rpm-gpg:/work/keys:ro,Z" \
    fedora:43 \
    bash -exo pipefail -c '
        mkdir -p /work/repos /work/installroot/etc/pki/rpm-gpg /etc/pki/rpm-gpg
        for k in RPM-GPG-KEY-azurelinux-4.0-primary RPM-GPG-KEY-fedora-43-primary; do
            install -m 0644 "/work/keys/$k" "/etc/pki/rpm-gpg/$k"
            install -m 0644 "/work/keys/$k" "/work/installroot/etc/pki/rpm-gpg/$k"
            rpm --import "/etc/pki/rpm-gpg/$k" 2>/dev/null || true
        done
        cat > /work/repos/azurelinux-base.repo << EOF
[azurelinux-base]
name=Azure Linux base
baseurl=https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-4.0-primary
priority=10
EOF
        cat > /work/repos/azurelinux-microsoft.repo << EOF
[azurelinux-microsoft]
name=Azure Linux Microsoft
baseurl=https://packages.microsoft.com/azurelinux/4.0/beta/microsoft/x86_64
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-4.0-primary
priority=10
EOF
        cat > /work/repos/fedora43.repo << EOF
[fedora43]
name=Fedora desktop runtime
baseurl=https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-43-primary
priority=50
EOF
        mapfile -t packages < /work/packages.txt
        dnf5 -y --setopt=reposdir=/work/repos \
            --setopt=install_weak_deps=False \
            --installroot=/work/installroot \
            --releasever=4.0 \
            install --downloadonly "${packages[@]}"
    '
