#!/bin/bash
# post-install.sh — Target system configuration (%post script for kickstart)
# Called from within the installed chroot during anaconda %post.
set -x

# --- Network configuration ---
# NetworkManager owns networking on the installed target; no networkd
# .network file is installed here since systemd-networkd is disabled
# below and never manages this system's interfaces.
install -d -m 0755 /etc/sysctl.d
install -m 0644 /opt/azl-desktop-assets/sysctl.d/80-azurelinux-desktop-policy-routing.conf \
    /etc/sysctl.d/80-azurelinux-desktop-policy-routing.conf

# --- GRUB defaults ---
install -m 0644 /opt/azl-desktop-assets/default/grub \
    /etc/default/grub

install -d -m 0755 /etc/pki/rpm-gpg
if [ -f /opt/azl-desktop-assets/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop ]; then
    install -m 0644 /opt/azl-desktop-assets/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop \
        /etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop
else
    curl -fsSL --retry 3 \
        https://sirredbeard.github.io/azurelinux-desktop/RPM-GPG-KEY-azurelinux-desktop \
        -o /etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop || true
fi
if [ -s /etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop ]; then
    rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop 2>/dev/null || true
fi
install -d -m 0755 /usr/share/azurelinux-desktop/gpg
if [ -f /opt/azl-desktop-assets/gpg/signing-key.asc ]; then
    install -m 0644 /opt/azl-desktop-assets/gpg/signing-key.asc \
        /usr/share/azurelinux-desktop/gpg/signing-key.asc
elif [ -s /etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop ]; then
    install -m 0644 /etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop \
        /usr/share/azurelinux-desktop/gpg/signing-key.asc
fi
# azl-desktop-kmods.repo is installed by the later chroot %post in
# kiwi/azl-install.ks.in from staged /root/assets. This script runs first
# inside the target chroot, before assets are copied, and /opt/azl-desktop-
# assets is only on the installer live root. Do not install the kmods repo
# here. See findings/installer-kmods-repo-missing.md.

# Stock azurelinux-repos writes [azurelinux-base] / [azurelinux-microsoft].
# Kickstart --excludepkgs does not persist into those files. Write
# excludepkgs so later dnf update keeps Fedora pinentry/grub/dnf5 and
# AZL owns NM plugins (findings/dnf-update-pinentry-nm-wwan.md).
python3 - <<'PY'
from pathlib import Path
import re

def set_exclude(path, section, pkgs):
    import sys
    p = Path(path)
    if not p.is_file():
        print(f"warning: missing repo file {path}", file=sys.stderr)
        return
    text = p.read_text()
    # Section body from ^[name] through the line before the next ^[ header.
    pat = re.compile(
        r"(^\[" + re.escape(section) + r"\][^\n]*\n.*?)(?=^\[|\Z)",
        re.M | re.S,
    )
    m = pat.search(text)
    if not m:
        print(f"warning: section [{section}] not in {path}", file=sys.stderr)
        return
    block = m.group(1)
    if re.search(r"^excludepkgs=", block, re.M):
        block = re.sub(
            r"^excludepkgs=.*$", "excludepkgs=" + pkgs, block, count=1, flags=re.M
        )
    else:
        block = block.rstrip("\n") + "\nexcludepkgs=" + pkgs + "\n"
    p.write_text(text[: m.start(1)] + block + text[m.end(1) :])

set_exclude("/etc/yum.repos.d/azurelinux.repo", "azurelinux-base", "hunspell-en,grub2,grub2-pc,grub2-pc-modules,grub2-efi-x64,grub2-efi-x64-modules,grub2-efi-x64-cdboot,grub2-tools,grub2-tools-extra,grub2-tools-minimal,grub2-common,shim,shim-x64,gsettings-desktop-schemas,dnf5,dnf5daemon-server,dnf5daemon-server-polkit,libdnf5,libdnf5-cli,libdnf5-plugin-actions,libdnf5-plugin-appstream,libdnf5-plugin-expired-pgp-keys,libdnf5-plugin-local,pinentry")
set_exclude("/etc/yum.repos.d/azurelinux.repo", "azurelinux-microsoft", "hunspell-en,grub2,grub2-pc,grub2-pc-modules,grub2-efi-x64,grub2-efi-x64-modules,grub2-efi-x64-cdboot,grub2-tools,grub2-tools-extra,grub2-tools-minimal,grub2-common,shim,shim-x64,gsettings-desktop-schemas,pinentry")
set_exclude("/etc/yum.repos.d/microsoft.repo", "azurelinux-microsoft", "hunspell-en,grub2,grub2-pc,grub2-pc-modules,grub2-efi-x64,grub2-efi-x64-modules,grub2-efi-x64-cdboot,grub2-tools,grub2-tools-extra,grub2-tools-minimal,grub2-common,shim,shim-x64,gsettings-desktop-schemas,pinentry")
PY


