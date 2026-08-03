#!/usr/bin/env bash
# Run fast non-GUI preflight checks in short, visible steps with per-step logs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ROOT="${1:-$HOME/azl-work/preflight-split-$(date -u +%Y%m%d-%H%M%S)}"
shift || true

REQUESTED_STEPS=("$@")

case "$RUN_ROOT" in
    "$HOME"/azl-work/*) ;;
    *)
        echo "run directory must be under $HOME/azl-work" >&2
        exit 1
        ;;
esac

mkdir -p "$RUN_ROOT"
LOG_DIR="$RUN_ROOT/logs"
mkdir -p "$LOG_DIR"

fail=0
selected_step() {
    local needle="$1"
    if [ "${#REQUESTED_STEPS[@]}" -eq 0 ]; then
        return 0
    fi
    local step
    for step in "${REQUESTED_STEPS[@]}"; do
        if [ "$step" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

run_step() {
    local name="$1"
    shift
    local log="$LOG_DIR/$name.log"
    local start
    start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "=== START $name ($start) ==="
    if "$@" >"$log" 2>&1; then
        local end
        end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "=== PASS  $name ($end) ==="
    else
        local rc=$?
        local end
        end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "=== FAIL  $name rc=$rc ($end) ==="
        fail=1
    fi
    echo "--- tail: $name ---"
    tail -n 25 "$log" | cat
}

runtime_resolve_dir="$RUN_ROOT/installer-runtime-resolve"

if selected_step "test-container-repos"; then
    run_step "test-container-repos" \
        timeout 1200 "$REPO_ROOT/scripts/test-container-repos.sh"
fi

if selected_step "podman-test-azl4-fedora"; then
    run_step "podman-test-azl4-fedora" \
        timeout 1200 "$REPO_ROOT/scripts/podman-test-azl4-fedora.sh"
fi

if selected_step "test-installer-runtime-resolve"; then
    run_step "test-installer-runtime-resolve" \
        timeout 1200 "$REPO_ROOT/scripts/test-installer-runtime-resolve.sh" "$runtime_resolve_dir"
fi

if selected_step "test-canary-container-local"; then
    run_step "test-canary-container-local" \
        timeout 1500 "$REPO_ROOT/scripts/test-canary-container-local.sh"
fi

if [ "${#REQUESTED_STEPS[@]}" -gt 0 ]; then
    for step in "${REQUESTED_STEPS[@]}"; do
        case "$step" in
            test-container-repos|podman-test-azl4-fedora|test-installer-runtime-resolve|test-canary-container-local)
                ;;
            *)
                echo "unknown step: $step" >&2
                exit 1
                ;;
        esac
    done
fi

echo
echo "Preflight logs: $LOG_DIR"
if [ "$fail" -ne 0 ]; then
    echo "Preflight summary: FAIL"
    exit 1
fi
echo "Preflight summary: PASS"
