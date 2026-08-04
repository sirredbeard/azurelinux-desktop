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

# KIWI/docker often leaves installer-result/ root-owned. Prefer writing
# sidecar files next to the asset; fall back to a temp dir under RUNNER_TEMP
# (or /tmp) so sha256sum/split never need write access to dir.
work="$dir"
if ! touch "$dir/.ci-upload-write-test" 2>/dev/null; then
  work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ci-upload-$$"
  mkdir -p "$work"
  echo "ci-upload-release-asset: $dir not writable; using $work for sidecars"
fi
rm -f "$dir/.ci-upload-write-test" 2>/dev/null || true

sha_out="$work/$base.sha256"
# sha256sum prints "<hash>  <path>"; keep basename-only second field so
# Get-AzureLinuxDesktop.ps1 and local checks stay path-agnostic.
hash=$(sha256sum "$path" | awk '{print $1}')
printf '%s  %s\n' "$hash" "$base" | tee "$sha_out"

# Always split so naming matches Get-AzureLinuxDesktop.ps1 even under 1900M.
split -b 1900M -d -a 2 --additional-suffix=.part "$path" "$work/$base.split."

shopt -s nullglob
parts=("$work/$base".split.*.part)
if [[ ${#parts[@]} -eq 0 ]]; then
  echo "ci-upload-release-asset: split produced no parts" >&2
  exit 1
fi

gh release upload "$tag" "${parts[@]}" "$sha_out" --clobber -R "$repo"
rm -f "${parts[@]}"
# Leave .sha256 next to the source when we could write there; else copy if possible.
if [[ "$work" != "$dir" ]]; then
  cp -f "$sha_out" "$dir/$base.sha256" 2>/dev/null || true
fi
echo "ci-upload-release-asset: uploaded $base (+ sha256, ${#parts[@]} part(s)) to $tag"
