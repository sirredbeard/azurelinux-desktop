# dnf update skips pinentry, NetworkManager-wwan, perl-libs

On bare metal after install, `dnf update` skipped three fights between Azure Linux and Fedora:

1. pinentry - AZL pinentry vs Fedora pinentry-gnome3 NVR lock. Keep pinentry on Fedora (with gnome3). Exclude pinentry from azurelinux-base.
2. NetworkManager-wwan - Fedora plugin wants Fedora NM. NM is AZL-owned. Claw NetworkManager-wwan and systemd-rpm-macros to AZL via FEDORA_EXCLUDES.
3. perl-libs - Fedora offers newer perl-libs. AZL perl-Errno hard-requires the AZL perl-libs NVR. Claw perl, perl-libs, perl-interpreter, perl-Errno to AZL.

Stock section names are azurelinux-base / azurelinux-microsoft, not azl-base. Install-time excludepkgs must land on those names or later updates ignore the policy.

Touched the same lists in live kickstart, installer assets, canary/container repo file, and kiwi/config.sh FEDORA_EXCLUDES so live, install target, and container stay aligned.

Metal check after the perl claw: `dnf update --assumeno` reports Nothing to do with no pinentry, NM-wwan, or perl-libs skip.
