#!/usr/bin/env bash
# Shared repo-policy helpers for the fast podman check and the in-guest
# upgrade/origin checks. The package lists are intentionally small and
# curated; the repo definitions themselves are always parsed from the real
# kickstart so the policy stays tied to the source of truth.

azl_repo_expected_family() {
    case "$1" in
        systemd|kernel|kernel-core|NetworkManager|bluez|fwupd-efi)
            printf 'azl\n'
            ;;
        glibc|gdm|gnome-shell|gnome-software|flatpak|wpa_supplicant|fwupd)
            printf 'fedora\n'
            ;;
        *)
            return 1
            ;;
    esac
}

azl_repo_origin_packages() {
    cat <<'EOF2'
systemd
kernel
kernel-core
NetworkManager
bluez
fwupd-efi
glibc
gdm
gnome-shell
gnome-software
flatpak
wpa_supplicant
fwupd
EOF2
}

azl_install_candidates() {
    case "$1" in
        azl)
            cat <<'EOF2'
strace
tree
lsof
jq
tcpdump
EOF2
            ;;
        fedora)
            cat <<'EOF2'
gnome-tweaks
file-roller
seahorse
gnome-extensions-app
EOF2
            ;;
        *)
            return 1
            ;;
    esac
}

azl_repo_matches_family() {
    local family="$1"
    local repoid="$2"

    case "$family" in
        azl)
            [[ "$repoid" == azl-* ]]
            ;;
        fedora)
            [[ "$repoid" == fedora43 || "$repoid" == fedora43-updates ]]
            ;;
        *)
            return 1
            ;;
    esac
}

azl_release_matches_family() {
    local family="$1"
    local release="$2"

    case "$family" in
        azl)
            [[ "$release" == *azl4* ]]
            ;;
        fedora)
            [[ "$release" == *fc43* ]]
            ;;
        *)
            return 1
            ;;
    esac
}

azl_required_repo_names() {
    cat <<'EOF2'
azl-base
azl-microsoft
fedora43
fedora43-updates
EOF2
}

#----------------------------------------------------------------------
# Full real package lists, parsed straight from source instead of hand-
# maintained here - used by the fuller repo-priority test so it actually
# installs the same real package sets the live/installer images do, not
# just the small curated subset above.
#----------------------------------------------------------------------

