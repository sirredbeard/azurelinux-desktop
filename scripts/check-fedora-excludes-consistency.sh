#!/usr/bin/env bash
# check-fedora-excludes-consistency.sh
#
# Purpose: Fail if the fedora45/fedora45-updates excludepkgs list drifts
#   between the live kickstart, the installer's kiwi/config.sh
#   FEDORA_EXCLUDES, and the two shipped .repo assets. These four places
#   all claw the same AZL-owned packages away from Fedora
#   (findings/dnf-update-pinentry-nm-wwan.md, findings/fedora-azl-repo-mixing.md).
#   A package added to one and missed in the others reproduces the same
#   class of "dnf update" dependency break every time (see
#   findings/dnf-update-devel-libblkid-libmount.md).
# Usage:   ./scripts/check-fedora-excludes-consistency.sh
# Needs:   bash, grep, sed, sort, tr, awk, diff
# CI:      Runs in the check-consistency workflow on kickstart, kiwi,
#          and repo asset changes. Also run it from local preflight
#          before pushing repo/kickstart changes.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Kickstart: excludepkgs is inline on the "repo --name=<section>..." line.
# Match the trailing space after the name so "fedora45" does not also
# swallow "fedora45-updates".
extract_kickstart() {
    grep "^repo --name=$2 " "$1" | grep -o 'excludepkgs=[^ ]*' \
        | sed 's/^excludepkgs=//' | tr ',' '\n' | sort -u
}

# Bash var: FEDORA_EXCLUDES="pkg1,pkg2,..." (one list, shared by both
# --setopt=fedora45.excludepkgs and --setopt=fedora45-updates.excludepkgs
# in kiwi/config.sh, so there is no fedora45 vs fedora45-updates split to
# check here).
extract_bashvar() {
    grep -o 'FEDORA_EXCLUDES="[^"]*"' "$1" | sed 's/FEDORA_EXCLUDES="//;s/"$//' \
        | tr ',' '\n' | sort -u
}

# INI repo file: excludepkgs= lives inside a [fedora45] or
# [fedora45-updates] section, several lines below the header. Match the
# section header exactly so "[fedora45]" does not also swallow
# "[fedora45-updates]".
extract_ini() {
    awk -v want="[$2]" '/^\[/{f = ($0 == want)} f && /^excludepkgs=/' "$1" \
        | sed 's/^excludepkgs=//' | tr ',' '\n' | sort -u
}

trap 'rm -f /tmp/azl-fedora-excludes.*.'"$$" EXIT
status=0

# Catch drift between fedora45 and fedora45-updates within the same file
# first: the cross-file diff below only ever compares one section, so a
# mismatch here would otherwise pass silently.
ks="kickstart/azurelinux-desktop-live.ks"
extract_kickstart "$ks" fedora45 > /tmp/azl-fedora-excludes.a.$$
extract_kickstart "$ks" fedora45-updates > /tmp/azl-fedora-excludes.b.$$
if ! diff -u /tmp/azl-fedora-excludes.a.$$ /tmp/azl-fedora-excludes.b.$$; then
    echo "error: fedora45 vs fedora45-updates excludepkgs mismatch within $ks" >&2
    status=1
fi
for f in assets/yum.repos.d/azl-desktop-fedora.repo assets/yum.repos.d/azurelinux-desktop.repo; do
    extract_ini "$f" fedora45 > /tmp/azl-fedora-excludes.a.$$
    extract_ini "$f" fedora45-updates > /tmp/azl-fedora-excludes.b.$$
    if ! diff -u /tmp/azl-fedora-excludes.a.$$ /tmp/azl-fedora-excludes.b.$$; then
        echo "error: fedora45 vs fedora45-updates excludepkgs mismatch within $f" >&2
        status=1
    fi
done

# Cross-file comparison, using the fedora45 section (already confirmed
# above to match fedora45-updates within each file).
extract_kickstart kickstart/azurelinux-desktop-live.ks fedora45 > /tmp/azl-fedora-excludes.live.$$
extract_bashvar kiwi/config.sh > /tmp/azl-fedora-excludes.kiwi.$$
extract_ini assets/yum.repos.d/azl-desktop-fedora.repo fedora45 > /tmp/azl-fedora-excludes.fedora_repo.$$
extract_ini assets/yum.repos.d/azurelinux-desktop.repo fedora45 > /tmp/azl-fedora-excludes.desktop_repo.$$

for other in kiwi fedora_repo desktop_repo; do
    if ! diff -u "/tmp/azl-fedora-excludes.live.$$" "/tmp/azl-fedora-excludes.$other.$$"; then
        echo "error: excludepkgs mismatch between live and $other" >&2
        status=1
    fi
done

# The list has to be wired in, not just defined: kiwi's offline download
# must attach it to both Fedora repos.
for opt in 'fedora45.excludepkgs="$FEDORA_EXCLUDES"' 'fedora45-updates.excludepkgs="$FEDORA_EXCLUDES"'; do
    if ! grep -qF -- "--setopt=$opt" kiwi/config.sh; then
        echo "error: kiwi/config.sh does not attach FEDORA_EXCLUDES via $opt" >&2
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "ok: fedora excludepkgs lists match across kickstart, kiwi, and assets"
fi
exit "$status"
