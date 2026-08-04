#!/usr/bin/env bash
# ci-upload-release-asset.sh - hash, split, and attach one file to a GitHub Release
#
# Purpose:
#   Publish a single build product (ISO, qcow2, or 7z disk image) onto an
#   existing GitHub Release as soon as the build job finishes. Used from
#   build-live-iso.yml and build-installer-iso.yml so assets do not wait
#   for sibling jobs inside a reusable workflow call. Matches the split
#   layout Get-AzureLinuxDesktop.ps1 expects.
#
# Usage:
#   ci-upload-release-asset.sh <tag> <file> [owner/repo]
#
#   tag   - existing release tag (empty tag = no-op success, for dry builds)
#   file  - path to the asset (must exist and be non-empty)
#   repo  - optional; default $GITHUB_REPOSITORY
#
# Behavior:
#   - Writes <file>.sha256 next to the file
#   - Splits into <basename>.split.NN.part chunks of 1900M (under the 2GiB
#     GitHub asset cap)
#   - gh release upload --clobber of parts + sha256
#   - Removes the local .part files after a successful upload (source file
#     and .sha256 stay for the caller)
#
# Requirements:
#   bash, coreutils (sha256sum, split), gh on PATH, GH_TOKEN or GITHUB_TOKEN
#
# CI:
#   Yes - build-live-iso.yml (live ISO, qcow2, vhdx/vdi/vmdk 7z) and
#   build-installer-iso.yml (installer ISO) when release_tag is set.
#
set -euo pipefail

tag="${1:-}"
file="${2:-}"
repo="${3:-${GITHUB_REPOSITORY:-}}"

if [[ -z "$tag" ]]; then
  echo "ci-upload-release-asset: empty tag; skip upload"
  exit 0
fi

if [[ -z "$file" || ! -f "$file" ]]; then
  echo "ci-upload-release-asset: missing file: ${file:-<none>}" >&2
  exit 1
fi

if [[ -z "$repo" ]]; then
  echo "ci-upload-release-asset: set GITHUB_REPOSITORY or pass owner/repo" >&2
  exit 1
fi

if [[ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  echo "ci-upload-release-asset: GH_TOKEN or GITHUB_TOKEN required" >&2
  exit 1
fi
export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"

dir=$(cd "$(dirname -- "$file")" && pwd)
base=$(basename -- "$file")
path="$dir/$base"

echo "ci-upload-release-asset: tag=$tag repo=$repo file=$path"
sha256sum "$path" | tee "$path.sha256"

# Always split so naming matches Get-AzureLinuxDesktop.ps1 even under 1900M.
split -b 1900M -d -a 2 --additional-suffix=.part "$path" "$path.split."

shopt -s nullglob
parts=("$path".split.*.part)
if [[ ${#parts[@]} -eq 0 ]]; then
  echo "ci-upload-release-asset: split produced no parts" >&2
  exit 1
fi

gh release upload "$tag" "${parts[@]}" "$path.sha256" --clobber -R "$repo"
rm -f "${parts[@]}"
echo "ci-upload-release-asset: uploaded $base (+ sha256, ${#parts[@]} part(s)) to $tag"
