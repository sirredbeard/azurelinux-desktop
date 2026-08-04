#!/bin/bash
# post-install.sh — Target system configuration (%post script for kickstart)
# Called from within the installed chroot during anaconda %post.
set -x

# --- Network configuration ---
cat > /etc/systemd/network/20-wired-dhcp.network << 'NET'
[Match]
Name=en* eth*

[Network]
DHCP=yes

[DHCPv4]
UseDNS=yes
NET

# --- GRUB defaults ---
cat > /etc/default/grub << 'GRUBDEF'
GRUB_TIMEOUT=2
GRUB_DISTRIBUTOR="Azure Linux"
GRUB_DEFAULT=0
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_CMDLINE_LINUX="console=ttyS0,115200 console=tty0"
GRUB_DISABLE_RECOVERY=true
GRUBDEF

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
cat > /etc/yum.repos.d/azl-desktop-kmods.repo << 'REPO'
[azl-desktop-kmods]
name=Azure Linux Desktop kernel modules
baseurl=https://sirredbeard.github.io/azurelinux-desktop/repo
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop
cost=1
REPO

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
# splash stays up with one "expanding disk / reboot once more" line instead
# of stock fixfiles console spam.
touch /.autorelabel
