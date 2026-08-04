#!/usr/bin/env bash
# build-qcow2-local.sh
#
# Purpose: Build a live-disk qcow2 on a local host (not Actions). Generates
#   the disk kickstart from kickstart/azurelinux-desktop-live.ks.
# Usage:   ./scripts/build-qcow2-local.sh
# Needs:   podman/docker, lorax/livemedia-creator stack, lots of disk.
# CI:      No. Local preflight for disk-image path.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
OUTPUT_DIR="$WORKDIR/local-qcow2-result"
LOG_DIR="$WORKDIR/local-qcow2-anaconda"

command -v podman >/dev/null || {
    echo "podman is required to build the qcow2 locally" >&2
    exit 1
}

sudo modprobe xfs
sudo rm -rf "$OUTPUT_DIR" "$LOG_DIR"
cd "$REPO_ROOT"

python3 - "$REPO_ROOT/.github/workflows/build-live-iso.yml" <<'PY' | bash -e
import sys
import yaml

with open(sys.argv[1]) as workflow:
    for step in yaml.safe_load(workflow)["jobs"]["build-disk-image"]["steps"]:
        if step.get("name") == "Build disk-image kickstart variant":
            print(step["run"])
            break
    else:
        raise SystemExit("Disk-image kickstart generation step not found")
PY

sudo mkdir -p "$OUTPUT_DIR" "$LOG_DIR"
sudo podman pull fedora:43
sudo podman run --rm \
    --privileged \
    --cgroups=disabled \
    -v /dev:/dev \
    --security-opt label=disable \
    -v "$REPO_ROOT:/workspace" \
    -v "$OUTPUT_DIR:/output" \
    -v "$LOG_DIR:/logs" \
    --tmpfs /tmp:exec,size=8g \
    fedora:43 \
    bash -exo pipefail -c '
        mount --make-rprivate /
        dnf5 install -y \
            lorax lorax-templates-generic lorax-lmc-novirt \
            anaconda-core anaconda-install-env-deps \
            qemu-img systemd-udev libguestfs-tools-c \
            shim-x64 grub2-efi-x64-cdboot policycoreutils \
            curl python3 flatpak
        python3 /workspace/scripts/patch-anaconda-efi-skip-bug.py
        python3 /workspace/scripts/configure-anaconda-efi-vendor.py
        /usr/lib/systemd/systemd-udevd --daemon
        udevadm trigger
        udevadm settle
        mkdir -p /run/dbus
        dbus-daemon --system --fork
        livemedia-creator \
            --make-disk \
            --no-virt \
            --resultdir /output \
            --image-name azurelinux-desktop-live.img \
            --ks /workspace/kickstart/azurelinux-desktop-live-disk.ks \
            --project "Azure Linux Desktop" \
            --releasever 43 \
            --logfile /logs/livemedia-disk-build.log
        LIBGUESTFS_BACKEND=direct virt-sparsify --in-place \
            /output/azurelinux-desktop-live.img
        qemu-img convert -O qcow2 -c -o compression_type=zstd \
            /output/azurelinux-desktop-live.img \
            /output/azurelinux-desktop-live.qcow2
        qemu-img resize /output/azurelinux-desktop-live.qcow2 64G
        rm -f /output/azurelinux-desktop-live.img
    '

sudo chown -R "$(id -u):$(id -g)" "$OUTPUT_DIR" "$LOG_DIR"
qemu-img info "$OUTPUT_DIR/azurelinux-desktop-live.qcow2"
