#!/usr/bin/env bash
# patch-kiwi-dnf5.sh
#
# Purpose: Apply KIWI + DNF5 compatibility fixes inside the Fedora installer
#   build container before kiwi-ng runs.
# Usage:   ./scripts/patch-kiwi-dnf5.sh
# Needs:   Root in the build container with python3-kiwi installed.
# CI:      Yes. build-installer-iso.yml.

set -euo pipefail

KIWI_DNF5=$(python3 -c 'import inspect, kiwi.repository.dnf5; print(inspect.getfile(kiwi.repository.dnf5))')

# Remove kiwi's --disable-plugin=priorities,versionlock dnf argument.
# The argument's layout in dnf5.py changed between kiwi releases: the
# Fedora 43 kiwi had it inline in the argument list, kiwi 11.x puts it
# on its own line. Handle both, then verify the end state instead of
# trusting that a pattern matched.
ARG='--disable-plugin=priorities,versionlock'
if grep -Fq -- "$ARG" "$KIWI_DNF5"; then
    # Own-line layout: drop the line when it holds only the argument.
    sed -i "/^[[:space:]]*'${ARG}',[[:space:]]*$/d" "$KIWI_DNF5"
    # Inline layouts: strip the argument with either comma placement.
    sed -i "s/, *'${ARG}'//g" "$KIWI_DNF5"
    sed -i "s/'${ARG}', *//g" "$KIWI_DNF5"
fi
! grep -Fq -- "$ARG" "$KIWI_DNF5"
python3 -m py_compile "$KIWI_DNF5"
