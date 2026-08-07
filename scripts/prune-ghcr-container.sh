#!/usr/bin/env bash
# prune-ghcr-container.sh
#
# Purpose: Keep only the newest N tagged GHCR container versions and drop
#   untagged leftovers. One script for canary, build-lorax, build-kiwi,
#   build-kmods (and any later GHCR package).
# Usage:
#   ./scripts/prune-ghcr-container.sh [PACKAGE] [KEEP_TAGGED]
#   GHCR_PACKAGE=azurelinux-desktop/canary ./scripts/prune-ghcr-container.sh [KEEP]
# Examples:
#   ./scripts/prune-ghcr-container.sh azurelinux-desktop/canary 2
#   ./scripts/prune-ghcr-container.sh azurelinux-desktop/build-lorax 2
# Needs: gh auth with packages read/delete (packages:write in CI).
# CI:    containers.yml after each image push.
#
# Env:
#   GHCR_OWNER   (default: sirredbeard)
#   GHCR_PACKAGE (default: azurelinux-desktop/canary; overridden by PACKAGE arg)
#
# Keep policy (default KEEP=2): newest KEEP tagged versions. Untagged
# versions are always deleted. :latest is just a tag on a version.

set -euo pipefail

OWNER="${GHCR_OWNER:-sirredbeard}"
KEEP=2
PACKAGE_RAW="${GHCR_PACKAGE:-azurelinux-desktop/canary}"

# Args: optional PACKAGE (contains / or starts with azurelinux-desktop), optional KEEP
for arg in "$@"; do
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
        KEEP="$arg"
    else
        PACKAGE_RAW="$arg"
    fi
done

PACKAGE_ENC="${PACKAGE_RAW//\//%2F}"

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || ((KEEP < 1)); then
    echo "usage: $0 [PACKAGE] [KEEP_TAGGED>=1]" >&2
    echo "   or: GHCR_PACKAGE=ns/name $0 [KEEP]" >&2
    exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "prune-ghcr-container: gh CLI required" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "prune-ghcr-container: jq required" >&2
    exit 1
fi

api_list() {
    local page=1
    local chunk
    while true; do
        chunk=$(gh api \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "/users/${OWNER}/packages/container/${PACKAGE_ENC}/versions?per_page=100&page=${page}" \
            2>/dev/null || true)
        if [[ -z "$chunk" || "$chunk" == "[]" ]]; then
            break
        fi
        if echo "$chunk" | jq -e 'type == "object" and has("message")' >/dev/null 2>&1; then
            echo "prune-ghcr-container: list failed: $(echo "$chunk" | jq -r .message)" >&2
            exit 1
        fi
        echo "$chunk"
        local n
        n=$(echo "$chunk" | jq 'length')
        ((n < 100)) && break
        page=$((page + 1))
    done | jq -s 'add // []'
}

echo "=== GHCR prune: ${OWNER}/${PACKAGE_RAW} keep_tagged=${KEEP} ==="

ALL=$(api_list)
TOTAL=$(echo "$ALL" | jq 'length')
echo "versions listed: ${TOTAL}"

if ((TOTAL == 0)); then
    echo "nothing to prune"
    exit 0
fi

TAGGED_IDS=$(echo "$ALL" | jq -c \
    '[.[] | select((.metadata.container.tags // []) | length > 0)]
     | sort_by(.created_at) | reverse | .[].id')
UNTAGGED_IDS=$(echo "$ALL" | jq -c \
    '[.[] | select((.metadata.container.tags // []) | length == 0)]
     | .[].id')

mapfile -t TAGGED_ARR < <(echo "$TAGGED_IDS" | sed '/^$/d')
mapfile -t UNTAGGED_ARR < <(echo "$UNTAGGED_IDS" | sed '/^$/d')

echo "tagged=${#TAGGED_ARR[@]} untagged=${#UNTAGGED_ARR[@]}"

DELETE_IDS=()
i=0
for id in "${TAGGED_ARR[@]+"${TAGGED_ARR[@]}"}"; do
    if ((i < KEEP)); then
        tags=$(echo "$ALL" | jq -r --argjson id "$id" \
            '.[] | select(.id == $id) | (.metadata.container.tags // []) | join(",")')
        echo "keep tagged id=${id} tags=${tags}"
    else
        DELETE_IDS+=("$id")
    fi
    i=$((i + 1))
done

for id in "${UNTAGGED_ARR[@]+"${UNTAGGED_ARR[@]}"}"; do
    DELETE_IDS+=("$id")
done

if ((${#DELETE_IDS[@]} == 0)); then
    echo "nothing to delete"
    exit 0
fi

echo "deleting ${#DELETE_IDS[@]} version(s)"
fail=0
for id in "${DELETE_IDS[@]}"; do
    tags=$(echo "$ALL" | jq -r --argjson id "$id" \
        '.[] | select(.id == $id) | ((.metadata.container.tags // []) | join(",")) // ""')
    echo "  delete id=${id} tags=${tags:-"(untagged)"}"
    if gh api --method DELETE \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "/users/${OWNER}/packages/container/${PACKAGE_ENC}/versions/${id}"; then
        :
    else
        echo "  WARN: delete failed for id=${id}" >&2
        fail=1
    fi
done

if ((fail != 0)); then
    echo "prune-ghcr-container: some deletes failed (token scope or package perms?)" >&2
    exit 1
fi

echo "=== GHCR prune done ==="
