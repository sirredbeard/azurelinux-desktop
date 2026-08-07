#!/usr/bin/env bash
# test-canary-container-local.sh
#
# Purpose: Thin local wrapper to build/test the canary image without GHCR push.
# Usage:   ./scripts/test-canary-container-local.sh
# Needs:   docker; build-canary-container.sh; test-canary-container.sh.
# CI:      No. Local twin of the containers.yml canary jobs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${AZL_CANARY_WORKDIR:-${AZL_HYBRID_CANARY_WORKDIR:-$HOME/azl-work/canary-container}}"
IMAGE_REF="${AZL_CANARY_IMAGE:-${AZL_HYBRID_CANARY_IMAGE:-localhost/azurelinux-desktop-canary:local}}"
LOG_DIR="$WORKDIR/logs"

mkdir -p "$WORKDIR"
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

"$REPO_ROOT/scripts/build-canary-container.sh" "$IMAGE_REF"

docker run --rm --user root \
    -v "$REPO_ROOT/scripts/test-canary-container.sh:/usr/local/bin/test-canary-container:ro" \
    -v "$LOG_DIR:/logs" \
    "$IMAGE_REF" \
    /usr/local/bin/test-canary-container

echo "Canary local test finished. Logs: $LOG_DIR"
