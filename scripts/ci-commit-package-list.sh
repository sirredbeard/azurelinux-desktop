#!/usr/bin/env bash
# ci-commit-package-list.sh
#
# Purpose: After a successful ISO build, commit refreshed
#   findings/*-package-list.txt back to the branch tip.
# Usage:   CI only; called from build-live-iso.yml / build-installer-iso.yml.
# Needs:   git write permission on contents; clean list files as inputs.
# CI:      Yes.

set -euo pipefail

SRC="${1:?usage: $0 <source-list> <repo-relative-dest> <commit-subject>}"
DEST="${2:?usage: $0 <source-list> <repo-relative-dest> <commit-subject>}"
SUBJECT="${3:?usage: $0 <source-list> <repo-relative-dest> <commit-subject>}"

if [ ! -f "$SRC" ]; then
    echo "error: package list not found: $SRC" >&2
    exit 1
fi

if [ ! -s "$SRC" ]; then
    echo "error: package list is empty: $SRC" >&2
    exit 1
fi

# Normalize CRLF; drop blank lines. Keep the build's sort order.
tmp="$(mktemp)"
# shellcheck disable=SC2064
trap 'rm -f "$tmp"' EXIT
tr -d '\r' <"$SRC" | sed '/^$/d' >"$tmp"

if [ ! -s "$tmp" ]; then
    echo "error: package list empty after normalize: $SRC" >&2
    exit 1
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

branch="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    echo "error: cannot determine branch to push" >&2
    exit 1
fi

body="Auto-updated from the successful ISO build."
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    body="${body}
Run: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi
if [ -n "${GITHUB_SHA:-}" ]; then
    body="${body}
Built from: ${GITHUB_SHA}"
fi

# Live and installer builds can finish close together and both push.
# Reset to the remote tip each attempt, re-apply only this file, commit,
# push. Build outputs live outside git, so a hard reset is safe here.
attempt=1
max_attempts=6
while true; do
    git fetch origin "$branch"
    git rebase --abort 2>/dev/null || true
    git reset --hard "origin/${branch}"

    mkdir -p "$(dirname "$DEST")"
    cp "$tmp" "$DEST"
    git add -- "$DEST"

    if git diff --staged --quiet -- "$DEST"; then
        echo "Package list unchanged: $DEST"
        exit 0
    fi

    git commit -m "$(printf '%s\n\n%s\n' "$SUBJECT" "$body")"

    if git push origin "HEAD:refs/heads/${branch}"; then
        echo "Pushed package list update to ${branch}: $DEST"
        exit 0
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
        echo "error: git push failed after ${max_attempts} attempts" >&2
        exit 1
    fi
    echo "Push rejected (attempt ${attempt}/${max_attempts}); retrying"
    attempt=$((attempt + 1))
    sleep $((attempt))
done
