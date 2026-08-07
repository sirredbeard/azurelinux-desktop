#!/usr/bin/env bash
# ghcr-tag-push.sh
#
# Purpose: Tag a local image as latest + UTC date (+ optional extra tags)
#   and push all of them. Same versioning for canary, build-lorax, build-kiwi, build-kmods.
# Usage:   ./scripts/ghcr-tag-push.sh LOCAL_REF IMAGE_BASE [extra_tag ...]
# Example: ./scripts/ghcr-tag-push.sh localhost/canary:latest \
#            ghcr.io/sirredbeard/azurelinux-desktop/canary f43
# Needs:  podman or docker already logged in to the registry.
# CI:     Yes. containers.yml

set -euo pipefail

LOCAL_REF="${1:?local image ref required}"
IMAGE_BASE="${2:?image base (no tag) required}"
shift 2

# Prefer docker (CI and canary Dockerfile path). Podman only if docker
# is missing and the local ref exists under podman.
if command -v docker >/dev/null 2>&1; then
    CTL=docker
elif command -v podman >/dev/null 2>&1 && podman image exists "$LOCAL_REF" 2>/dev/null; then
    CTL=podman
else
    echo "ghcr-tag-push: need docker (or podman with the local image)" >&2
    exit 1
fi

date_tag="$(date -u +%Y.%m.%d)"
tags=(latest "$date_tag" "$@")

# Dedupe
declare -A seen=()
uniq=()
for t in "${tags[@]}"; do
    [[ -n "$t" ]] || continue
    [[ -n "${seen[$t]:-}" ]] && continue
    seen[$t]=1
    uniq+=("$t")
done

for t in "${uniq[@]}"; do
    echo "tag ${IMAGE_BASE}:${t}"
    $CTL tag "$LOCAL_REF" "${IMAGE_BASE}:${t}"
done
for t in "${uniq[@]}"; do
    echo "push ${IMAGE_BASE}:${t}"
    $CTL push "${IMAGE_BASE}:${t}"
done

echo "ghcr-tag-push: pushed ${IMAGE_BASE} tags=${uniq[*]}"