# --- Encrypted disk: regenerate initramfs with LUKS support ---
if [ -f /etc/crypttab ] && [ -s /etc/crypttab ]; then
    echo "LUKS detected — regenerating initramfs with crypt module..."
    dracut --regenerate-all --force --add crypt
fi

# --- Security hardening ---
# Remove SSH host keys — sshd-keygen regenerates on first boot
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

# Reset machine-id — systemd regenerates on first boot
: > /etc/machine-id

# Disable root SSH login with password (key-based only)
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config 2>/dev/null || true

# Trigger SELinux relabel on first boot. Covered by Plymouth via
# assets/bin/azl-first-boot-prepare (selinux-autorelabel.service drop-in):
# splash stays up with one "Finishing setup. System will reboot." line instead
# of stock fixfiles console spam.
touch /.autorelabel

# Re-apply iHD dri link if the offline %post path reinstalled media packages
# without config.sh. No-op when the .so is already linked.
if [ -x /usr/local/bin/azl-link-intel-ihd ]; then
    /usr/local/bin/azl-link-intel-ihd /
elif [ -e /usr/lib64/dri-nonfree/iHD_drv_video.so ]; then
    install -d -m 0755 /usr/lib64/dri /etc/environment.d
    ln -sfn ../dri-nonfree/iHD_drv_video.so /usr/lib64/dri/iHD_drv_video.so
    if [ -f /usr/share/azurelinux-desktop/environment.d/50-azurelinux-desktop-libva.conf ]; then
        install -m 0644 \
            /usr/share/azurelinux-desktop/environment.d/50-azurelinux-desktop-libva.conf \
            /etc/environment.d/50-azurelinux-desktop-libva.conf
    fi
fi

# Desktop performance userspace (Fedora packages). Sysctl/zram conf comes
# from azurelinux-desktop-performance-kmod; this only enables the daemons.
systemctl enable irqbalance.service 2>/dev/null || true
systemctl enable tuned.service 2>/dev/null || true
if command -v tuned-adm >/dev/null 2>&1; then
    tuned-adm profile desktop 2>/dev/null || tuned-adm profile balanced 2>/dev/null || true
fi
systemctl enable thermald.service 2>/dev/null || true
# NetworkManager owns networking on this image, not systemd-networkd, but
# systemd-networkd-wait-online.service still rides in enabled via systemd's
# own preset. It then blocks graphical.target for its full 2 minute
# timeout every boot since networkd never configures anything here.
# Disable both explicitly.
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl disable systemd-networkd.service 2>/dev/null || true
# Azure VM guest agent is not in the desktop package set. Mask if present.
systemctl disable --now walinuxagent.service 2>/dev/null || true
systemctl mask walinuxagent.service 2>/dev/null || true
systemctl disable --now waagent.service 2>/dev/null || true
systemctl mask waagent.service 2>/dev/null || true

# Journal + iosched assets (also staged in kiwi/config.sh for the offline tree).
if [ -f /opt/azl-desktop-assets/systemd/journald.conf.d/50-azurelinux-desktop.conf ]; then
    install -d -m 0755 /etc/systemd/journald.conf.d
    install -m 0644 \
        /opt/azl-desktop-assets/systemd/journald.conf.d/50-azurelinux-desktop.conf \
        /etc/systemd/journald.conf.d/50-azurelinux-desktop.conf
fi
if [ -f /opt/azl-desktop-assets/udev/60-azurelinux-desktop-iosched.rules ]; then
    install -d -m 0755 /etc/udev/rules.d
    install -m 0644 \
        /opt/azl-desktop-assets/udev/60-azurelinux-desktop-iosched.rules \
        /etc/udev/rules.d/60-azurelinux-desktop-iosched.rules
fi
