#!/usr/bin/env bash
# Build the installer ISO locally with the same privileged Fedora container
# shape used by CI. Pass an empty target directory under ~/azl-work.
set -euo pipefail

TARGET="${1:?usage: $0 /path/under/azl-work/target-directory}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

case "$TARGET" in
    "$HOME"/azl-work/*) ;;
    *)
        echo "target directory must be under $HOME/azl-work" >&2
        exit 1
        ;;
esac

if [ -e "$TARGET" ]; then
    echo "target directory already exists: $TARGET" >&2
    exit 1
fi

mkdir -p "$TARGET/source/installer-result"
cp -a "$REPO_DIR/." "$TARGET/source"
tar -C "$TARGET/source" \
    --transform 's,^assets,opt/azl-desktop-assets,' \
    -czf "$TARGET/source/kiwi/assets.tar.gz" \
    assets

podman run --rm --privileged \
    -v /dev:/dev \
    --security-opt label=disable \
    -v "$TARGET/source:/workspace" \
    --tmpfs /tmp:exec,size=8g \
    fedora:43 \
    bash -exo pipefail -c '
        dnf5 install -y \
            python3-kiwi dracut-live squashfs-tools xorriso dosfstools mtools \
            grub2-tools grub2-tools-extra shim-x64 grub2-efi-x64-cdboot \
            createrepo_c curl isomd5sum qemu-img e2fsprogs
        /workspace/scripts/patch-kiwi-dnf5.sh
        KIWI_NG=kiwi-ng
        command -v kiwi-ng >/dev/null 2>&1 || KIWI_NG=kiwi-ng-3
        "$KIWI_NG" --debug system build \
            --description /workspace/kiwi \
            --target-dir /workspace/installer-result
    ' 2>&1 | tee "$TARGET/kiwi-build.log"

find "$TARGET/source/installer-result" -maxdepth 1 -type f -name '*.iso' -print
