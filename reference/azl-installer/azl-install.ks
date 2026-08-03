# Azure Linux 4.0 — Anaconda Kickstart (Offline)

# Installation source — local repo bundled on the ISO
repo --name=azl-offline --baseurl=file:///opt/azl-offline-repo/

# Disable any system repos so only the offline repo is used
# (handled by disabling .repo files before anaconda starts)

# System settings
lang en_US.UTF-8
keyboard us
timezone UTC --utc
selinux --enforcing
firewall --enabled --ssh
network --hostname=azurelinux
services --enabled=sshd,systemd-networkd,systemd-resolved

# Bootloader
bootloader --location=mbr --append="console=ttyS0,115200 console=tty0"

# Eject installation media and reboot automatically after install
reboot --eject

# Disk layout — LVM without encryption
clearpart --all --initlabel
part /boot/efi --fstype=efi --size=600
part /boot --fstype=ext4 --size=1024
part pv.01 --size=1 --grow
volgroup vg_azl pv.01
logvol swap --vgname=vg_azl --name=lv_swap --fstype=swap --size=512
logvol / --vgname=vg_azl --name=lv_root --fstype=ext4 --size=1 --grow

# Packages — minimal Azure Linux system
# --nocore: AZL repo has no comps groups, so @core would fail
%packages --nocore
bash
coreutils
systemd
systemd-networkd
systemd-resolved
dnf5
grub2
grub2-efi-x64
grub2-efi-x64-modules
shim
efibootmgr
kernel
kernel-modules
openssh-server
openssh-clients
sudo
vim-minimal
ca-certificates
azurelinux-release
azurelinux-repos
setup
shadow-utils
util-linux
selinux-policy-targeted
audit
chrony
cracklib-dicts
glibc
glibc-langpack-en
cryptsetup
firewalld
iproute
%end

%post --nochroot --log=/mnt/sysroot/var/log/anaconda-post.log
cp /root/post-install.sh /mnt/sysroot/tmp/
chroot /mnt/sysroot bash /tmp/post-install.sh
rm -f /mnt/sysroot/tmp/post-install.sh
%end

%post --nochroot --log=/mnt/sysroot/var/log/anaconda-bootloader.log
/root/post-bootloader.sh
%end
