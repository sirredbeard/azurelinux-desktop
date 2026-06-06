# ── Stage 1: build pipewire-module-xrdp (audio over the RDP connection) ──
# Fedora does not package the xrdp sink module; it must be compiled against
# the same PipeWire the image runs.
FROM mcr.microsoft.com/azurelinux-beta/base/core:4.0 AS audio-builder

RUN rpm --import https://src.fedoraproject.org/rpms/fedora-repos/raw/rawhide/f/RPM-GPG-KEY-fedora-43-primary
COPY fedora43.repo /etc/yum.repos.d/fedora43.repo

RUN dnf5 install -y gcc make autoconf automake libtool git pkg-config gawk diffutils which pipewire-devel \
    && dnf5 clean all
RUN git clone --depth 1 https://github.com/neutrinolabs/pipewire-module-xrdp.git /src \
    && cd /src \
    && ./bootstrap \
    && ./configure --prefix=/usr \
         --with-module-dir=/usr/lib64/pipewire-0.3 \
         --with-xdgautostart-dir=/etc/xdg/autostart \
    && make \
    && make install DESTDIR=/staged

# ── Stage 2: the desktop image ───────────────────────────────────────────
FROM mcr.microsoft.com/azurelinux-beta/base/core:4.0

RUN rpm --import https://src.fedoraproject.org/rpms/fedora-repos/raw/rawhide/f/RPM-GPG-KEY-fedora-43-primary \
    && rpm --import https://packages.microsoft.com/keys/microsoft.asc
COPY fedora43.repo /etc/yum.repos.d/fedora43.repo
COPY vscode.repo /etc/yum.repos.d/vscode.repo

RUN dnf5 install -y \
      xrdp tigervnc-server-minimal xorg-x11-xinit fuse3 util-linux \
      xfce4-session xfwm4 xfce4-panel xfce4-settings xfce4-terminal \
      xfdesktop adwaita-icon-theme elementary-xfce-icon-theme epiphany xfce4-pulseaudio-plugin \
      xfce4-appfinder pipewire-utils pulseaudio-utils \
      libxfce4ui libxfce4util xfconf exo garcon thunar \
      dbus-x11 xkeyboard-config xorg-x11-fonts-misc default-fonts \
      pam shadow-utils passwd procps-ng sudo openssl tzdata \
      librsvg2-tools curl tar gzip icu \
      code \
    && dnf5 clean all

# xfce-polkit autostarts and immediately errors (no polkit daemon in the
# container); drop it from the session.
RUN rm -f /etc/xdg/autostart/xfce-polkit.desktop

# Electron apps cannot use the setuid sandbox inside the container; launch
# VS Code with --no-sandbox everywhere its desktop file invokes it.
RUN sed -i 's|/usr/share/code/code|/usr/share/code/code --no-sandbox|g' /usr/share/applications/code.desktop

# PowerShell ships no aarch64 RPM, so unpack the official tarball for the
# build architecture and make it the default xfce4-terminal shell.
RUN case "$(uname -m)" in \
      aarch64) ps_arch=arm64 ;; \
      x86_64)  ps_arch=x64 ;; \
      *) echo "unsupported arch for PowerShell: $(uname -m)" && exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/powershell.tar.gz \
         "https://github.com/PowerShell/PowerShell/releases/download/v7.6.2/powershell-7.6.2-linux-${ps_arch}.tar.gz" \
    && mkdir -p /opt/microsoft/powershell/7 \
    && tar -xzf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7 \
    && chmod 755 /opt/microsoft/powershell/7/pwsh \
    && ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh \
    && rm -f /tmp/powershell.tar.gz
RUN mkdir -p /etc/xdg/xfce4/terminal \
    && printf '[Configuration]\nRunCustomCommand=TRUE\nCustomCommand=/usr/bin/pwsh\nColorForeground=#000000\nColorBackground=#ffffff\nColorCursor=#000000\n' \
         > /etc/xdg/xfce4/terminal/terminalrc

# Panel launcher for the terminal, wearing the bright blue PowerShell icon.
COPY powershell-icon.png /usr/share/pixmaps/powershell.png
RUN printf '[Desktop Entry]\nVersion=1.0\nType=Application\nName=PowerShell\nComment=PowerShell in xfce4-terminal\nExec=xfce4-terminal\nIcon=/usr/share/pixmaps/powershell.png\nCategories=System;TerminalEmulator;\n' \
      > /usr/share/applications/powershell-terminal.desktop

# Menu cleanup: no Mail Reader entry, and the Web Browser preferred-app
# launcher opens GNOME Web.
RUN rm -f /usr/share/applications/xfce4-mail-reader.desktop \
    && printf '[Desktop Entry]\nVersion=1.0\nType=X-XFCE-Helper\nIcon=org.gnome.Epiphany\nName=GNOME Web\nX-XFCE-Binaries=epiphany\nX-XFCE-Category=WebBrowser\nX-XFCE-CommandsWithParameter=epiphany "%%s"\nX-XFCE-Commands=epiphany\n' > /usr/share/xfce4/helpers/epiphany.desktop \
    && mkdir -p /etc/xdg/xfce4 \
    && printf 'WebBrowser=epiphany\nTerminalEmulator=xfce4-terminal\nFileManager=Thunar\n' > /etc/xdg/xfce4/helpers.rc

