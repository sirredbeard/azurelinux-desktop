# dnf update skips pinentry, NetworkManager-wwan, perl-libs

On bare metal after install, `dnf update` skipped three fights between Azure Linux and Fedora:

1. pinentry - AZL pinentry vs Fedora pinentry-gnome3 NVR lock. Keep pinentry on Fedora (with gnome3). Exclude pinentry from azurelinux-base.
2. NetworkManager-wwan - Fedora plugin wants Fedora NM. NM is AZL-owned. Claw NetworkManager-wwan and systemd-rpm-macros to AZL via FEDORA_EXCLUDES.
3. perl-libs - Fedora offers newer perl-libs. AZL perl-Errno hard-requires the AZL perl-libs NVR. Claw perl, perl-libs, perl-interpreter, perl-Errno to AZL.

Stock section names are azurelinux-base / azurelinux-microsoft, not azl-base. Install-time excludepkgs must land on those names or later updates ignore the policy.

Touched the same lists in live kickstart, installer assets, canary/container repo file, and kiwi/config.sh FEDORA_EXCLUDES so live, install target, and container stay aligned.

Metal check after the perl claw: `dnf update --assumeno` reports Nothing to do with no pinentry, NM-wwan, or perl-libs skip.

## kernel-devel, kernel-headers, kernel-tools, kernel-tools-libs

Same class of gap, found later on the same bare metal box. The claw-back
list already covered kernel, kernel-core, kernel-modules,
kernel-modules-core, kernel-modules-extra, but not the tooling family
that ships alongside every AZL kernel build. `dnf update` pulled
Fedora's kernel-tools and kernel-devel (matching Fedora's own kernel
version, not the running AZL kernel) with nothing loud about it, since
`kernel-tools`/`kernel-devel` aren't named `kernel*` closely enough to
catch anyone's eye scanning the list, and AZL ships all four for every
build it publishes. Left the box carrying 200+ MiB of kernel-devel for
a kernel version that was never actually running, plus a real risk of
kmod builds resolving headers that do not match the running kernel.

Added kernel-devel, kernel-headers, kernel-tools, kernel-tools-libs
right after kernel-modules-extra in the same claw-back list, in the
same four places: live kickstart, both yum.repos.d assets (the second
one is the canary/container source of truth), and kiwi/config.sh
FEDORA_EXCLUDES.

Metal check: removed the mismatched Fedora kernel-devel/kernel-tools/
kernel-tools-libs, reinstalled the AZL builds matching the running
kernel, patched the live repo file with the same claw-back entries,
`dnf update --assumeno` reports Nothing to do.
