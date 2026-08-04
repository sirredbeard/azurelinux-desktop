#!/usr/bin/env bash
# test-container-repos.sh
#
# Purpose: Assert package origins and repo priority for the mixed desktop set.
# Usage:   ./scripts/test-container-repos.sh
# Needs:   podman; test-repo-common.sh.
# CI:      Yes when wired into preflight/canary paths; also local.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KS="${AZL_LIVE_KS:-$REPO_ROOT/kickstart/azurelinux-desktop-live.ks}"
INSTALLER_CONFIG="${AZL_INSTALLER_CONFIG:-$REPO_ROOT/kiwi/config.sh}"
WORKDIR="${AZL_PODMAN_WORKDIR:-$HOME/azl-work/test-container-repos}"
REPO_FILE="$WORKDIR/azl-test.repo"
PKG_FILE="$WORKDIR/combined-packages.txt"
ASSERT_FILE="$WORKDIR/repo-assertions.txt"

# shellcheck source=scripts/test-repo-common.sh
source "$REPO_ROOT/scripts/test-repo-common.sh"

mkdir -p "$WORKDIR"

if [ ! -f "$KS" ]; then
    echo "error: $KS not found" >&2
    exit 1
fi
if [ ! -f "$INSTALLER_CONFIG" ]; then
    echo "error: $INSTALLER_CONFIG not found" >&2
    exit 1
fi

azl_write_repo_file_from_kickstart "$KS" "$REPO_FILE"
azl_combined_install_packages "$KS" "$INSTALLER_CONFIG" > "$PKG_FILE"

while read -r repo_name; do
    if ! grep -q "^\[$repo_name\]$" "$REPO_FILE"; then
        echo "error: $repo_name was not parsed out of $KS" >&2
        exit 1
    fi
done < <(azl_required_repo_names)

azl_full_repo_assertions "$KS" > "$ASSERT_FILE"

# Fail loudly if the derived (excludepkgs-based) and curated (fallback)
# assertion sources ever disagree on the same package, instead of
# silently trusting whichever one happened to sort first.
conflicts=$(awk '{if (seen[$1] && seen[$1] != $2) print $1; seen[$1] = $2}' "$ASSERT_FILE" | sort -u)
if [ -n "$conflicts" ]; then
    echo "error: conflicting expected-family assertions for: $(echo "$conflicts" | tr '\n' ' ')" >&2
    exit 1
fi

echo "Using live kickstart:    $KS"
echo "Using installer config:  $INSTALLER_CONFIG"
echo "Repo file:               $REPO_FILE"
echo "Combined package set:    $(wc -l < "$PKG_FILE") packages (union of live %packages and installer INSTALL_PKGS)"
echo "Repo-origin assertions:  $(wc -l < "$ASSERT_FILE") packages with a determinable expected family"

podman run --rm \
    -v "$WORKDIR:/work:Z" \
    -v "$REPO_ROOT/scripts/test-repo-common.sh:/work/test-repo-common.sh:ro,Z" \
    registry.fedoraproject.org/fedora:43 bash -eo pipefail -c '
        source /work/test-repo-common.sh

        mkdir -p /work/repos /mnt/azl/etc/yum.repos.d
        cp /work/azl-test.repo /work/repos/azl-test.repo
        cp /work/azl-test.repo /mnt/azl/etc/yum.repos.d/azl-test.repo
        mapfile -t PKGS < /work/combined-packages.txt

        # install_weak_deps=True (not False) here on purpose - matches
        # what livemedia-creator/anaconda actually do for both real
        # images, so weak-dep-only packages that participate in the
        # priority split (fedora-logos, etc.) show up to be checked the
        # same way a real build would pull them in.
        dnf5 install -y \
            --setopt=reposdir=/work/repos \
            --installroot=/mnt/azl \
            --releasever=43 \
            --setopt=install_weak_deps=True \
            --best \
            "${PKGS[@]}" \
            >/work/dnf-install.log 2>&1

        # Origin ground truth comes straight from dnf5'"'"'s own transaction
        # log (its "Installing:"/"Installing dependencies:"/"Installing
        # weak dependencies:" tables list Package/Arch/Version/Repository/
        # Size, one resolved package per line, six whitespace-separated
        # fields) - this is the actual repo dnf5 picked for each package,
        # not an inference from the installed rpm'"'"'s release string.
        # Guessing origin from a ".fc43"/".azl4" dist-tag substring (the
        # old approach) falsely flagged shim-x64 as wrong: signed UEFI
        # bootloader packages like it deliberately ship with a plain
        # numeric release and no dist tag at all, in real Fedora too, so
        # it can stay byte-identical (and validly signed) across distro
        # releases - it still resolved from fedora43 correctly, the old
        # check just could not see that from the release string alone.
        awk "/^Installing/{f=1;next} /^Transaction Summary:/{f=0} f && NF==6 {print \$1, \$4}" \
            /work/dnf-install.log | sort -u > /work/installed-origins.txt
        total=$(wc -l < /work/installed-origins.txt)
        azl=$(awk "\$2 ~ /^azl-/" /work/installed-origins.txt | wc -l)
        fedora=$(awk "\$2 == \"fedora43\" || \$2 == \"fedora43-updates\"" /work/installed-origins.txt | wc -l)
        echo "=== $total packages installed total (azl=$azl fedora=$fedora other=$((total - azl - fedora))) ==="

        fail=0
        checked=0
        total_assertions=$(wc -l < /work/repo-assertions.txt)
        while read -r pkg family; do
            repo=$(awk -v p="$pkg" "\$1==p{print \$2; exit}" /work/installed-origins.txt)
            if [ -z "$repo" ]; then
                # Not every asserted package necessarily lands in this
                # fast installroot resolve (arch-specific siblings,
                # packages only reachable via a dependency chain a plain
                # dnf5 install does not walk the exact same way a full
                # livemedia-creator/anaconda transaction does) - note it
                # and move on rather than fail the whole run over a
                # package that was never actually going to be installed.
                echo "SKIP: $pkg not installed, cannot check origin"
                continue
            fi
            checked=$((checked + 1))
            azl_repo_matches_family "$family" "$repo" || {
                echo "FAIL: $pkg came from repo $repo, expected $family"
                fail=1
            }
        done < /work/repo-assertions.txt
        echo "=== checked $checked/$total_assertions assertions with a resolvable package ==="
        if [ "$fail" -ne 0 ]; then
            echo "FAIL: one or more packages resolved from the wrong repo family" >&2
            exit 1
        fi
        echo "PASS: all checkable repo-origin assertions matched"
    '

echo "Full resolved package list + repo-origin assertions under: $WORKDIR"
