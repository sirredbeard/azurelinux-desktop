#!/usr/bin/env bash
# Builds a small OCI container image straight from this project's own
# repo/priority setup, the same idea as Azure Linux's own upstream
# container-base (microsoft/azurelinux base/images/container-base/
# container-base.kiwi): a tiny, non-bootable, no-systemd image that
# ships nothing but the release/repo package plus whatever it's there
# to demonstrate. Their `core` container is base-only (filesystem,
# bash, azurelinux-release-container, azurelinux-repos); ours adds the
# one thing this project actually exists to prove - that the
# Azure-Linux-base + Fedora/GNOME-layer repo priority split in
# kickstart/azurelinux-desktop-live.ks resolves cleanly and keeps
# picking packages from the intended repo, not just at ISO-build time.
#
# This is NOT a container version of the full desktop - a GNOME
# session needs a running systemd, D-Bus, and a display, none of which
# make sense in a plain OCI container. It's a lightweight, publishable
# proof of the repo-priority mechanism, small enough to build and push
# on every run, and pullable by anyone who wants to inspect/test the
# hybrid resolution without building a full ISO or disk image.
#
# Reuses the exact repo --name=... parsing approach from
# scripts/podman-test-azl4-fedora43.sh (see that script's comments for
# why: always test/ship what the kickstart actually says, never a
# hand-maintained second copy of it).
#
# Usage (from repo root, needs podman or buildah):
#   ./scripts/build-hybrid-container.sh [image-ref]
#
# image-ref defaults to localhost/azurelinux-desktop-hybrid:latest.
# Set PUSH=1 (and have already `podman login`'d) to push it too - the
# GitHub Actions workflow does this against ghcr.io.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KS="$REPO_ROOT/kickstart/azurelinux-desktop-live.ks"
IMAGE_REF="${1:-localhost/azurelinux-desktop-hybrid:latest}"

if [ ! -f "$KS" ]; then
    echo "error: $KS not found - run this from a checkout of the repo" >&2
    exit 1
fi

# Same repo-parsing awk as podman-test-azl4-fedora43.sh - see that
# script for a line-by-line explanation of why each field is handled
# the way it is (mirrorlist vs baseurl, the quote() escaping, etc).
# shellcheck disable=SC1003
REPO_SETUP=$(awk '
function quote(s) { gsub(/'"'"'/, "'"'"'\\'"'"''"'"'", s); return "'"'"'" s "'"'"'" }
/^repo --name=/ {
    name=""; url=""; cost=""; excl="";
    n=split($0, parts, " --");
    for (i=1;i<=n;i++) {
        p=parts[i];
        if (p ~ /^name=/) { name=substr(p,6) }
        else if (p ~ /^baseurl=/) { url=substr(p,9) }
        else if (p ~ /^mirrorlist=/) { url=substr(p,12); ismirror=1 }
        else if (p ~ /^cost=/) { cost=substr(p,6) }
        else if (p ~ /^excludepkgs=/) { excl=substr(p,13) }
    }
    printf "REPO_NAMES+=(%s)\n", quote(name);
    printf "REPO_URLS+=(%s)\n", quote(url);
    printf "REPO_COSTS+=(%s)\n", quote(cost);
    printf "REPO_EXCLUDES+=(%s)\n", quote(excl == "" ? "-" : excl);
    printf "REPO_MIRROR+=(%s)\n", quote(ismirror == 1 ? "1" : "0");
    ismirror=0;
}
' "$KS")

declare -a REPO_NAMES REPO_URLS REPO_COSTS REPO_EXCLUDES REPO_MIRROR
eval "$REPO_SETUP"

echo "=== ${#REPO_NAMES[@]} repos parsed: ${REPO_NAMES[*]} ==="

# The proof-of-priority package set: azurelinux-release plus a couple
# of base packages from azl-base (cost=1, wins ties), and a handful of
# small Fedora GNOME-stack libraries that only exist in the Fedora repo
# (cost=50) - enough to force real cross-repo dependency resolution
# without pulling in the whole desktop (no X server, no compositor, no
# systemd - none of that runs meaningfully in a plain OCI container
# anyway, same reasoning Azure Linux's own container-base uses to ship
# systemd=false). If any of these ever resolve from the wrong repo, the
# same priority setup backing the real desktop build has broken.
PKGS=(
    filesystem
    bash
    azurelinux-release
    glib2
    gtk4
)

WORKDIR="${AZL_CONTAINER_WORKDIR:-$HOME/azl-work/build-hybrid-container}"
# podman unshare, not a plain rm - a previous run's rootfs may contain
# files created under rootless podman's mapped root user namespace
# (mode 000 files, directories only that mapped root can traverse),
# which a bare host-user `rm -rf` can't remove.
podman unshare rm -rf "$WORKDIR" 2>/dev/null || rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
printf '%s\n' "${PKGS[@]}" > "$WORKDIR/pkglist.txt"

REPO_FILE="$WORKDIR/azl-hybrid.repo"
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
        echo "gpgcheck=0"
        echo "cost=${REPO_COSTS[$i]}"
        if [ "${REPO_EXCLUDES[$i]}" != "-" ]; then
            echo "excludepkgs=${REPO_EXCLUDES[$i]}"
        fi
        echo
    } >> "$REPO_FILE"
done

ROOTFS="$WORKDIR/rootfs"
mkdir -p "$ROOTFS/etc/yum.repos.d"
cp "$REPO_FILE" "$ROOTFS/etc/yum.repos.d/azl-hybrid.repo"

echo "=== Resolving hybrid package set into $ROOTFS ==="
# /mnt/azl has to be a bind mount of the host's $ROOTFS, not a path
# internal to this throwaway container - otherwise everything dnf5
# installs there vanishes the moment the container exits with --rm,
# and the later `tar -C "$ROOTFS"` on the host packages up nothing but
# the repo file copied in beforehand.
podman run --rm \
    -v "$WORKDIR:/work:Z" \
    -v "$ROOTFS:/mnt/azl:Z" \
    registry.fedoraproject.org/fedora:43 bash -exo pipefail -c '
        # /mnt/azl/etc/yum.repos.d/azl-hybrid.repo already exists here -
        # it is the same bind-mounted $ROOTFS the host wrote it into
        # above, nothing to copy in.
        dnf5 install -y \
            --setopt=reposdir=/mnt/azl/etc/yum.repos.d \
            --installroot=/mnt/azl --releasever=43 \
            --setopt=install_weak_deps=False \
            $(cat /work/pkglist.txt) 2>&1 | tail -60
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
        rm -rf /mnt/azl/var/cache/* /mnt/azl/var/log/* \
               /mnt/azl/usr/share/doc/* /mnt/azl/usr/share/man/*
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
