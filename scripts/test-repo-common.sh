#!/usr/bin/env bash
# test-repo-common.sh
#
# Purpose: Shared helpers for repo-origin and priority tests. Sourced by
#   test-container-repos.sh and related scripts.
# Usage:   source ./scripts/test-repo-common.sh
# Needs:   bash; dnf inside the test container.
# CI:      Indirect (library for CI/local repo tests).

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
# Azure Linux / Fedora repo split (ms-prod, vscode, edge-canary, rpmfusion-*,
# etc.) are skipped - their excludepkgs entries (e.g. ms-prod's
# aznfs/mdatp) are outright removals, not a family assertion. Emits
# "pkg family" pairs, one per line.
azl_derive_repo_assertions() {
    # Read excludepkgs from assets/yum.repos.d (or a path passed as $1).
    # Prefer static .repo files over kickstart awk parsing.
    local src="${1:-}"
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local repo_file="$repo_root/assets/yum.repos.d/azurelinux-desktop.repo"
    if [[ -n "$src" && -f "$src" && "$src" == *.repo ]]; then
        repo_file="$src"
    elif [[ -n "$src" && -d "$src" ]]; then
        repo_file="$src/azurelinux-desktop.repo"
    fi
    [[ -f "$repo_file" ]] || {
        echo "azl_derive_repo_assertions: missing $repo_file" >&2
        return 1
    }
    local name="" excl="" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            \[*\])
                name="${line#\[}"; name="${name%\]}"
                excl=""
                ;;
            excludepkgs=*)
                excl="${line#excludepkgs=}"
                if [[ -n "$excl" ]]; then
                    if [[ "$name" == azl-* ]]; then
                        family=fedora
                    elif [[ "$name" == fedora43* ]]; then
                        family=azl
                    else
                        continue
                    fi
                    IFS=',' read -r -a pkgs <<< "$excl"
                    for pkg in "${pkgs[@]}"; do
                        [[ -n "$pkg" ]] || continue
                        printf '%s %s\n' "$pkg" "$family"
                    done
                fi
                ;;
        esac
    done < "$repo_file"
}

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
    # Name kept for callers. Copies the static canary/live-aligned repo file.
    local _ks_unused="${1:-}"
    local repo_file="$2"
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local src="$repo_root/assets/yum.repos.d/azurelinux-desktop.repo"
    [[ -f "$src" ]] || {
        echo "azl_write_repo_file_from_kickstart: missing $src" >&2
        return 1
    }
    install -m 0644 "$src" "$repo_file"
}


