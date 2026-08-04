#!/usr/bin/env bash
# prestage-copilot-flatpak-system.sh
#
# Purpose: Build a complete /var/lib/flatpak tree for the Microsoft Copilot
#   GTK Flatpak (Platform//50 + app + Pages remote) into DEST_DIR. Used by
#   CI *before* livemedia-creator/kiwi so Anaconda %post only copies the
#   tree. Pulling OSTree inside Anaconda %post --nochroot hung for 90+ min
#   on GHA; the same install finishes in ~30s on the build host/container.
# Usage:   ./scripts/prestage-copilot-flatpak-system.sh DEST_DIR [flathub.flatpakrepo]
# Needs:  flatpak CLI, network, install-copilot-desktop-flatpak.sh beside this
#         script (or SCRIPTS_DIR). DEST_DIR is replaced on each run.
# CI:     Yes. build-live-iso.yml (ISO + disk), build-installer-iso.yml
#         assets pack, local build-qcow2-local.sh.

set -euo pipefail

DEST="${1:?usage: $0 DEST_DIR [flathub.flatpakrepo]}"
FLATHUB_REPO="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_HELPER="${INSTALL_COPILOT_HELPER:-$SCRIPT_DIR/install-copilot-desktop-flatpak.sh}"

if [[ ! -x "$INSTALL_HELPER" ]]; then
    echo "error: install helper missing or not executable: $INSTALL_HELPER" >&2
    exit 1
fi

# Work root holds a fake rootfs; only var/lib/flatpak is published to DEST.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/azl-flatpak-prestage.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK"
echo "=== Prestage Copilot Flatpak system tree → ${DEST} ==="

if [[ -n "$FLATHUB_REPO" && -s "$FLATHUB_REPO" ]]; then
    "$INSTALL_HELPER" "$WORK" "$FLATHUB_REPO"
else
    "$INSTALL_HELPER" "$WORK"
fi

test -f "$WORK/var/lib/flatpak/repo/config"
test -d "$WORK/var/lib/flatpak/app/com.github.sirredbeard.copilot-desktop-gtk"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$WORK/var/lib/flatpak"/. "$DEST"/

test -f "$DEST/repo/config"
test -d "$DEST/app/com.github.sirredbeard.copilot-desktop-gtk"
# Exported desktop id used in GNOME favorites.
test -e "$DEST/exports/share/applications/com.github.sirredbeard.copilot-desktop-gtk.desktop" \
    || find "$DEST" -name 'com.github.sirredbeard.copilot-desktop-gtk.desktop' | grep -q .

du -sh "$DEST" || true
echo "=== Prestage OK (${DEST}) ==="
