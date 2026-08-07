# Prebuilt Fedora tool image for live ISO + disk image CI.
# Used by build-live-iso.yml via docker run --privileged.
# Rebuild: .github/workflows/containers.yml (weekly / on demand).
# Lint locally with hadolint before push; not run in CI.
FROM fedora:43

# Keep dnf metadata out of the final layers where we can; image is rebuilt
# on a schedule so packages stay current enough for lorax/anaconda.
RUN dnf5 -y upgrade --refresh \
    && dnf5 -y install \
        lorax \
        lorax-templates-generic \
        lorax-lmc-novirt \
        anaconda-core \
        anaconda-install-env-deps \
        anaconda-live \
        squashfs-tools \
        xorriso \
        dosfstools \
        shim-x64 \
        grub2-efi-x64-cdboot \
        policycoreutils \
        curl \
        python3 \
        flatpak \
        qemu-img \
        systemd-udev \
        libguestfs-tools-c \
        util-linux \
        e2fsprogs \
    && dnf5 -y clean all \
    && rm -rf /var/cache/dnf /var/log/dnf* /var/log/hawkey.log

LABEL org.opencontainers.image.title="azurelinux-desktop build-lorax" \
      org.opencontainers.image.description="Fedora lorax/anaconda tool image for Azure Linux Desktop CI" \
      org.opencontainers.image.source="https://github.com/sirredbeard/azurelinux-desktop"