# Sequenced pipewire stack as a session autostart (no systemd user units in
# the container).
COPY start-audio.sh /usr/local/bin/start-audio.sh
RUN sed -i 's/\r$//' /usr/local/bin/start-audio.sh && chmod 755 /usr/local/bin/start-audio.sh \
    && printf '[Desktop Entry]\nType=Application\nName=Audio stack\nExec=/usr/local/bin/start-audio.sh\nOnlyShowIn=XFCE;\n' > /etc/xdg/autostart/azurelinux-audio.desktop

# The xrdp sink module built in stage 1: container audio -> xrdp chansrv ->
# rdpsnd channel -> the app's RDP connection -> Windows speakers.
COPY --from=audio-builder /staged/ /

# VS Code detects a WSL-like environment and prompts on every launch;
# the variable opts out. Set for login shells (xrdp sessions).
ENV DONT_PROMPT_WSL_INSTALL=1
RUN printf 'export DONT_PROMPT_WSL_INSTALL=1\n' > /etc/profile.d/vscode-no-wsl-prompt.sh

# The Fedora xrdp package creates the xrdp service user itself, so only add
# it when missing.
RUN id -u xrdp >/dev/null 2>&1 || useradd -r -d / -s /usr/sbin/nologin -c "xrdp daemon" xrdp
RUN useradd -m -s /bin/bash deskuser \
    && echo "deskuser:ChangeMe123!" | chpasswd \
    && printf 'deskuser ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/deskuser \
    && chmod 440 /etc/sudoers.d/deskuser

RUN sed -i 's/password-auth/system-auth/g' /etc/pam.d/xrdp-sesman
# No client drive redirection: without this, chansrv FUSE-mounts a
# thinclient_drives folder into the desktop user's home.
RUN if grep -q '^\[Chansrv\]' /etc/xrdp/sesman.ini; then \
      sed -i '/^\[Chansrv\]/a EnableFuseMount=false' /etc/xrdp/sesman.ini; \
    else \
      printf '\n[Chansrv]\nEnableFuseMount=false\n' >> /etc/xrdp/sesman.ini; \
    fi
RUN xrdp-keygen xrdp /etc/xrdp/rsakeys.ini \
    && openssl req -x509 -newkey rsa:2048 -nodes -days 3652 \
         -keyout /etc/xrdp/key.pem \
         -out /etc/xrdp/cert.pem \
         -config /etc/xrdp/openssl.conf \
    && chgrp xrdp /etc/xrdp/rsakeys.ini /etc/xrdp/key.pem /etc/xrdp/cert.pem \
    && chmod 0640 /etc/xrdp/rsakeys.ini /etc/xrdp/key.pem /etc/xrdp/cert.pem

# Bluecurve theme by neeeeow (github.com/neeeeow/Bluecurve), staged from the
# external/Bluecurve submodule by Build-AzureLinuxRdpImage.ps1. The GTK 2
# engine is skipped (it needs a per-arch compile and XFCE 4.20 is GTK 3).
COPY .bluecurve/themes/ /usr/share/themes/
COPY .bluecurve/icons/ /usr/share/icons/
COPY .bluecurve/fonts/ /usr/share/fonts/luxi/
COPY .bluecurve/wallpapers/ /usr/share/backgrounds/bluecurve/
COPY .bluecurve/azurelinux-logo.png /usr/share/pixmaps/azurelinux-logo.png
COPY xfce-defaults/xsettings.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml
COPY xfce-defaults/xfwm4.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml
COPY xfce-defaults/xfce4-desktop.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml
COPY xfce-defaults/xfce4-panel.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml
# Bluecurve (2002) lacks most modern icon names; inherit complete themes so
# nothing renders as a missing-icon placeholder. elementary-xfce carries the
# XFCE-specific names (utilities-terminal, web-browser, ...).
RUN for theme in /usr/share/icons/Bluecurve*/index.theme; do \
      sed -i 's/^Inherits=.*/Inherits=elementary-xfce,Adwaita,gnome,hicolor/' "$theme" || true; \
    done
RUN fc-cache -f >/dev/null 2>&1 || true

# Fedora 43 dropped the librsvg gdk-pixbuf loader, and its replacement
# (glycin) sandboxes with bubblewrap, which cannot start inside the
# container. Without a working SVG decoder every SVG icon is a missing
# placeholder. Rasterize the themes to PNG at build time instead; see the
# script for details.
COPY rasterize-icons.sh /tmp/rasterize-icons.sh
RUN sed -i 's/\r$//' /tmp/rasterize-icons.sh \
    && bash /tmp/rasterize-icons.sh \
    && rm -f /tmp/rasterize-icons.sh

# Default the clock to US Eastern. The launcher app re-points /etc/localtime
# at the host's actual timezone on every start; the clock itself already
# tracks the host through Hyper-V time synchronization.
RUN ln -sfn /usr/share/zoneinfo/America/New_York /etc/localtime

COPY startwm.sh /usr/libexec/xrdp/startwm.sh
COPY start-desktop.sh /usr/local/bin/start-desktop.sh
# Belt and braces: a CRLF shebang makes exec fail with "no such file or
# directory" if the scripts were checked out on Windows without .gitattributes.
RUN sed -i 's/\r$//' /usr/libexec/xrdp/startwm.sh /usr/local/bin/start-desktop.sh \
    && chmod 755 /usr/libexec/xrdp/startwm.sh /usr/local/bin/start-desktop.sh

EXPOSE 3389
ENTRYPOINT ["/usr/local/bin/start-desktop.sh"]
