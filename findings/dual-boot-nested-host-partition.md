# Dual-boot: Fedora host + nested Azure Linux Desktop

**Status:** active host setup notes (no host serials/UUIDs)

## Layout

Host GPT (example layout only; paths are local):

1. ESP (Fedora)
2. `/boot` (Fedora)
3. LUKS/btrfs (Fedora root+home)
4. **Container partition** for Azure Linux Desktop (`nvme0n1p4` only)

Inside the container partition, Anaconda wrote a nested GPT (install
done in QEMU with only that partition attached):

1. ESP
2. `/boot`
3. `/`
4. `/home`

The host firmware only sees the host partitions. Nested ESP is not a
firmware boot target.

## Safety rules (hard)

- Guest/install path must only ever receive **nvme0n1p4**, never the
  whole NVMe.
- Fedora ESP/root/bootloader stay on the host system partitions.
- After nested reinstall or Azure Linux kernel/initramfs update, run
  `scripts/restage-azl-nested-boot.sh`. The restage script writes the
  current nested root UUID into the host GRUB drop-in.
- Keep Fedora EFI first in BootOrder.
- Nested root needs the `50azl-nested-partx` dracut module so initrd
  runs `kpartx` before mount.
- **Never** run `partx --delete` on the container node from the host.
  On this machine that removed the live partition node (on-disk GPT was
  fine; `partprobe` restored it). Host-side tooling should use `kpartx`
  only.

## Host GRUB

- Drop-in: `/etc/grub.d/45_azurelinux_desktop_nested`
- Menu entries (titles from `scripts/restage-azl-nested-boot.sh`):
  - `Azure Linux Desktop (test install on container partition)` (primary)
  - `Azure Linux Desktop rescue (nested container partition)`
  - `Azure Linux Desktop (loopback fallback)` (recovery only)
- `GRUB_TIMEOUT=15`, `GRUB_TIMEOUT_STYLE=menu`
- **`menu_auto_hide` must be unset**, not `0`. Fedora GRUB treats any
  non-empty `menu_auto_hide` as enabled, so `=0` still hides the menu
  after a successful boot and the dual-boot entries never appear.
- `/etc/grub.d/13_azl_force_menu` runs after `12_menu_auto_hide` and
  forces `timeout_style=menu` + `timeout=15` on every config rebuild.
- Default remains the Fedora BLS entry.
- EFI BootOrder first entry is the host Fedora shim.
- Stale EFI NVRAM entry from the QEMU install path was removed.

### Menu order at boot

1. Fedora kernels (BLS / blscfg) - default
2. UEFI Firmware Settings
3. Azure Linux Desktop (nested test install)
4. Azure Linux Desktop rescue
5. Azure Linux Desktop (loopback fallback)

Arrow down from the Fedora entry to reach Azure Linux.

### Why kernel/initrd are staged on Fedora `/boot`

This host GRUB build has no `search_part_uuid` module. Nested
filesystems inside the container partition are also invisible to GRUB
without loopback. Primary entries therefore load staged copies:

- `/boot/vmlinuz-azl-desktop-nested`
- `/boot/initramfs-azl-desktop-nested.img`

copied from the nested `/boot`, then boot with:

`root=UUID=<nested-root-uuid> ro rootwait console=tty0 rhgb quiet`

(`rhgb quiet` for Plymouth; `console=tty0` only - no `ttyS0`.)

The restage script also rebuilds nested initrd with
`50azl-nested-partx` (`dracut --add azl-nested-partx`), refreshes the
GRUB drop-in, enables persistent journald on the nested root, and
softens thinkpad modules-load so VMs do not fail `systemd-modules-load`.

## Nested initramfs hook

Azure Linux ships a dracut module:

- `/usr/lib/dracut/modules.d/50azl-nested-partx/`
- pre-mount hook runs `kpartx -av` on the container partition so nested
  UUIDs appear before root mount

Without this, bare metal cannot resolve `root=UUID=...` because the
kernel does not auto-scan GPT inside a partition.

A stock Anaconda install does not include this module. Module sources
live in `assets/dracut/50azl-nested-partx/`. Restage installs them and
rebuilds the initrd.

## Clean logs for bare-metal failure analysis

Before first bare-metal boot, journals and log files on the nested
install can be wiped. Persistent journal is enabled under
`/etc/systemd/journald.conf.d/`.

After a failed (or successful) AZL boot, return to Fedora and run:

```bash
./scripts/inspect-azl-nested-install.sh
# or
./scripts/inspect-azl-nested-install.sh --copy-logs ~/azl-work/azl-boot-logs
./scripts/inspect-azl-nested-install.sh --umount
```

## QEMU host-like retest

```bash
./scripts/qemu-boot-installed-hostpart.sh $HOSTPART
```

## Reinstall with a newer installer ISO

Reinstall nested Azure Linux on **nvme0n1p4 only**, then restage
kernel/initrd for host GRUB before bare-metal checks.

1. Confirm fresh ISO checksum under `~/azl-work/`.
2. Stop any QEMU using the container partition. Unmount nested maps,
   then `kpartx -d $HOSTPART` (never `partx --delete`).
3. For a full reinstall, wipe the nested contents of the container
   partition only (host GPT entry stays). Zero the start/end of the
   partition and `wipefs -a --force` so OVMF/Anaconda do not see the
   old ESP.
4. Launch installer against the container partition only. The helper
   uses fresh OVMF vars and gives the ISO `bootindex=1` so firmware
   does not boot a leftover nested install from NVRAM:

```bash
# Default: graphical tty1 + PS/2 keyboard in the GTK window
./scripts/qemu-install-to-hostpart.sh \
  ~/azl-work/azurelinux-desktop-install.iso \
  $HOSTPART azl-installer-hostpart 8192
```

The installer ISO has no usbhid. Default mode uses QEMU PS/2 keyboard
on tty1 (`console=tty0`, no serial device). Guest disk label is still
the host container partition attached as raw (not a qcow2).

5. In Anaconda, use the single NVMe disk (the container partition).
6. Shut down the guest after install.
7. QEMU first-boot smoke test:
   `./scripts/qemu-boot-installed-hostpart.sh $HOSTPART`
8. From Fedora, run `scripts/restage-azl-nested-boot.sh` (writes current
   UUID, stages kernel/initrd, rebuilds GRUB).
9. Optional: wipe nested journals before bare metal so new boot logs are
   clean.
10. Reboot bare metal, pick Azure Linux Desktop in the GRUB menu.

## Nested layout after install

Standard partitions (not LVM) inside the container:

- nested ESP
- nested `/boot`
- nested `/`
- nested `/home`

Host GRUB drop-in and staged files refreshed by
`scripts/restage-azl-nested-boot.sh`.

## Packages and kmods on nested root

Expect:

- `azurelinux-desktop-policy` + USB/Wi-Fi/BT and related kmod RPMs
- project modules under `extra/azurelinux-desktop/`
- firmware packages as shipped by the installer offline set

Wi-Fi on bare metal needs the OOT iwlwifi path when AZL stock config
leaves WLAN off. See `wifi-missing-on-bare-metal.md`.

## Nested desktop polish / Flatpak

After installer to hostpart boot:

- First-boot Plymouth/relabel and GRUB timeout 0: see
  `first-boot-plymouth-relabel.md`, `installed-grub-skip-menu.md`,
  `scripts/patch-nested-desktop-polish.sh`.
- Copilot Flatpak system updates: Pages must be GPG-signed and the
  image needs the wheel polkit rule. See
  `flatpak-untrusted-non-gpg-remote.md`.
- Guest default shell is often `pwsh` (use `bash -c`).
