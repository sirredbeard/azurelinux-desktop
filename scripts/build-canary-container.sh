#!/usr/bin/env bash
# build-canary-container.sh
#
# Purpose: Build the package-policy canary with docker (repo-root context).
# Usage:   ./scripts/build-canary-container.sh [tag]
# Needs:   docker; network; optional GITHUB_TOKEN for third-party fetch.
# CI:      Yes. containers.yml owns lifecycle.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-localhost/azurelinux-desktop-canary:latest}"
cd "$ROOT"

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is required to build the canary" >&2
    exit 1
fi

secret_args=()
if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
    export GITHUB_TOKEN="${GITHUB_TOKEN:-$GH_TOKEN}"
    secret_args+=(--secret "id=github_token,env=GITHUB_TOKEN")
fi

export DOCKER_BUILDKIT=1
docker build \
    -f containers/canary/Dockerfile \
    -t "$TAG" \
    "${secret_args[@]}" \
    .

echo "Built $TAG"
docker images "$TAG"
