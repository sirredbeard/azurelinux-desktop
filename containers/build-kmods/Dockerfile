# Prebuilt Azure Linux 4 tool image for desktop kmod CI.
# Used by publish-desktop-kmods.yml instead of bare
# mcr.microsoft.com/azurelinux-beta/base/core:4.0 + per-job dnf of the
# compiler stack. kernel-devel still installs at build time for the
# exact target kernel EVR (that package moves with upstream).
#
# Rebuild: .github/workflows/containers.yml (weekly / on demand).
# Lint locally with hadolint before push; not run in CI.
FROM mcr.microsoft.com/azurelinux-beta/base/core:4.0

ARG AZL_BASE_URL=https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64

RUN dnf5 -y install \
        --setopt=reposdir=/dev/null \
        --setopt=azl-base.gpgcheck=0 \
        --repofrompath=azl-base,"${AZL_BASE_URL}" \
        --repo=azl-base \
        bc \
        gcc \
        make \
        perl \
        python3 \
        openssl-devel \
        elfutils-devel \
        elfutils-libelf-devel \
        rpm-build \
        rpm-sign \
        gnupg2 \
        kmod \
        git \
        curl \
        gawk \
        tar \
        gzip \
        findutils \
        which \
        createrepo_c \
        ca-certificates \
    && dnf5 -y clean all \
    && rm -rf /var/cache/dnf /var/cache/tdnf /var/log/dnf*

LABEL org.opencontainers.image.title="azurelinux-desktop build-kmods" \
      org.opencontainers.image.description="Azure Linux 4 kmod toolchain for Azure Linux Desktop CI" \
      org.opencontainers.image.source="https://github.com/sirredbeard/azurelinux-desktop"
