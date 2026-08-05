#!/usr/bin/env bash
# install-rpm-gpg-keys.sh
#
# Purpose: Stage and import RPM OpenPGP keys used by this project's mixed
#   repos (Azure Linux, Fedora, Microsoft, GitHub CLI/Desktop, RPM Fusion,
#   project desktop kmods). Turns gpgcheck=1 into a working path instead of
#   dnf "skipped OpenPGP checks".
# Usage:   ./scripts/install-rpm-gpg-keys.sh [ROOTFS]
#          ROOTFS defaults to /. Keys are read from assets/pki/rpm-gpg next to
#          this repo, or from KEYS_SRC if set.
# Needs:  install, rpm. Optional curl only if a key is missing and URL is known.
# CI:     Yes. Live kickstart %post, installer post paths, canary build.

set -euo pipefail

ROOTFS="${1:-/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEYS_SRC="${KEYS_SRC:-$REPO_ROOT/assets/pki/rpm-gpg}"

if [[ ! -d "$KEYS_SRC" ]]; then
    echo "error: key source directory missing: $KEYS_SRC" >&2
    exit 1
fi

DEST="$ROOTFS/etc/pki/rpm-gpg"
install -d -m 0755 "$DEST"

# Copy every key/symlink from the asset tree. Preserve relative symlinks so
# AZL's RPM-GPG-KEY-azurelinux-4.0-x86_64 -> ...-primary layout matches
# azurelinux.repo's gpgkey=...-$releasever-$basearch pattern.
shopt -s nullglob
for path in "$KEYS_SRC"/*; do
    base="$(basename "$path")"
    # Only key material — skip docs.
    [[ "$base" == README.md ]] && continue
    [[ "$base" == *.md ]] && continue
    if [[ -L "$path" ]]; then
        # Recreate symlink by name; target stays relative as vendored.
        ln -sfn "$(readlink "$path")" "$DEST/$base"
    elif [[ -f "$path" ]]; then
        install -m 0644 "$path" "$DEST/$base"
    fi
done
shopt -u nullglob

# Import material keys into the RPM DB (symlinks resolve to the same primary).
import_one() {
    local f="$1"
    [[ -e "$f" ]] || return 0
    if [[ "$ROOTFS" == "/" ]]; then
        rpm --import "$f" 2>/dev/null || true
    else
        rpm --root="$ROOTFS" --import "$f" 2>/dev/null || true
    fi
}

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
    import_one "$DEST/$key"
done

echo "RPM GPG keys staged under $DEST"
