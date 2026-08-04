#!/usr/bin/env bash
# install-copilot-desktop-flatpak.sh
#
# Purpose: Install the unofficial Microsoft Copilot GTK desktop app
#   (com.github.sirredbeard.copilot-desktop-gtk) as a system Flatpak into a
#   rootfs. Pulls org.gnome.Platform//50 from Flathub, then installs the app
#   from the project's GitHub Pages Flatpakref so the Pages remote stays
#   registered for later `flatpak update`. Distinct from the GitHub Copilot
#   GUI RPM / CLI side-load in fetch-latest-thirdparty.sh.
# Usage:   ./scripts/install-copilot-desktop-flatpak.sh ROOTFS [flathub.flatpakrepo]
#          ROOTFS is the install root (/mnt/sysimage, /mnt/azl, / for host).
#          Optional second arg is a staged Flathub .flatpakrepo path; when
#          omitted the script fetches Flathub's published file over the net.
# Needs:  host `flatpak` CLI, network, curl. Fails hard if install or verify
#          steps fail (image builds should not ship without the app).
# CI:     Yes. Live ISO %post --nochroot, installer config.sh offline stage,
#         canary container build.
#
# Notes:  Installs via FLATPAK_USER_DIR pointed at ROOTFS/var/lib/flatpak and
#         `flatpak --user`. That path is the system Flatpak tree on the
#         finished image; using the user CLI avoids needing a privileged
#         ostree "bare" repo init inside build containers. Layout matches
#         what GNOME and `flatpak --system` read from /var/lib/flatpak.

set -euo pipefail

ROOTFS="${1:?usage: $0 ROOTFS [flathub.flatpakrepo]}"
FLATHUB_REPO_FILE="${2:-}"

if [[ ! -d "$ROOTFS" ]]; then
    echo "error: ROOTFS is not a directory: $ROOTFS" >&2
    exit 1
fi

# Resolve to an absolute path so FLATPAK_*_DIR is unambiguous when the
# caller passes a relative installroot.
ROOTFS="$(cd "$ROOTFS" && pwd -P)"

if ! command -v flatpak >/dev/null 2>&1; then
    echo "error: flatpak CLI missing on the build host" >&2
    exit 1
fi

export FLATPAK_USER_DIR="${ROOTFS}/var/lib/flatpak"
# Keep OSTree temp objects on the same filesystem as the install root so a
# tiny build-host /var does not fail a large Platform pull.
export FLATPAK_USER_CACHE_DIR="${ROOTFS}/var/tmp/flatpak-cache"
mkdir -p "$FLATPAK_USER_DIR" "$FLATPAK_USER_CACHE_DIR"

APP_ID="com.github.sirredbeard.copilot-desktop-gtk"
FLATPAKREF_URL="https://sirredbeard.github.io/copilot-desktop-gtk/${APP_ID}.flatpakref"
RUNTIME_REF="org.gnome.Platform//50"

echo "=== Installing Copilot Flatpak into ${FLATPAK_USER_DIR} ==="

if [[ -n "$FLATHUB_REPO_FILE" && -s "$FLATHUB_REPO_FILE" ]]; then
    flatpak remote-add --user --if-not-exists flathub "$FLATHUB_REPO_FILE"
else
    flatpak remote-add --user --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo
fi

# Runtime first so the app install does not surprise-resolve a missing
# Platform mid-transaction on a half-populated image root.
flatpak install --user --noninteractive -y flathub "$RUNTIME_REF"

# flatpakref registers SuggestRemoteName=copilot-desktop-gtk and pulls the
# app from the Pages OSTree. Pages repo is unsigned; flatpakref install
# still works for GitHub Pages hosts the same way the project README shows.
flatpak install --user --noninteractive -y --from "$FLATPAKREF_URL"

flatpak info --user "$APP_ID" >/dev/null
flatpak list --user --app --columns=application,origin | grep -F "$APP_ID"

if ! flatpak remotes --user --columns=name | grep -qx 'copilot-desktop-gtk'; then
    # Belt-and-suspenders: if a future flatpakref path skipped remote
    # registration, add the Pages remote explicitly (no GPG on that host).
    flatpak remote-add --user --if-not-exists --no-gpg-verify \
        copilot-desktop-gtk \
        https://sirredbeard.github.io/copilot-desktop-gtk/copilot-desktop-gtk.flatpakrepo
fi

flatpak remotes --user --columns=name | grep -qx 'copilot-desktop-gtk'

# Exported launcher id used in GNOME Shell favorite-apps lists.
if [[ ! -f "${FLATPAK_USER_DIR}/exports/share/applications/${APP_ID}.desktop" ]]; then
    found="$(find "${FLATPAK_USER_DIR}" -path "*/exports/share/applications/${APP_ID}.desktop" 2>/dev/null | head -1 || true)"
    if [[ -z "$found" ]]; then
        echo "error: exported desktop file missing for ${APP_ID}" >&2
        exit 1
    fi
fi

echo "=== Copilot Flatpak install OK (${APP_ID}) ==="