azl_live_kickstart_packages() {
    local ks="$1"
    # Same %packages...%end extraction as the older podman-test-azl4-
    # fedora43.sh: strip comments/blank lines, "@group" lines (--nocore
    # means no comps groups exist to expand here anyway), and leading-
    # "-" exclusion lines (those remove a package, they are not one to
    # install).
    awk '/^%packages/{f=1;next}/^%end/{if(f){exit}}f' "$ks" \
        | sed -e 's/#.*$//' -e '/^\s*$/d' -e '/^@/d' -e '/^-/d' \
              -e 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

azl_installer_config_packages() {
    local config_sh="$1"
    # kiwi/config.sh's INSTALL_PKGS=( ... ) is a plain bash array, no
    # "-pkgname" exclusion syntax inside it (those live separately in
    # generate_packages_section(), see azl_installer_exclusions below) -
    # just strip comments and blank lines.
    awk '/^INSTALL_PKGS=\(/{f=1;next}/^\)/{if(f){exit}}f' "$config_sh" \
        | sed -e 's/#.*$//' -e '/^\s*$/d' \
              -e 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# generate_packages_section() in kiwi/config.sh appends these as
# "-pkgname" lines onto the installer's own generated kickstart, after
# INSTALL_PKGS - they never actually get positively installed, so a
# combined package list built from the two positive lists above has to
# strip them back out to match what the installer image really ends up
# asking dnf5 for.
azl_installer_exclusions() {
    cat <<'EOF2'
gnome-tour
malcontent-control
mdatp
EOF2
}

# Union of what the live ISO and the installer ISO actually ask dnf5 to
# install, minus the installer's own post-INSTALL_PKGS removals - the
# real combined package set both images resolve through this project's
# azl/fedora priority scheme, not a hand-picked few representative names.
azl_combined_install_packages() {
    local live_ks="$1" installer_config="$2"
    {
        azl_live_kickstart_packages "$live_ks"
        azl_installer_config_packages "$installer_config"
    } | grep -vxF -f <(azl_installer_exclusions) | sort -u
}

# Derive pkg->family assertions straight from the kickstart's own
# repo --name=...--excludepkgs=... claw-back lists, instead of hand-
# maintaining a second copy of "which package should come from which
# repo" here that can silently drift out of sync. A package excluded
# from an azl-* repo is expected to resolve from fedora (that is the
# whole point of excluding it there); a package excluded from a
# fedora43* repo is expected to resolve from azl. Repos outside the
# azl/fedora hybrid split (ms-prod, vscode, edge-canary, rpmfusion-*,
# etc.) are skipped - their excludepkgs entries (e.g. ms-prod's
# aznfs/mdatp) are outright removals, not a family assertion. Emits
# "pkg family" pairs, one per line.
azl_derive_repo_assertions() {
    local ks="$1"
    awk '
    /^repo --name=/ {
        name = ""; excl = "";
        n = split($0, parts, " --");
        for (i = 1; i <= n; i++) {
            p = parts[i];
            if (p ~ /^name=/) { name = substr(p, 6) }
            else if (p ~ /^excludepkgs=/) { excl = substr(p, 13) }
        }
        if (excl == "") { next }
        if (name ~ /^azl-/) { family = "fedora" }
        else if (name ~ /^fedora43/) { family = "azl" }
        else { next }
        n2 = split(excl, pkgs, ",");
        for (j = 1; j <= n2; j++) { print pkgs[j], family }
    }
    ' "$ks"
}

# Merges the derived excludepkgs-based assertions above with the small
# curated fallback list (azl_repo_origin_packages/azl_repo_expected_family)
# for packages that win by "azl just does not build this at all" rather
# than an explicit excludepkgs= claw-back (glibc, gdm, gnome-shell,
# gnome-software, flatpak, wpa_supplicant, fwupd - none of these appear in
# any excludepkgs list). Emits "pkg family" pairs, one per line, and does
# NOT itself detect conflicts between the two sources - callers should
# check for a package appearing twice with two different families before
# trusting this output, since that would mean the two sources disagree.
azl_full_repo_assertions() {
    local ks="$1"
    {
        azl_derive_repo_assertions "$ks"
        while read -r pkg; do
            family=$(azl_repo_expected_family "$pkg" 2>/dev/null) || continue
            printf '%s %s\n' "$pkg" "$family"
        done < <(azl_repo_origin_packages)
    } | sort -u
}

azl_write_repo_file_from_kickstart() {
    local ks="$1"
    local repo_file="$2"
    local repo_setup
    local i

    # shellcheck disable=SC1003
    repo_setup=$(awk '
function quote(s) { gsub(/'"'"'/, "'"'"'\\'"'"''"'"'", s); return "'"'"'" s "'"'"'" }
/^repo --name=/ {
    name=""; url=""; cost=""; excl=""; ismirror=0;
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
    printf "REPO_COSTS+=(%s)\n", quote(cost == "" ? "50" : cost);
    printf "REPO_EXCLUDES+=(%s)\n", quote(excl == "" ? "-" : excl);
    printf "REPO_MIRROR+=(%s)\n", quote(ismirror == 1 ? "1" : "0");
}
' "$ks")

    declare -a REPO_NAMES=() REPO_URLS=() REPO_COSTS=() REPO_EXCLUDES=() REPO_MIRROR=()
    eval "$repo_setup"

    : > "$repo_file"
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
        } >> "$repo_file"
    done
}
