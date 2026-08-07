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
#
# Trust:  Pages stream is GPG-signed (0.1.15+). Assert remote gpg-verify=true
#         after install. Non-root system updates also need the image polkit
#         rule (assets/polkit-1/rules.d/10-azurelinux-desktop-flatpak.rules).

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
REMOTE_NAME="copilot-desktop-gtk"
FLATPAKREF_URL="https://sirredbeard.github.io/copilot-desktop-gtk/${APP_ID}.flatpakref"
REPO_URL="https://sirredbeard.github.io/copilot-desktop-gtk/${REMOTE_NAME}.flatpakrepo"
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

# flatpakref registers SuggestRemoteName=copilot-desktop-gtk, embeds GPGKey=
# when Pages is signed, and pulls the app from the Pages OSTree.
flatpak install --user --noninteractive -y --from "$FLATPAKREF_URL"

flatpak info --user "$APP_ID" >/dev/null
flatpak list --user --app --columns=application,origin | grep -F "$APP_ID"

if ! flatpak remotes --user --columns=name | grep -qx "$REMOTE_NAME"; then
    # Belt-and-suspenders: if a future flatpakref path skipped remote
    # registration, add the Pages remote. Prefer GPG from .flatpakrepo;
    # only fall back to --no-gpg-verify for a legacy unsigned stream.
    if curl -fsSL "$REPO_URL" | grep -q '^GPGKey='; then
        flatpak remote-add --user --if-not-exists "$REMOTE_NAME" "$REPO_URL"
    else
        echo "warning: Pages .flatpakrepo has no GPGKey=; adding --no-gpg-verify" >&2
        flatpak remote-add --user --if-not-exists --no-gpg-verify \
            "$REMOTE_NAME" "$REPO_URL"
    fi
fi

flatpak remotes --user --columns=name | grep -qx "$REMOTE_NAME"

# Require GPG on the Pages remote when the published .flatpakrepo carries a key.
# Non-root system updates and GNOME Software need gpg-verify=true.
if curl -fsSL "$REPO_URL" | grep -q '^GPGKey='; then
    gpg_state="$(flatpak remotes --user --show-details 2>/dev/null \
        | awk -v r="$REMOTE_NAME" '
            $0 ~ "^" r " " || $1 == r {hit=1}
            hit && /gpg-verify/ {print; exit}
        ' || true)"
    # Prefer config file under the install root (stable across flatpak versions).
    remote_cfg=""
    for cand in \
        "${FLATPAK_USER_DIR}/repo/config" \
        "${ROOTFS}/var/lib/flatpak/repo/config"; do
        if [[ -f "$cand" ]]; then remote_cfg="$cand"; break; fi
    done
    if [[ -n "$remote_cfg" ]]; then
        # Section is [remote "copilot-desktop-gtk"]
        if ! awk -v name="$REMOTE_NAME" '
            $0 == "[remote \"" name "\"]" {insec=1; next}
            /^\[/ {insec=0}
            insec && $0 ~ /^gpg-verify=true/ {found=1}
            END {exit found ? 0 : 1}
        ' "$remote_cfg"; then
            # Some installs store no-gpg-verify=true instead of gpg-verify=false.
            if awk -v name="$REMOTE_NAME" '
                $0 == "[remote \"" name "\"]" {insec=1; next}
                /^\[/ {insec=0}
                insec && ($0 ~ /^gpg-verify=false/ || $0 ~ /^gpg-verify=0/ || $0 ~ /^no-gpg-verify=true/) {bad=1}
                END {exit bad ? 0 : 1}
            ' "$remote_cfg"; then
                echo "error: remote $REMOTE_NAME is not GPG-verified in $remote_cfg" >&2
                awk -v name="$REMOTE_NAME" '
                    $0 == "[remote \"" name "\"]" {insec=1}
                    insec {print}
                    insec && /^\[/ && $0 != "[remote \"" name "\"]" {exit}
                ' "$remote_cfg" >&2 || true
                exit 1
            fi
            # If neither gpg-verify=true nor an explicit disable is present,
            # Flatpak defaults to verify when GPGKey was imported; require true.
            echo "error: remote $REMOTE_NAME missing gpg-verify=true in $remote_cfg" >&2
            exit 1
        fi
        echo "OK: $REMOTE_NAME gpg-verify=true ($remote_cfg)"
    else
        echo "warning: no flatpak repo config under $FLATPAK_USER_DIR; skip gpg assert" >&2
        echo "remote details: ${gpg_state:-unknown}"
    fi
else
    echo "warning: live Pages .flatpakrepo has no GPGKey=; skip gpg-verify assert" >&2
fi

# Exported launcher id used in GNOME Shell favorite-apps lists.
if [[ ! -f "${FLATPAK_USER_DIR}/exports/share/applications/${APP_ID}.desktop" ]]; then
    found="$(find "${FLATPAK_USER_DIR}" -path "*/exports/share/applications/${APP_ID}.desktop" 2>/dev/null | head -1 || true)"
    if [[ -z "$found" ]]; then
        echo "error: exported desktop file missing for ${APP_ID}" >&2
        exit 1
    fi
fi

# Bake Flathub AppStream into the system tree so GNOME Software curated
# pages (Learn / Editor's Choice / …) are not empty on first open
# (github.com/sirredbeard/azurelinux-desktop/issues/6). Metadata-only
# (~100 MiB: appstream.xml + icons); apps still install over the network.
# Images keep azl-flatpak-appstream.service as a fallback when this tree
# is missing or stripped.
echo "=== Baking Flathub AppStream into ${FLATPAK_USER_DIR} ==="
flatpak update --user --appstream flathub
AS_ACTIVE="${FLATPAK_USER_DIR}/appstream/flathub/x86_64/active"
if [[ ! -e "${AS_ACTIVE}/appstream.xml" && ! -e "${AS_ACTIVE}/appstream.xml.gz" ]]; then
    echo "error: Flathub AppStream missing after update --appstream (${AS_ACTIVE})" >&2
    ls -la "${FLATPAK_USER_DIR}/appstream/flathub/x86_64/" 2>/dev/null || true
    exit 1
fi
if [[ ! -d "${AS_ACTIVE}/icons" ]]; then
    echo "error: Flathub AppStream icons dir missing (${AS_ACTIVE}/icons)" >&2
    exit 1
fi
du -sh "${FLATPAK_USER_DIR}/appstream" 2>/dev/null || true
echo "=== Flathub AppStream OK ==="

echo "=== Copilot Flatpak install OK (${APP_ID}) ==="
