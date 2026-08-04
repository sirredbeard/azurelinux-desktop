#!/usr/bin/env bash
# rpm-gpg-import.sh - prepare a GPG homedir for desktop kmod RPM signing.
#
# Usage:
#   ./scripts/rpm-gpg-import.sh [--generate]
# Env:
#   FLATPAK_GPG_PRIVATE_KEY       armored private key (CI secret; shared name)
#   FLATPAK_GPG_PRIVATE_KEY_FILE  path to armored private key
#   FLATPAK_GPG_HOME              existing gnupg home to reuse
#   RPM_GPG_* aliases accepted as fallbacks
# Writes path to GPG home on stdout (last line). Stores key id in $HOME/.keyid.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUB_DIR="$ROOT/packaging/rpm-gpg"
GENERATE=0
[[ "${1:-}" == "--generate" ]] && GENERATE=1

PRIVATE_KEY="${FLATPAK_GPG_PRIVATE_KEY:-${RPM_GPG_PRIVATE_KEY:-}}"
PRIVATE_FILE="${FLATPAK_GPG_PRIVATE_KEY_FILE:-${RPM_GPG_PRIVATE_KEY_FILE:-}}"
HOME_IN="${FLATPAK_GPG_HOME:-${RPM_GPG_HOME:-}}"

if [[ -n "$HOME_IN" && -d "$HOME_IN" ]]; then
  HOME_GPG="$HOME_IN"
else
  HOME_GPG="$(mktemp -d "${TMPDIR:-/tmp}/azl-rpm-gpg.XXXXXX")"
  chmod 700 "$HOME_GPG"
  if [[ -n "$PRIVATE_KEY" ]]; then
    printf '%s\n' "$PRIVATE_KEY" | gpg --homedir "$HOME_GPG" --batch --import
  elif [[ -f "$PRIVATE_FILE" ]]; then
    gpg --homedir "$HOME_GPG" --batch --import "$PRIVATE_FILE"
  elif [[ "$GENERATE" -eq 1 ]]; then
    batch="$(mktemp)"
    cat > "$batch" <<'BATCH'
%echo Generating azurelinux-desktop RPM signing key
Key-Type: RSA
Key-Length: 4096
Name-Real: azurelinux-desktop
Name-Email: rpm-signing@sirredbeard.github.io
Expire-Date: 0
%no-protection
%commit
BATCH
    gpg --homedir "$HOME_GPG" --batch --generate-key "$batch"
    rm -f "$batch"
    KEYID=$(gpg --homedir "$HOME_GPG" --list-keys --with-colons | awk -F: '/^pub/ {print $5; exit}')
    mkdir -p "$PUB_DIR"
    echo "$KEYID" > "$PUB_DIR/keyid.txt"
    gpg --homedir "$HOME_GPG" --armor --export "$KEYID" > "$PUB_DIR/public.asc"
  else
    echo "error: set FLATPAK_GPG_PRIVATE_KEY (or RPM_GPG_*), FILE, HOME, or --generate" >&2
    exit 1
  fi
fi

KEYID=$(gpg --homedir "$HOME_GPG" --list-keys --with-colons | awk -F: '/^pub/ {print $5; exit}')
if [[ -z "$KEYID" ]]; then
  echo "error: no public key in $HOME_GPG" >&2
  exit 1
fi
if [[ -f "$PUB_DIR/keyid.txt" ]]; then
  want=$(tr -d ' \n' < "$PUB_DIR/keyid.txt")
  if gpg --homedir "$HOME_GPG" --list-secret-keys --with-colons | grep -q "$want"; then
    KEYID="$want"
  fi
fi
echo "$KEYID" > "${HOME_GPG}/.keyid"
echo "rpm gpg ready key=$KEYID home=$HOME_GPG" >&2
echo "$HOME_GPG"
