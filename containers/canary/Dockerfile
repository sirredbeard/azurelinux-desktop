# Azure Linux Desktop package-policy canary.
# Build from repo root (docker only, no nested podman):
#   docker build -f containers/canary/Dockerfile \
#     --secret id=github_token,env=GITHUB_TOKEN \
#     -t localhost/azurelinux-desktop-canary:local .
# Fedora is the build host only. The image rootfs is dnf --installroot
# into an empty tree so azurelinux-release does not fight fedora-release.
# Lifecycle: .github/workflows/containers.yml
# Lint locally with hadolint before push; not run in CI.

FROM fedora:43 AS build

RUN rm -f /etc/yum.repos.d/*.repo
COPY assets/yum.repos.d/azurelinux-desktop.repo /etc/yum.repos.d/azurelinux-desktop.repo
COPY assets/pki/rpm-gpg/ /etc/pki/rpm-gpg/
COPY assets/canary/pkglist.txt /tmp/canary-pkglist.txt
COPY assets /opt/azl-desktop-assets
COPY scripts/fetch-latest-thirdparty.sh \
     scripts/install-dotnet-sdk-tarball.sh \
     scripts/install-copilot-desktop-flatpak.sh \
     scripts/configure-github-copilot-system-git.sh \
     /opt/azl-scripts/

RUN chmod 0755 /opt/azl-scripts/*.sh

# Host needs curl/tar/python for side-load fetch; keys for gpgkey=file://.
RUN set -eux; \
    dnf5 -y install --setopt=install_weak_deps=False curl tar ca-certificates python3 flatpak; \
    for key in \
        RPM-GPG-KEY-azurelinux-4.0-primary \
        RPM-GPG-KEY-azurelinux-desktop \
        RPM-GPG-KEY-fedora-43-primary \
        RPM-GPG-KEY-microsoft \
        RPM-GPG-KEY-githubcli \
        RPM-GPG-KEY-shiftkey-desktop \
        RPM-GPG-KEY-rpmfusion-free-fedora-2020 \
        RPM-GPG-KEY-rpmfusion-nonfree-fedora-2020; do \
        if [ -f "/etc/pki/rpm-gpg/$key" ]; then \
            rpm --import "/etc/pki/rpm-gpg/$key" || true; \
        fi; \
    done; \
    dnf5 -y clean all

ENV ROOTFS=/mnt/rootfs
RUN --mount=type=secret,id=github_token,required=false \
    set -eux; \
    if [ -f /run/secrets/github_token ]; then \
        GITHUB_TOKEN="$(cat /run/secrets/github_token)"; \
        export GITHUB_TOKEN GH_TOKEN="$GITHUB_TOKEN"; \
    fi; \
    mkdir -p "$ROOTFS/etc/yum.repos.d" "$ROOTFS/etc/pki/rpm-gpg"; \
    cp /etc/yum.repos.d/azurelinux-desktop.repo "$ROOTFS/etc/yum.repos.d/"; \
    cp -a /etc/pki/rpm-gpg/. "$ROOTFS/etc/pki/rpm-gpg/"; \
    for key in /etc/pki/rpm-gpg/RPM-GPG-KEY-*; do \
        [ -f "$key" ] || continue; \
        rpm --root="$ROOTFS" --import "$key" 2>/dev/null || true; \
    done; \
    mapfile -t pkgs < <(grep -vE '^(#|$)' /tmp/canary-pkglist.txt); \
    dnf5 -y install --refresh \
        --installroot="$ROOTFS" --releasever=43 \
        --setopt=install_weak_deps=False \
        --setopt=reposdir=/etc/yum.repos.d \
        "${pkgs[@]}"; \
    /opt/azl-scripts/fetch-latest-thirdparty.sh /tmp/thirdparty; \
    dnf5 -y install \
        --installroot="$ROOTFS" --releasever=43 \
        --setopt=install_weak_deps=False \
        --setopt=reposdir=/etc/yum.repos.d \
        /tmp/thirdparty/github-copilot.rpm; \
    test -x "$ROOTFS/usr/bin/git"; \
    /opt/azl-scripts/configure-github-copilot-system-git.sh "$ROOTFS"; \
    install -Dm0755 /opt/azl-desktop-assets/bin/azl-powershell-terminal \
        "$ROOTFS/usr/local/bin/azl-powershell-terminal"; \
    install -Dm0644 /opt/azl-desktop-assets/desktop/org.azurelinux.PowerShell.desktop \
        "$ROOTFS/usr/share/applications/org.azurelinux.PowerShell.desktop"; \
    install -Dm0644 /opt/azl-desktop-assets/icons/powershell.png \
        "$ROOTFS/usr/share/pixmaps/powershell.png"; \
    install -Dm0644 /opt/azl-desktop-assets/wallpapers/adwaita-l.jpg \
        "$ROOTFS/usr/share/backgrounds/azurelinux/adwaita-l.jpg"; \
    install -Dm0644 /opt/azl-desktop-assets/wallpapers/adwaita-d.jpg \
        "$ROOTFS/usr/share/backgrounds/azurelinux/adwaita-d.jpg"; \
    install -Dm0644 /opt/azl-desktop-assets/plymouth/azurelinux/azurelinux.plymouth \
        "$ROOTFS/usr/share/plymouth/themes/azurelinux/azurelinux.plymouth"; \
    install -Dm0644 /opt/azl-desktop-assets/plymouth/azurelinux/azurelinux.script \
        "$ROOTFS/usr/share/plymouth/themes/azurelinux/azurelinux.script"; \
    install -Dm0644 /opt/azl-desktop-assets/plymouth/azurelinux/dot.png \
        "$ROOTFS/usr/share/plymouth/themes/azurelinux/dot.png"; \
    install -Dm0644 /opt/azl-desktop-assets/plymouth/azurelinux/dot-glow.png \
        "$ROOTFS/usr/share/plymouth/themes/azurelinux/dot-glow.png"; \
    install -Dm0644 /opt/azl-desktop-assets/branding/AzureLinuxLogo.png \
        "$ROOTFS/usr/share/plymouth/themes/azurelinux/azurelinuxlogo.png"; \
    install -Dm0644 /opt/azl-desktop-assets/systemd/journald.conf.d/50-azurelinux-desktop.conf \
        "$ROOTFS/etc/systemd/journald.conf.d/50-azurelinux-desktop.conf"; \
    install -Dm0644 /opt/azl-desktop-assets/udev/60-azurelinux-desktop-iosched.rules \
        "$ROOTFS/etc/udev/rules.d/60-azurelinux-desktop-iosched.rules"; \
    install -Dm0644 /opt/azl-desktop-assets/dconf/db/local.d/00-azl-desktop-defaults \
        "$ROOTFS/etc/dconf/db/local.d/00-azl-desktop-defaults"; \
    install -Dm0644 /opt/azl-desktop-assets/dconf/profile/user \
        "$ROOTFS/etc/dconf/profile/user"; \
    chroot "$ROOTFS" dconf update; \
    test -s "$ROOTFS/etc/dconf/db/local"; \
    tar -xzf /tmp/thirdparty/copilot-linux-x64.tar.gz -C "$ROOTFS/usr/local/bin" copilot; \
    chmod 0755 "$ROOTFS/usr/local/bin/copilot"; \
    tar -xzf /tmp/thirdparty/edit.tar.gz -C /tmp; \
    install -m 0755 /tmp/edit "$ROOTFS/usr/local/bin/edit"; \
    rm -f /tmp/edit; \
    if [ -f /tmp/thirdparty/thirdparty-versions.txt ]; then \
        install -Dm0644 /tmp/thirdparty/thirdparty-versions.txt \
            "$ROOTFS/var/log/azl-desktop-thirdparty-versions.txt"; \
    fi; \
    test -x "$ROOTFS/usr/local/bin/copilot"; \
    test -x "$ROOTFS/usr/local/bin/edit"; \
    test -s /tmp/thirdparty/dotnet-sdk-linux-x64.tar.gz; \
    /opt/azl-scripts/install-dotnet-sdk-tarball.sh "$ROOTFS" /tmp/thirdparty/dotnet-sdk-linux-x64.tar.gz; \
    test -x "$ROOTFS/usr/share/dotnet/dotnet"; \
    rpm --root="$ROOTFS" -q gh github-desktop; \
    if [ -s /tmp/thirdparty/flathub.flatpakrepo ]; then \
        /opt/azl-scripts/install-copilot-desktop-flatpak.sh "$ROOTFS" \
            /tmp/thirdparty/flathub.flatpakrepo; \
    else \
        /opt/azl-scripts/install-copilot-desktop-flatpak.sh "$ROOTFS"; \
    fi; \
    test -e "$ROOTFS/var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml" \
        || test -e "$ROOTFS/var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml.gz"; \
    test -d "$ROOTFS/var/lib/flatpak/appstream/flathub/x86_64/active/icons"; \
    if rpm --root="$ROOTFS" -q libva-intel-media-driver >/dev/null 2>&1; then \
        echo "error: libva-intel-media-driver (Fedora free) must not be installed" >&2; \
        exit 1; \
    fi; \
    rpm --root="$ROOTFS" -q intel-media-driver ffmpeg libva \
        gstreamer1-vaapi gstreamer1-plugins-ugly mesa-vulkan-drivers; \
    install -d -m 0755 "$ROOTFS/usr/share/azurelinux-desktop/environment.d"; \
    if [ -f /opt/azl-desktop-assets/environment.d/50-azurelinux-desktop-libva.conf ]; then \
        install -m 0644 /opt/azl-desktop-assets/environment.d/50-azurelinux-desktop-libva.conf \
            "$ROOTFS/usr/share/azurelinux-desktop/environment.d/50-azurelinux-desktop-libva.conf"; \
    fi; \
    if [ -x /opt/azl-desktop-assets/bin/azl-link-intel-ihd ]; then \
        AZL_DESKTOP_ASSETS=/opt/azl-desktop-assets \
            /opt/azl-desktop-assets/bin/azl-link-intel-ihd "$ROOTFS"; \
    fi; \
    if [ -d "$ROOTFS/usr/lib/sysimage/rpm" ]; then \
        chmod 0755 "$ROOTFS/usr/lib/sysimage/rpm" 2>/dev/null || true; \
        chmod a+r "$ROOTFS/usr/lib/sysimage/rpm/rpmdb.sqlite" \
            "$ROOTFS/usr/lib/sysimage/rpm/rpmdb.sqlite-shm" \
            "$ROOTFS/usr/lib/sysimage/rpm/rpmdb.sqlite-wal" 2>/dev/null || true; \
    fi; \
    install -d -m 0755 "$ROOTFS/usr/share/azurelinux-desktop/gpg"; \
    if [ -f /opt/azl-desktop-assets/gpg/signing-key.asc ]; then \
        install -m 0644 /opt/azl-desktop-assets/gpg/signing-key.asc \
            "$ROOTFS/usr/share/azurelinux-desktop/gpg/signing-key.asc"; \
    elif [ -f "$ROOTFS/etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop" ]; then \
        install -m 0644 "$ROOTFS/etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop" \
            "$ROOTFS/usr/share/azurelinux-desktop/gpg/signing-key.asc"; \
    fi; \
    rm -rf "$ROOTFS/var/cache"/* /tmp/thirdparty \
        "$ROOTFS/usr/share/doc"/* "$ROOTFS/usr/share/man"/*; \
    find "$ROOTFS/var/log" -mindepth 1 -maxdepth 1 \
        ! -name azl-desktop-thirdparty-versions.txt -exec rm -rf {} + 2>/dev/null || true; \
    # Ensure a shell exists for CMD
    test -x "$ROOTFS/bin/bash" || test -x "$ROOTFS/usr/bin/bash"

FROM scratch
COPY --from=build /mnt/rootfs /
WORKDIR /
CMD ["/bin/bash"]
LABEL org.opencontainers.image.title="azurelinux-desktop-canary" \
      org.opencontainers.image.description="Package-policy canary for Azure Linux Desktop" \
      org.opencontainers.image.source="https://github.com/sirredbeard/azurelinux-desktop"
