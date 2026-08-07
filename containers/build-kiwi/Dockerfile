# Prebuilt Fedora tool image for installer ISO CI (KIWI-NG).
# Used by build-installer-iso.yml via docker run --privileged.
# Rebuild: .github/workflows/containers.yml (weekly / on demand).
# Lint locally with hadolint before push; not run in CI.
FROM fedora:43

RUN dnf5 -y upgrade --refresh \
    && dnf5 -y install \
        python3-kiwi \
        dracut-live \
        squashfs-tools \
        xorriso \
        dosfstools \
        mtools \
        grub2-tools \
        grub2-tools-extra \
        shim-x64 \
        grub2-efi-x64-cdboot \
        createrepo_c \
        curl \
        isomd5sum \
        qemu-img \
        e2fsprogs \
        python3 \
        util-linux \
    && dnf5 -y clean all \
    && rm -rf /var/cache/dnf /var/log/dnf* /var/log/hawkey.log

LABEL org.opencontainers.image.title="azurelinux-desktop build-kiwi" \
      org.opencontainers.image.description="Fedora KIWI-NG tool image for Azure Linux Desktop installer CI" \
      org.opencontainers.image.source="https://github.com/sirredbeard/azurelinux-desktop"
