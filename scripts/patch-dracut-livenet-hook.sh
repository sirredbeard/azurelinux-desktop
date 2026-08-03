#!/usr/bin/env bash
# Remove the livenet hook's stray pre-source function call.
set -euo pipefail

if [ "$#" -gt 0 ]; then
    HOOK="$1"
else
    for candidate in \
        /usr/lib/dracut/modules.d/90livenet/parse-livenet.sh \
        /usr/lib/dracut/modules.d/70livenet/parse-livenet.sh; do
        if [ -f "$candidate" ]; then
            HOOK="$candidate"
            break
        fi
    done
fi

if [ -z "${HOOK:-}" ]; then
    echo "error: no livenet dracut hook found" >&2
    exit 1
fi

test -f "$HOOK"
if grep -Fxq 'get_url_handler' "$HOOK"; then
    sed -i '/^get_url_handler$/d' "$HOOK"
    echo "Removed the stray pre-source get_url_handler call from $HOOK"
else
    echo "No stray pre-source get_url_handler call in $HOOK"
fi
! grep -Fxq 'get_url_handler' "$HOOK"
