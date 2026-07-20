#!/usr/bin/env bash
# Build the qcow2 through the same privileged Fedora/Anaconda pipeline as
# build-disk-image in GitHub Actions. This is for local artifact QA.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/local-qcow2-result"
LOG_DIR="$REPO_ROOT/local-qcow2-anaconda"

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

sudo podman pull fedora:44
sudo podman run --rm \
    --privileged \
    -v /dev:/dev \
    --security-opt label=disable \
    -v "$REPO_ROOT:/workspace" \
    --tmpfs /tmp:exec,size=8g \
    fedora:44 \
    bash -exo pipefail -c '
        mount --make-rprivate /
        dnf5 install -y \
            lorax lorax-templates-generic lorax-lmc-novirt \
            anaconda-core anaconda-install-env-deps \
            qemu-img systemd-udev libguestfs-tools-c \
            shim-x64 grub2-efi-x64-cdboot policycoreutils
        python3 /workspace/scripts/patch-anaconda-efi-skip-bug.py
        /usr/lib/systemd/systemd-udevd --daemon
        udevadm trigger
        udevadm settle
        mkdir -p /run/dbus
        dbus-daemon --system --fork
        livemedia-creator \
            --make-disk \
            --no-virt \
            --resultdir /workspace/local-qcow2-result \
            --image-name azurelinux-desktop-live.img \
            --ks /workspace/kickstart/azurelinux-desktop-live-disk.ks \
            --project "Azure Linux Desktop" \
            --releasever 44 \
            --logfile /workspace/local-qcow2-anaconda/livemedia-disk-build.log
        qemu-img convert -O qcow2 -c -o compression_type=zstd \
            /workspace/local-qcow2-result/azurelinux-desktop-live.img \
            /workspace/local-qcow2-result/azurelinux-desktop-live.qcow2
        qemu-img resize /workspace/local-qcow2-result/azurelinux-desktop-live.qcow2 64G
        rm -f /workspace/local-qcow2-result/azurelinux-desktop-live.img
        LIBGUESTFS_BACKEND=direct virt-sparsify --in-place \
            /workspace/local-qcow2-result/azurelinux-desktop-live.qcow2
    '

sudo chown -R "$(id -u):$(id -g)" "$OUTPUT_DIR" "$LOG_DIR"
qemu-img info "$OUTPUT_DIR/azurelinux-desktop-live.qcow2"
