# Hypervisor guest agents (ship-all)

**Status:** packages + enables landed in live kickstart and installer
`INSTALL_PKGS` / `azl-install.ks.in`. Runtime verify after next image
build. Companion: `findings/hypervisor-mouse-ps2-boxes.md` (PS/2 +
Boxes mouse/resize).

## Why one package set for every format

Disk pipeline builds **one** qcow2, then `qemu-img convert` to VHDX /
VDI / VMDK. There is no second kickstart per hypervisor. Shipping
every guest agent on every image is the minimal approach that still
covers Hyper-V, VirtualBox, VMware, and QEMU/SPICE without five
kickstarts.

Agents that do not match the host stay quiet:

| Package | Role | Start behavior |
| --- | --- | --- |
| `spice-vdagent` | Boxes/virt-manager SPICE clipboard + resize | `spice-vdagentd` + session autostart; no-op without spice channel |
| `qemu-guest-agent` | QEMU lifecycle / fsfreeze | enabled; waits on virtio serial |
| `hyperv-daemons` | Hyper-V KVP/VSS/fcopy | udev when vmbus appears |
| `open-vm-tools` + `open-vm-tools-desktop` | VMware | `vmtoolsd` enabled; detects VMware |
| `virtualbox-guest-additions` | VBox userspace (Fedora RPM) | `vboxservice` enabled; **no** `vboxguest.ko` in this RPM |

## Where listed

- `kickstart/azurelinux-desktop-live.ks` `%packages` + `%post`
  `systemctl enable` for spice-vdagentd, qemu-guest-agent, vmtoolsd,
  vboxservice
- `kiwi/config.sh` `INSTALL_PKGS` (installed target offline set)
- `kiwi/azl-install.ks.in` matching enables

Not added to the canary container (no desktop/SPICE session).

## PS/2 mouse (separate kmod)

Boxes still presents PS/2 by default. Guest agents do not replace
`psmouse`. OOT family `azurelinux-desktop-psmouse-kmod` is added in
`scripts/build-desktop-kmods.sh` and will ship on the next Pages
kmod publish (`azurelinux-desktop-policy` Requires). Until that
publish + image rebuild, PS/2-only guests still need a tablet hot-add
or virtio-tablet.

## Issue

GitHub issue #1 (hypervisor / Boxes guest tooling).

## Still verify after rebuild

1. Boxes: mouse without host tablet attach; window resize via spice.
2. Project QEMU scripts: no regression (still use usb-tablet).
3. `rpm -q` of the six packages on live + installed.
4. `systemctl is-enabled spice-vdagentd qemu-guest-agent`.
5. VBox full features still need a later `vboxguest.ko` path if wanted.
