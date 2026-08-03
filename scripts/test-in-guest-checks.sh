#!/usr/bin/env bash
# Runs inside the dedicated test image's first boot, as a oneshot systemd
# service with journal+console output so the host-side QEMU wrapper can read
# the results from the serial log. This is intentionally self-contained and
# defensive - if any step fails, print a clear marker and shut the VM down.

set -euo pipefail

STAMP=/var/lib/azl-image-test.done
# shellcheck source=/dev/null
source /usr/local/lib/azl-test-repo-common.sh

log() {
    echo "AZL_TEST: $*"
}

fail() {
    log "FAIL: $*"
    touch "$STAMP"
    echo 'AZL_TEST_RESULT FAIL'
    sync
    systemctl poweroff --no-wall >/dev/null 2>&1 || true
    exit 1
}

pass() {
    log "$*"
    touch "$STAMP"
    echo 'AZL_TEST_RESULT PASS'
    sync
    systemctl poweroff --no-wall >/dev/null 2>&1 || true
    exit 0
}

wait_for_repo_access() {
    local attempt

    for attempt in $(seq 1 30); do
        if dnf -q repolist >/dev/null 2>&1; then
            return 0
        fi
        log "waiting for dnf repo access ($attempt/30)"
        sleep 10
    done

    return 1
}

wait_for_gdm() {
    local attempt

    for attempt in $(seq 1 18); do
        if systemctl is-active gdm.service >/dev/null 2>&1; then
            return 0
        fi
        log "waiting for gdm.service ($attempt/18)"
        sleep 10
    done

    return 1
}

run_dnf_retry() {
    local attempt
    local output
    local rc

    for attempt in $(seq 1 12); do
        if output=$("$@" 2>&1); then
            printf '%s\n' "$output"
            return 0
        fi
        rc=$?
        printf '%s\n' "$output"
        if grep -qiE 'Failed to acquire lock|Waiting for process with pid|another app is currently holding the dnf lock|System is busy' <<< "$output"; then
            log "dnf lock hit on attempt $attempt/12, retrying in 15s"
            sleep 15
            continue
        fi
        return "$rc"
    done

    return 1
}

installed_release() {
    local pkg="$1"
    rpm -q --qf '%{release}\n' "$pkg" 2>/dev/null | awk 'NR==1 { print $1 }'
}

winning_repoid() {
    local pkg="$1"
    dnf repoquery --available --latest-limit=1 --qf '%{repoid}' "$pkg" 2>/dev/null | awk 'NR==1 { print $1 }'
}

check_origin() {
    local pkg="$1"
    local family="$2"
    local release
    local repoid

    release="$(installed_release "$pkg")"
    [ -n "$release" ] || fail "no installed release found for $pkg"
    azl_release_matches_family "$family" "$release" || fail "$pkg has installed release $release, expected $family"

    repoid="$(winning_repoid "$pkg")"
    [ -n "$repoid" ] || fail "no winning repo found for $pkg"
    azl_repo_matches_family "$family" "$repoid" || fail "$pkg currently resolves from $repoid, expected $family"
    log "origin ok: $pkg <- installed release $release, current repo $repoid"
}

select_install_candidate() {
    local family="$1"
    local pkg
    local repoid

    while read -r pkg; do
        [ -n "$pkg" ] || continue
        if rpm -q "$pkg" >/dev/null 2>&1; then
            continue
        fi
        repoid="$(dnf repoquery --available --latest-limit=1 --qf '%{repoid}' "$pkg" 2>/dev/null | awk 'NR==1 { print $1 }')"
        [ -n "$repoid" ] || continue
        if azl_repo_matches_family "$family" "$repoid"; then
            printf '%s\n' "$pkg"
            return 0
        fi
    done < <(azl_install_candidates "$family")

    return 1
}

log 'beginning first-boot guest checks'
wait_for_gdm || fail 'gdm.service never became active'
wait_for_repo_access || fail 'dnf never reached a usable repo state'

log 'running dnf -y --best upgrade with lock retry'
run_dnf_retry dnf -y --best upgrade --refresh || fail 'dnf upgrade failed'

while read -r pkg; do
    [ -n "$pkg" ] || continue
    family="$(azl_repo_expected_family "$pkg")" || fail "no expected repo family defined for $pkg"
    check_origin "$pkg" "$family"
done < <(azl_repo_origin_packages)

azl_pkg="$(select_install_candidate azl)" || fail 'could not find an Azure Linux install candidate'
log "installing Azure Linux candidate: $azl_pkg"
run_dnf_retry dnf -y --best install "$azl_pkg" || fail "dnf install failed for $azl_pkg"
check_origin "$azl_pkg" azl

fedora_pkg="$(select_install_candidate fedora)" || fail 'could not find a Fedora install candidate'
log "installing Fedora candidate: $fedora_pkg"
run_dnf_retry dnf -y --best install "$fedora_pkg" || fail "dnf install failed for $fedora_pkg"
check_origin "$fedora_pkg" fedora

log 'testing Flathub remote/add/install path'
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || fail 'flatpak remote-add flathub failed'
flatpak install -y --noninteractive flathub org.gnome.clocks || fail 'flatpak install org.gnome.clocks failed'
flatpak info --system org.gnome.clocks >/dev/null 2>&1 || fail 'flatpak info org.gnome.clocks failed'

pass 'all guest checks passed'
