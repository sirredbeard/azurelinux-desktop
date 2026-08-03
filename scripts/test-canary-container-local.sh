#!/usr/bin/env bash
# Build and exercise the canary package-source canary on the local host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${AZL_CANARY_WORKDIR:-${AZL_HYBRID_CANARY_WORKDIR:-$HOME/azl-work/canary-container}}"
IMAGE_REF="${AZL_CANARY_IMAGE:-${AZL_HYBRID_CANARY_IMAGE:-localhost/azurelinux-desktop-canary:local}}"
LOG_DIR="$WORKDIR/logs"

mkdir -p "$WORKDIR"
podman unshare rm -rf "$LOG_DIR" 2>/dev/null || rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

AZL_CONTAINER_WORKDIR="$WORKDIR/build" \
    "$REPO_ROOT/scripts/build-canary-container.sh" "$IMAGE_REF"

podman run --rm --user root \
    -v "$REPO_ROOT/scripts/test-canary-container.sh:/usr/local/bin/test-canary-container:ro,Z" \
    -v "$LOG_DIR:/logs:Z" \
    "$IMAGE_REF" \
    /usr/local/bin/test-canary-container

echo "Canary logs: $LOG_DIR"
