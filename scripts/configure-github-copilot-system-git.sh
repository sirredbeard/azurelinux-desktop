#!/usr/bin/env bash
# configure-github-copilot-system-git.sh
#
# Purpose: After installing the GitHub Copilot GUI RPM (package name
#   "github"), point it at the distro git instead of its Debian-linked
#   bundled github-copilot-git (needs libcurl-gnutls.so.4, which Fedora
#   and Azure Linux do not ship).
# Usage:   ./scripts/configure-github-copilot-system-git.sh [installroot]
# Needs:  installroot already has /usr/bin/github and /usr/bin/git.
# CI:     Called from live kickstart, installer kickstart, canary build.

set -euo pipefail

ROOT="${1:-/}"
ROOT="${ROOT%/}"
[[ -n "$ROOT" ]] || ROOT="/"

if [[ "$ROOT" == "/" ]]; then
    prefix=""
else
    prefix="$ROOT"
fi

if [[ ! -x "$prefix/usr/bin/github" ]]; then
    echo "error: $prefix/usr/bin/github missing - install github RPM first" >&2
    exit 1
fi
if [[ ! -x "$prefix/usr/bin/git" ]]; then
    echo "error: $prefix/usr/bin/git missing - install the git package first" >&2
    exit 1
fi

# Session-wide env (GNOME reads environment.d for graphical sessions).
install -d "$prefix/etc/environment.d"
cat > "$prefix/etc/environment.d/50-azurelinux-desktop-github-copilot.conf" << 'EOF'
# GitHub Copilot GUI embeds a Debian-built git that needs libcurl-gnutls.
# Azure Linux / Fedora provide OpenSSL libcurl only. Use the system git.
LOCAL_GIT_DIRECTORY=/usr
EOF
chmod 0644 "$prefix/etc/environment.d/50-azurelinux-desktop-github-copilot.conf"

# PATH wrapper so terminal and .desktop launches both get the override.
install -d "$prefix/usr/local/bin"
if [[ -f "${BASH_SOURCE[0]%/*}/../assets/bin/azl-github-copilot" ]]; then
    install -m 0755 \
        "${BASH_SOURCE[0]%/*}/../assets/bin/azl-github-copilot" \
        "$prefix/usr/local/bin/azl-github-copilot"
else
    # Fallback when assets are not next to the script (e.g. staged under
    # /root/thirdparty during image builds).
    cat > "$prefix/usr/local/bin/azl-github-copilot" << 'EOF'
#!/bin/sh
set -eu
export LOCAL_GIT_DIRECTORY=/usr
exec /usr/bin/github "$@"
EOF
    chmod 0755 "$prefix/usr/local/bin/azl-github-copilot"
fi

desktop="$prefix/usr/share/applications/GitHub Copilot.desktop"
if [[ -f "$desktop" ]]; then
    # Desktop entries often resolve "github" to /usr/bin/github and skip
    # PATH. Force the wrapper so LOCAL_GIT_DIRECTORY is always set.
    if grep -q '^Exec=' "$desktop"; then
        sed -i 's|^Exec=.*|Exec=/usr/local/bin/azl-github-copilot %u|' "$desktop"
    else
        printf '\nExec=/usr/local/bin/azl-github-copilot %%u\n' >> "$desktop"
    fi
    chmod 0644 "$desktop"
fi

echo "configured GitHub Copilot GUI to use system git (LOCAL_GIT_DIRECTORY=/usr)"
