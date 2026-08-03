#!/usr/bin/env bash
# Stage 1 of the three-stage test pipeline in README.md's "How it's
# tested" section: resolve and install the live ISO's real %packages
# list into a throwaway installroot with dnf, before ever spending a
# full lorax build on it. This is where every packaging conflict so far
# (grub2/fuse3 ABI fork, dnf5daemon-server version floor, glibc/gtk4
# symbol floor, the fwupd/libcbor soname fork) actually got caught.
#
# Pulls the package list and every repo --cost=/--excludepkgs= setting
# straight out of kickstart/azurelinux-desktop-live.ks instead of
# hardcoding a second copy here that can silently drift out of sync -
# this script is meant to always test what the live ISO's kickstart
# would actually resolve, not a snapshot of it from whenever this file
# was last hand-edited.
#
# Usage (from repo root, needs podman):
#   ./scripts/podman-test-azl4-fedora43.sh
#
# Runs inside a plain `podman run fedora:43` container - no --privileged,
# no /dev mount, no real ISO/ostree work happens here, just a dnf
# --installroot resolve+install into a container-local directory, which
# is enough to catch every dependency conflict this project has actually
# hit so far without spending a real lorax build to find them.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KS="$REPO_ROOT/kickstart/azurelinux-desktop-live.ks"

if [ ! -f "$KS" ]; then
    echo "error: $KS not found - run this from a checkout of the repo" >&2
    exit 1
fi

# Extract the exact repo --name=... lines from the kickstart, translate
# each into a --setopt=<repo>.cost=/.excludepkgs= pair, same mechanism
# dnf5 download uses in kiwi/config.sh. awk keeps this a single pass
# over the file instead of shelling out to grep/sed per-repo.
# quote() single-quotes a value for safe use inside the eval'd
# REPO_*+=(...) assignments below - repo URLs contain unescaped shell
# metacharacters (RPMFusion's mirrorlist= URLs have a literal & in the
# query string), so this can't be left unquoted or passed through printf
# %s as-is.
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

# Pull the real %packages --nocore --excludedocs ... %end block, minus
# comments/blank lines/group refs (@... group syntax isn't meaningful
# for a plain dnf install line here) and leading-"-" exclusions (kickstart's
# "-pkgname" removes a package a @group would have pulled in - with no
# @group on this line, dnf5 install just sees a bare "-pkgname" as an
# unknown CLI flag, not a package to omit).
mapfile -t PKGS < <(awk '/^%packages/{f=1;next}/^%end/{if(f){exit}}f' "$KS" \
    | sed -e 's/#.*$//' -e '/^\s*$/d' -e '/^@/d' -e '/^-/d' -e 's/^\s*//;s/\s*$//')

echo "=== ${#PKGS[@]} packages parsed from $KS ==="
echo "=== ${#REPO_NAMES[@]} repos parsed: ${REPO_NAMES[*]} ==="

WORKDIR="${AZL_PODMAN_WORKDIR:-$HOME/azl-work/podman-test-azl4-fedora43}"
mkdir -p "$WORKDIR"
printf '%s\n' "${PKGS[@]}" > "$WORKDIR/pkglist.txt"

REPO_FILE="$WORKDIR/azl-test.repo"
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
        if [ "${REPO_INCLUDES[$i]}" != "-" ]; then
            echo "includepkgs=${REPO_INCLUDES[$i]}"
        fi
        echo
    } >> "$REPO_FILE"
done

# This host's rootless Podman cannot install its device-filter cgroup. The
# privileged image builders use the same rootful cgroup workaround.
sudo podman run --rm \
    --cgroups=disabled \
    --security-opt label=disable \
    -v "$WORKDIR:/work:Z" \
    registry.fedoraproject.org/fedora:43 bash -exo pipefail -c '
        mkdir -p /mnt/azl/etc/yum.repos.d
        cp /work/azl-test.repo /mnt/azl/etc/yum.repos.d/azl-test.repo
        dnf5 install -y \
            --setopt=reposdir=/mnt/azl/etc/yum.repos.d \
            --installroot=/mnt/azl --releasever=43 \
            --setopt=install_weak_deps=True \
            $(cat /work/pkglist.txt) 2>&1 | tail -80
        echo "=== RESULT ==="
        cat /mnt/azl/etc/os-release 2>&1 | head -5
        chroot /mnt/azl rpm -q glibc systemd mutter gnome-shell azurelinux-release gdm 2>&1 || true
        chroot /mnt/azl rpm -qa --qf "%{name}-%{version}-%{release}.%{arch}\n" 2>/dev/null | sort > /work/pkglist_result.txt
        TOTAL=$(wc -l < /work/pkglist_result.txt)
        AZL=$(grep -c "\.azl4" /work/pkglist_result.txt || true)
        FC=$(grep -c "\.fc43" /work/pkglist_result.txt || true)
        echo "azl4=$AZL fc43=$FC total=$TOTAL"
    '

sudo chown -R "$(id -u):$(id -g)" "$WORKDIR"
echo "Full resolved package list: $WORKDIR/pkglist_result.txt"
