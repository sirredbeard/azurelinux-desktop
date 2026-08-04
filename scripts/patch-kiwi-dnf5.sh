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

grep -Fq -- '--disable-plugin=priorities,versionlock' "$KIWI_DNF5"
sed -i "s/, '--disable-plugin=priorities,versionlock'//" "$KIWI_DNF5"
! grep -Fq -- '--disable-plugin=priorities,versionlock' "$KIWI_DNF5"
