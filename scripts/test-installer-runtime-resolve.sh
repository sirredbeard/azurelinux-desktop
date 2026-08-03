#!/usr/bin/env bash
# Resolve the complete KIWI installer runtime against its Azure-preferred and
# Fedora fallback repositories without requiring KIWI loop or bind mounts.
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
    fedora:43 \
    bash -exo pipefail -c '
        mkdir -p /work/repos /work/installroot
        cat > /work/repos/azurelinux-base.repo << EOF
[azurelinux-base]
name=Azure Linux base
baseurl=https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64
enabled=1
gpgcheck=0
priority=10
EOF
        cat > /work/repos/azurelinux-microsoft.repo << EOF
[azurelinux-microsoft]
name=Azure Linux Microsoft
baseurl=https://packages.microsoft.com/azurelinux/4.0/beta/microsoft/x86_64
enabled=1
gpgcheck=0
priority=10
EOF
        cat > /work/repos/fedora43.repo << EOF
[fedora43]
name=Fedora desktop runtime
baseurl=https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/
enabled=1
gpgcheck=0
priority=50
EOF
        mapfile -t packages < /work/packages.txt
        dnf5 -y --setopt=reposdir=/work/repos \
            --setopt=install_weak_deps=False \
            --installroot=/work/installroot \
            --releasever=4.0 \
            install --downloadonly "${packages[@]}"
    '
