#!/usr/bin/env bash
# install-dotnet-sdk-tarball.sh
#
# Purpose: Lay out a .NET SDK tarball into a rootfs (/usr/share/dotnet,
#   /usr/bin/dotnet, DOTNET_ROOT). Used at image build and canary time.
# Usage:   ./scripts/install-dotnet-sdk-tarball.sh ROOTFS TARBALL
# Needs:   bash, tar; rootfs writable.
# CI:      Yes. Image %post paths and canary build.

set -euo pipefail

ROOTFS="${1:?rootfs}"
TARBALL="${2:?dotnet sdk tar.gz}"
test -f "$TARBALL"
if [[ "$ROOTFS" != "/" ]]; then
    mkdir -p "$ROOTFS"
fi
test -d "$ROOTFS"

DOTNET_ROOT_REL=usr/share/dotnet
DEST="$ROOTFS/$DOTNET_ROOT_REL"
mkdir -p "$DEST"
# Empty dest of a previous partial extract if re-run.
if [[ -e "$DEST/dotnet" ]]; then
    rm -rf "$DEST"
    mkdir -p "$DEST"
fi
tar -xzf "$TARBALL" -C "$DEST"
test -x "$DEST/dotnet"

mkdir -p "$ROOTFS/usr/bin"
ln -sfn "/$DOTNET_ROOT_REL/dotnet" "$ROOTFS/usr/bin/dotnet"

mkdir -p "$ROOTFS/etc/profile.d"
cat > "$ROOTFS/etc/profile.d/dotnet.sh" << 'PD'
# Microsoft .NET SDK (side-loaded binary archive)
export DOTNET_ROOT=/usr/share/dotnet
# Prefer the side-loaded host over any older distro package on PATH.
case ":$PATH:" in
  *:/usr/share/dotnet:*) ;;
  *) PATH="/usr/share/dotnet:$PATH" ;;
esac
export PATH
PD
chmod 0644 "$ROOTFS/etc/profile.d/dotnet.sh"

# Non-login shells (desktop launchers) still need DOTNET_ROOT.
mkdir -p "$ROOTFS/etc/environment.d" 2>/dev/null || true
if [[ -d "$ROOTFS/etc/environment.d" ]]; then
    printf 'DOTNET_ROOT=/usr/share/dotnet\n' > "$ROOTFS/etc/environment.d/dotnet.conf"
fi

# Record version for support logs when we can run the binary on this host.
ver="unknown"
if [[ "$(uname -m)" = "x86_64" ]] && [[ -x "$DEST/dotnet" ]]; then
    ver="$("$DEST/dotnet" --version 2>/dev/null || true)"
fi
echo "installed .NET SDK tarball -> /$DOTNET_ROOT_REL (version=${ver:-unknown})"
if [[ -n "${ver:-}" && "$ver" != "unknown" ]]; then
    mkdir -p "$ROOTFS/var/log"
    printf 'dotnet-sdk-tarball %s\n' "$ver" >> "$ROOTFS/var/log/azl-desktop-thirdparty-versions.txt" 2>/dev/null || true
fi
