# Nested virt and max performance as a VM guest

## tuned profile: fixed a real "wrong profile baked into VM images" bug

The live kickstart (which also builds the qcow2/VHDX/VDI/VMDK disk
images) and the installer's `kiwi/post-install.sh` both used to force
`tuned-adm profile desktop` unconditionally at build/install time.
tuned ships its own virt-aware auto-recommend logic
(`/usr/lib/tuned/recommend.d/50-tuned.conf`): `virt=.+` picks the
`virtual-guest` profile (looser `dirty_bytes`/`vm.swappiness`, tuned
for a virtio/paravirt I/O path) automatically. Forcing "desktop" ahead
of time silently overrides that for every published disk image, since
those always run as a VM guest under KVM/Hyper-V/VirtualBox/VMware.

Can't just call `systemd-detect-virt` at build time either: CI runners
building the live ISO/disk images are commonly VMs themselves, so a
build-time check would misclassify the bare-metal-targeted live ISO
and installed system too.

Fix: `azl-tuned-autoprofile.service` (oneshot,
`ConditionPathExists=!/etc/tuned/active_profile`, runs before
`tuned.service`) + `/usr/libexec/azl-tuned-autoprofile` decide at real
first boot: `systemd-detect-virt --vm` true -> `virtual-guest`, false
-> `desktop`. Wired into both the live kickstart (for live ISO + disk
images) and `kiwi/azl-install.ks.in`'s chroot `%post` (for the
installer target - `kiwi/post-install.sh` runs too early in that path
to see `$ASSETS`, so the unit gets staged in the later phase instead,
same as `azl-flatpak-appstream.service`).

## Nested KVM

Nested virtualization is a *host* hypervisor setting
(`kvm_intel.nested=1` / `kvm_amd.nested=1` on the physical machine),
not something this project's image can turn on for itself. What the
image controls is guest-side readiness: `CONFIG_KVM`, `CONFIG_KVM_INTEL`,
`CONFIG_KVM_AMD` are stock `=m` in the Azure Linux kernel, so if the
outer host has nested virt enabled, `/dev/kvm` shows up correctly
inside this desktop when it's itself a VM, and any hypervisor userspace
run inside it (QEMU/KVM, VirtualBox, etc.) can use hardware
acceleration instead of falling back to software emulation. This
project does not currently ship GNOME Boxes, virt-manager, or libvirtd
- none of the existing kickstart/kiwi package lists include them. That
would be a separate, deliberate package addition, not implied by
existing coverage.

## Guest agent coverage across hypervisors (already covered, verified)

Confirmed already shipped identically in both the live kickstart and
kiwi's installer package list ("ship-all" approach - see
`findings/hypervisor-mouse-ps2-boxes.md` and issue #1): `spice-vdagent`,
`qemu-guest-agent`, `hyperv-daemons`, `open-vm-tools` +
`open-vm-tools-desktop`, `virtualbox-guest-additions`. Units are
enabled unconditionally; each no-ops or udev-gates when its matching
hypervisor is absent, so this is harmless on bare metal and correct
under all four target hypervisors without per-hypervisor image
variants.
