#!/usr/bin/env bash
# resolve-release-tag.sh
#
# Purpose: Pick the GitHub Release tag for uploads. Prefer the latest
#   existing product release so focused rebuilds do not mint a new
#   UTC-date tag after midnight UTC. Pre-releases and drafts never
#   count: a dated release candidate created after the product
#   release would otherwise capture every focused rebuild and the
#   daily refresh. Create a dated tag only when none exists.
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
# --limit 100 is far more releases than this repo ever holds at once;
# the filter needs the newest product release even when newer
# candidates sit above it in the list.
if ! existing="$(
  gh release list -R "$repo" --limit 100 --json tagName,isPrerelease,isDraft \
    --jq '[.[] | select(.isPrerelease | not) | select(.isDraft | not)]
          | .[0].tagName // empty'
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
