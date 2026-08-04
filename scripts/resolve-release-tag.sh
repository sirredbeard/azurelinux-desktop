#!/usr/bin/env bash
# resolve-release-tag.sh
#
# Purpose: Pick the GitHub Release tag for uploads. Prefer the latest
#   existing release so focused rebuilds do not mint a new UTC-date tag
#   after midnight UTC. Create a dated tag only when none exists.
# Usage:   bash scripts/resolve-release-tag.sh owner/repo  # prints tag=...
# Needs:   gh auth; network.
# CI:      Yes. release.yml create-release job.

set -euo pipefail

repo="${1:-${GITHUB_REPOSITORY:-}}"
if [ -z "$repo" ]; then
  echo "usage: $0 <owner/repo>" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required" >&2
  exit 1
fi

# Fail closed on API/auth errors. An empty list is the only "create" path.
if ! existing="$(
  gh release list -R "$repo" --limit 1 --json tagName \
    --jq '.[0].tagName // empty'
)"; then
  echo "failed to list releases for $repo" >&2
  exit 1
fi

if [ -n "$existing" ]; then
  printf 'tag=%s\n' "$existing"
  printf 'create=false\n'
  exit 0
fi

printf 'tag=%s\n' "$(date -u +%Y.%m.%d)"
printf 'create=true\n'
