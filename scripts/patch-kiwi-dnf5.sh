#!/usr/bin/env bash
# KIWI's dnf5 backend disables legacy plugins that current libdnf5 no longer
# ships. DNF treats unknown disabled plugin names as a transaction failure.
set -euo pipefail

KIWI_DNF5=$(python3 -c 'import inspect, kiwi.repository.dnf5; print(inspect.getfile(kiwi.repository.dnf5))')

grep -Fq -- '--disable-plugin=priorities,versionlock' "$KIWI_DNF5"
sed -i "s/, '--disable-plugin=priorities,versionlock'//" "$KIWI_DNF5"
! grep -Fq -- '--disable-plugin=priorities,versionlock' "$KIWI_DNF5"
