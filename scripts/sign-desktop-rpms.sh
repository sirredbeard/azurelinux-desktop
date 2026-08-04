#!/usr/bin/env bash
# sign-desktop-rpms.sh
#
# Purpose: rpmsign --addsign every .rpm in a directory with the project
#   OpenPGP key (same key as Copilot Flatpak Pages).
# Usage:   ./scripts/sign-desktop-rpms.sh RPM_DIR
# Needs:  rpmsign (rpm-sign), gpg; key via rpm-gpg-import.sh env
# CI:     Yes. publish-desktop-kmods.yml before createrepo_c.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPM_DIR="${1:?usage: $0 RPM_DIR}"

if [[ ! -d "$RPM_DIR" ]]; then
  echo "error: not a directory: $RPM_DIR" >&2
  exit 1
fi
mapfile -t RPMS < <(find "$RPM_DIR" -maxdepth 1 -type f -name '*.rpm' | sort)
if [[ "${#RPMS[@]}" -eq 0 ]]; then
  echo "error: no RPMs in $RPM_DIR" >&2
  exit 1
fi

if ! command -v rpmsign >/dev/null 2>&1; then
  echo "error: rpmsign required (install rpm-sign)" >&2
  exit 1
fi

GPG_HOME="$("${ROOT}/scripts/rpm-gpg-import.sh")"
GPG_KEY_ID="$(cat "${GPG_HOME}/.keyid")"
export GNUPGHOME="$GPG_HOME"

# CI-friendly signing (no pinentry).
cat > "${HOME}/.rpmmacros" <<MACROS
%_signature gpg
%_gpg_path ${GPG_HOME}
%_gpg_name ${GPG_KEY_ID}
%__gpg /usr/bin/gpg
%_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback
MACROS

# Republish merges prior Pages RPMs that may already carry a signature
# (old key or same key). rpmsign --addsign refuses "legacy signature"
# packages. Strip first, then sign with the current project key.
echo "delsign + addsign ${#RPMS[@]} RPM(s) with key $GPG_KEY_ID"
rpmsign --delsign "${RPMS[@]}"
rpmsign --addsign "${RPMS[@]}"

# Import pubkey so --checksig can validate on this host.
PUB_ASC="${ROOT}/packaging/gpg/public.asc"
if [[ ! -s "$PUB_ASC" ]]; then
  mkdir -p "${ROOT}/dist"
  gpg --homedir "$GPG_HOME" --armor --export "$GPG_KEY_ID" > "${ROOT}/dist/RPM-GPG-KEY-azurelinux-desktop"
  PUB_ASC="${ROOT}/dist/RPM-GPG-KEY-azurelinux-desktop"
fi
rpm --import "$PUB_ASC"

fail=0
for rpm in "${RPMS[@]}"; do
  out="$(rpm --checksig "$rpm" 2>&1 || true)"
  echo "$out"
  # rpm 4/6: "digests signatures OK" or similar
  if ! grep -Eiq 'signatures OK|pgp|gpg' <<<"$out"; then
    echo "error: signature verification failed for $rpm" >&2
    fail=1
    continue
  fi
  if grep -Eiq 'NOT OK' <<<"$out"; then
    echo "error: signature NOT OK for $rpm" >&2
    fail=1
    continue
  fi
  echo "OK $(basename "$rpm")"
done
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

mkdir -p "${ROOT}/dist"
gpg --homedir "$GPG_HOME" --armor --export "$GPG_KEY_ID" \
  > "${ROOT}/dist/RPM-GPG-KEY-azurelinux-desktop"

echo "OK: signed ${#RPMS[@]} RPM(s)"
