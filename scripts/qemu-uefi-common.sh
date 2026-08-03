#!/usr/bin/env bash
# Shared UEFI/OVMF helpers for the headless QEMU test scripts. Sourced by
# the scripts that need real OVMF firmware and a scratch VARS file.

azl_find_ovmf() {
    local candidate_dir
    local code_name
    local vars_name

    # Fedora/RHEL's edk2-ovmf package ships plain OVMF_CODE.fd/OVMF_VARS.fd.
    # Ubuntu/Debian's ovmf package (what the GitHub-hosted ubuntu-24.04
    # runners this project's CI uses actually installs) ships the same
    # firmware under OVMF_CODE_4M.fd/OVMF_VARS_4M.fd instead - both name
    # pairs get checked in every candidate directory so this works
    # unmodified on both the dev machine and CI.
    for candidate_dir in /usr/share/edk2/ovmf /usr/share/OVMF /usr/share/qemu/firmware; do
        for code_name in OVMF_CODE.fd OVMF_CODE_4M.fd; do
            vars_name="${code_name/CODE/VARS}"
            if [ -f "$candidate_dir/$code_name" ] && [ -f "$candidate_dir/$vars_name" ]; then
                # shellcheck disable=SC2034
                AZL_OVMF_CODE="$candidate_dir/$code_name"
                # shellcheck disable=SC2034
                AZL_OVMF_VARS_SRC="$candidate_dir/$vars_name"
                return 0
            fi
        done
    done

    echo "ERROR: could not find OVMF_CODE(.fd|_4M.fd)/OVMF_VARS(.fd|_4M.fd)." >&2
    echo "Install it first, e.g.: sudo dnf install edk2-ovmf (Fedora/RHEL)" >&2
    echo "or: sudo apt-get install ovmf (Ubuntu/Debian)" >&2
    return 1
}

azl_prepare_ovmf_vars() {
    local workdir="$1"
    local tag="$2"
    local vars_copy

    # Callers must call azl_find_ovmf themselves, in their own shell,
    # before calling this function - NOT rely on this function to call it
    # for them. Every caller captures this function's *output* via command
    # substitution (OVMF_VARS="$(azl_prepare_ovmf_vars ...)"), which runs
    # in a subshell; any variables azl_find_ovmf set would only exist in
    # that subshell and vanish the moment it exits, leaving the caller's
    # own $AZL_OVMF_CODE unset ("unbound variable" under set -u) even
    # though detection had actually succeeded. This bit in real CI before
    # being caught by an actual dispatched run, not code review.
    if [ -z "${AZL_OVMF_VARS_SRC:-}" ]; then
        echo "ERROR: AZL_OVMF_VARS_SRC not set - call azl_find_ovmf before azl_prepare_ovmf_vars." >&2
        return 1
    fi
    mkdir -p "$workdir"

    vars_copy="$workdir/${tag}.ovmf-vars.fd"
    cp -f "$AZL_OVMF_VARS_SRC" "$vars_copy"
    printf '%s\n' "$vars_copy"
}

azl_qemu_safe_name() {
    basename "$1" | tr -c 'A-Za-z0-9._-' '_'
}

azl_qemu_monitor_socket() {
    local workdir="$1"
    local name="$2"
    local runtime_dir
    local socket_id

    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if [ -d "$runtime_dir" ] && [ -w "$runtime_dir" ]; then
        mkdir -p "$runtime_dir/azl-qemu"
        socket_id="$(printf '%s' "$name" | sha256sum | cut -c1-16)"
        printf '%s\n' "$runtime_dir/azl-qemu/${socket_id}.mon"
        return 0
    fi

    printf '%s\n' "$workdir/$(azl_qemu_safe_name "$name").mon"
}

azl_qemu_is_iso() {
    case "$1" in
        *.iso|*.ISO) return 0 ;;
        *) return 1 ;;
    esac
}

# Emits the right -accel/-cpu pair as newline-separated QEMU args: KVM+host
# passthrough when /dev/kvm exists and is actually usable (real dev
# hardware, self-hosted runners with nested virt), TCG software emulation
# otherwise. Callers should
# read this into an array with mapfile/readarray, not word-split it, in
# case a future accel needs an argument containing a space.
azl_qemu_accel_args() {
    if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        printf '%s\n' "-accel" "kvm" "-cpu" "host"
    else
        printf '%s\n' "-accel" "tcg,thread=multi" "-cpu" "max"
    fi
}
