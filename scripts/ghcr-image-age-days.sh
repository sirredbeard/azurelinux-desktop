#!/usr/bin/env bash
# ghcr-image-age-days.sh
#
# Purpose: Print whole days since the GHCR package version tagged
#   TAG (default: latest) was created. Exit 0 always when the package
#   exists; print "missing" and exit 0 if there is no such tag so callers
#   can treat missing as "rebuild required".
# Usage:   GHCR_PACKAGE=azurelinux-desktop/build-lorax ./scripts/ghcr-image-age-days.sh [TAG]
# Needs:  gh, jq. packages:read token in CI.
# CI:     Yes. containers.yml plan job.

set -euo pipefail

TAG="${1:-latest}"
OWNER="${GHCR_OWNER:-sirredbeard}"
PACKAGE_RAW="${GHCR_PACKAGE:?GHCR_PACKAGE required}"
PACKAGE_ENC="${PACKAGE_RAW//\//%2F}"

if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "ghcr-image-age-days: gh and jq required" >&2
    exit 1
fi

# Scan a few pages for the version that carries TAG.
page=1
created=""
while ((page <= 10)); do
    chunk=$(gh api \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "/users/${OWNER}/packages/container/${PACKAGE_ENC}/versions?per_page=100&page=${page}" \
        2>/dev/null || true)
    if [[ -z "$chunk" || "$chunk" == "[]" ]]; then
        break
    fi
    if echo "$chunk" | jq -e 'type == "object" and has("message")' >/dev/null 2>&1; then
        # Package missing or no access.
        msg=$(echo "$chunk" | jq -r .message)
        if [[ "$msg" == *"Not Found"* || "$msg" == *"404"* ]]; then
            echo "missing"
            exit 0
        fi
        echo "ghcr-image-age-days: list failed: $msg" >&2
        exit 1
    fi
    created=$(echo "$chunk" | jq -r --arg tag "$TAG" '
        [.[] | select((.metadata.container.tags // []) | index($tag))]
        | sort_by(.updated_at) | reverse | .[0].updated_at // empty')
    if [[ -n "$created" ]]; then
        break
    fi
    n=$(echo "$chunk" | jq 'length')
    ((n < 100)) && break
    page=$((page + 1))
done

if [[ -z "$created" ]]; then
    echo "missing"
    exit 0
fi

# Portable day age (UTC). Prefer GNU date; fall back to python.
if date -u -d "$created" +%s >/dev/null 2>&1; then
    then_s=$(date -u -d "$created" +%s)
    now_s=$(date -u +%s)
elif date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${created%.*}Z" +%s >/dev/null 2>&1; then
    then_s=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${created%.*}Z" +%s)
    now_s=$(date -u +%s)
else
    then_s=$(python3 -c "from datetime import datetime,timezone; print(int(datetime.fromisoformat('${created}'.replace('Z','+00:00')).timestamp()))")
    now_s=$(python3 -c "from datetime import datetime,timezone; print(int(datetime.now(timezone.utc).timestamp()))")
fi

age_days=$(( (now_s - then_s) / 86400 ))
if ((age_days < 0)); then
    age_days=0
fi
echo "$age_days"
