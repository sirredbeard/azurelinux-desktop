# Dual-boot: Fedora host + nested Azure Linux Desktop on a container partition

**Status:** active host setup notes (no host serials/UUIDs)

## Layout

Host GPT (example layout only; paths are local):

1. ESP (Fedora)
2. `/boot` (Fedora)
3. LUKS/btrfs (Fedora root+home)
4. **Container partition** for Azure Linux Desktop (`PARTUUID=<uuid>`)

Inside the container partition, Anaconda wrote a nested GPT (install done in QEMU with only that partition attached):

1. ESP `<esp-uuid>`
2. `/boot` `<uuid>`
3. `/` `<uuid>`
4. `/home` `<uuid>`

The host firmware only sees the host partitions. Nested ESP is not a firmware boot target. Nested ESP is not a firmware boot target.

## Host GRUB

- Drop-in: `/etc/grub.d/45_azurelinux_desktop_nested`
- Menu entries in `/boot/grub2/grub.cfg` (titles from
  `scripts/restage-azl-nested-boot.sh`):
  - `Azure Linux Desktop (test install on container partition)` (primary)
  - `Azure Linux Desktop rescue (nested container partition)`
  - `Azure Linux Desktop (loopback fallback)` (recovery only)
- `GRUB_TIMEOUT=15`, `GRUB_TIMEOUT_STYLE=menu`
- **`menu_auto_hide` must be unset**, not `0`. Fedora GRUB treats any
  non-empty `menu_auto_hide` as enabled, so `=0` still hides the menu
  after a successful boot (`timeout_style=hidden`, `timeout=1`) and the
  dual-boot entries never appear.
- `/etc/grub.d/13_azl_force_menu` runs after `12_menu_auto_hide` and
  forces `timeout_style=menu` + `timeout=15` on every config rebuild.
- Default remains Fedora BLS entry (`saved_entry=<fedora-bls-id>)
- EFI BootOrder first entry is the host Fedora shim
- Stale EFI NVRAM entry from the QEMU install path was removed

### Menu order at boot

1. Fedora kernels (BLS / blscfg) — default
2. UEFI Firmware Settings
3. Azure Linux Desktop (nested test install)
4. Azure Linux Desktop rescue
5. Azure Linux Desktop (loopback fallback)

Arrow down from the Fedora entry to reach Azure Linux.

### Why kernel/initrd are staged on Fedora `/boot`

This host GRUB build has **no `search_part_uuid` module**. Nested filesystems
inside the container partition are also invisible to GRUB without loopback. Primary entries
therefore load staged copies:

- `/boot/vmlinuz-azl-desktop-nested`
- `/boot/initramfs-azl-desktop-nested.img`

copied from the nested `/boot`, then boot with:

`root=UUID=<nested-root-uuid> ro rootwait console=tty0 rhgb quiet`

(`rhgb quiet` for Plymouth; `console=tty0` only — no `ttyS0`.)

After an Azure Linux kernel/initramfs update or nested reinstall, run:

`scripts/restage-azl-nested-boot.sh`

That script restages kernel/initrd, rebuilds nested initrd with
`50azl-nested-partx` (`dracut --add azl-nested-partx`), refreshes the GRUB
drop-in, enables persistent journald on the nested root, and softens
thinkpad modules-load so VMs do not fail `systemd-modules-load`.

### Sanity check results (2026-08-03 reinstall)

- QEMU boot of the nested install reached GNOME desktop after SELinux
  autorelabel
- Full desktop kmod set present under
  `/usr/lib/modules/<kver>/extra/azurelinux-desktop/` (usbhid, usb-storage,
  iwlwifi, sound, bluetooth, uvc, thinkpad, typec) plus policy RPM and
  iwlwifi firmware packages
- Host GRUB drop-in executable; three Azure Linux menu entries in
  `grub.cfg`; `grub2-script-check` OK; `GRUB_TIMEOUT=15` menu style
- Staged initrd contains `kpartx` and `pre-mount/10-azl-nested-partx.sh`
- Nested `journald`: `Storage=persistent` via
  `/etc/systemd/journald.conf.d/90-azl-desktop-persistent.conf`
- `gdm` and `sshd` enabled on nested install
- After bare-metal boot, check hardware with journalctl (wifi/bt/audio/camera)
  without pasting host serials or partition UUIDs into public findings

## Nested initramfs hook

Azure Linux ships a dracut module:

- `/usr/lib/dracut/modules.d/50azl-nested-partx/`
- pre-mount hook runs **`kpartx -av`** on the container partition so nested
  UUIDs appear before root mount (`/dev/mapper/the container partitionp*` + by-uuid)

Without this, bare metal cannot resolve `root=UUID=...` because the kernel
does not auto-scan GPT inside a partition.

**Do not use `partx --delete` on the container node from the host.** On this
machine that removed `the container partition` from the live partition table (on-disk GPT
was fine; `partprobe` restored the node). Host-side tooling should use
`kpartx` only.

## Clean logs for bare-metal failure analysis

Before first bare-metal boot, journals and log files on the nested install
were wiped. Persistent journal is enabled
(`/etc/systemd/journald.conf.d/persistent.conf`).

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

## Reinstall with a newer installer ISO (WiFi packages)

Release `2026.08.02` installer ships `kernel-modules-extra` and
`iwlwifi-*-firmware`. Reinstall nested Azure Linux on **the container partition only**, then restage
kernel/initrd for host GRUB before bare-metal WiFi check.

1. Confirm fresh ISO checksum under `~/azl-work/`.
2. Stop any QEMU using the container partition. Unmount nested maps, then
   `kpartx -d $HOSTPART` (never `partx --delete`).
3. For a full reinstall, wipe the nested contents of the container partition only (host GPT
   entry stays). Zero the start/end of the partition and
   `wipefs -a --force` so OVMF/Anaconda do not see the old ESP.
4. Launch installer against the container partition only. The helper uses **fresh OVMF vars**
   and gives the ISO `bootindex=1` so firmware does not boot a leftover
   nested install from NVRAM:

```bash
# Default: graphical tty1 + PS/2 keyboard in the GTK window
./scripts/qemu-install-to-hostpart.sh \
  ~/azl-work/azurelinux-desktop-install.iso \
  $HOSTPART azl-installer-hostpart 8192

# Optional serial typing path:
#   AZL_INSTALLER_INPUT=serial ./scripts/qemu-install-to-hostpart.sh ...
#   socat STDIO,raw,echo=0,escape=0x1d \
#     UNIX-CONNECT:$HOME/azl-work/azl-installer-hostpart-serial.sock
```

The installer ISO has **no usbhid**. Default mode uses QEMU’s PS/2
keyboard on tty1 (`console=tty0`, no serial device). Guest disk label
`QEMU NVMe Ctrl` / `the host disk` is still the host container partition
attached as raw (not a qcow2).

Release `2026.08.02` hit `No match for argument: nvme-cli` on that NVMe
target. Fix: `nvme-cli` in `EXTRA_REPO_PKGS` — see
`anaconda-nvme-cli-offline-repo.md`. Use a rebuilt installer ISO after
that change for bare metal or nested reinstall.

5. In Anaconda, use the single NVMe disk (the container partition). Keep
   the nested layout (ESP, `/boot`, `/`, `/home`) or accept Anaconda’s
   guided layout for that one disk.

6. Shut down the guest after install.
7. QEMU first-boot smoke test:

```bash
./scripts/qemu-boot-installed-hostpart.sh $HOSTPART
```

8. From Fedora, restage nested kernel/initrd onto `/boot` and rebuild GRUB
   if the NEVRA changed (see staging paths above).
9. Optional: wipe nested journals before bare metal so new boot logs are
   clean (`inspect-azl-nested-install.sh` after mount, or clear
   `/var/log/journal` on nested root).
10. Reboot bare metal, pick **Azure Linux Desktop** in the GRUB menu, test
    WiFi (`iwlwifi` bind + `wlp…` in NetworkManager).

## Safety

- Guest/install path must only ever receive **the container partition**, never the whole NVMe.
- Fedora ESP/root/bootloader stay on the host system partitions.

## Fresh nested reinstall (2026-08-02, installer with kmods + Wi-Fi pkgs)

Target: host container partition only (default `the container partition`), never the whole disk.

Prep:

1. Downloaded installer from release `2026.08.02` via
   `scripts/Get-AzureLinuxDesktop.ps1 -Install` into `~/azl-work`.
2. Verified reassembled ISO checksum against the published `.sha256`.
3. Confirmed installer **initrd** contains project modules:
   - `extra/azurelinux-desktop/usbhid.ko`
   - `extra/azurelinux-desktop/usb-storage.ko`
   - `extra/azurelinux-desktop/uas.ko`
4. Confirmed offline live rootfs strings include `nvme-cli-`,
   `iwlwifi-mvm-firmware`, `kernel-modules-extra-`,
   `azurelinux-desktop-policy`, both kmod package names.
5. Wiped only the first 64 MiB of the container partition so the nested
   GPT was gone (`sfdisk` reported no partition table). Host system partitions
   untouched.
6. Launched:
   `AZL_INSTALLER_INPUT=gtk ./scripts/qemu-install-to-hostpart.sh \
      ~/azl-work/azurelinux-desktop-install.iso $HOSTPART`

Manual TUI steps (operator):

- Admin username + password when prompted.
- Storage spoke: single NVMe disk shown to the guest is the container
  partition. Auto or custom layout is fine; this wipes that container only.
- Optional: timezone/language. Press **b** when storage is complete.
- After reboot/shutdown of the guest, restage nested kernel/initrd onto
  Fedora `/boot` before bare-metal dual-boot:
  `vmlinuz-azl-desktop-nested` / `initramfs-azl-desktop-nested.img`.

Wi-Fi note: nested QEMU has no Intel Wi-Fi NIC. Firmware RPMs and
`kernel-modules-extra` land on the nested root, but AZL 4.0 x86_64 has
`# CONFIG_WLAN is not set`, so there is still no `iwlwifi.ko`. Bare-metal
Wi-Fi needs an out-of-tree driver (or a kernel config change). See
[`wifi-missing-on-bare-metal.md`](wifi-missing-on-bare-metal.md).


## Post-reinstall verification (2026-08-02 evening)

Installer ISO (checksum `0bfd6d2c…`, kmods + offline `nvme-cli` + firmware
RPMs) completed a full Anaconda install onto the host container partition
only. QEMU then rebooted into the same ISO and exited; that is expected with
the current install script (ISO stays first bootindex).

### Nested layout (standard partitions, not LVM)

| Nested | Role | Filesystem UUID |
| --- | --- | --- |
| nested ESP | ESP | `<esp-uuid>` |
| nested /boot | `/boot` | `<uuid>` |
| nested / | `/` | `<uuid>` |
| the container partition | `/home` | `<uuid>` |

Host GRUB drop-in `/etc/grub.d/45_azurelinux_desktop_nested` and staged
files were refreshed with
[`scripts/restage-azl-nested-boot.sh`](../scripts/restage-azl-nested-boot.sh):

* `/boot/vmlinuz-azl-desktop-nested`
* `/boot/initramfs-azl-desktop-nested.img`
* `root=UUID=<uuid>`
* Fedora `/boot` search UUID unchanged: `<uuid>`
* `grub2-script-check` OK

### Nested initramfs hook (restored)

A stock Anaconda install does **not** include the dual-boot
`50azl-nested-partx` dracut module. Without it, bare metal cannot resolve
the nested root UUID. Module sources live in
[`assets/dracut/50azl-nested-partx/`](../assets/dracut/50azl-nested-partx/).
Installed into the nested root, `dracut -f` rebuilt the initrd. Staged
initrd now contains:

* `pre-mount/10-azl-nested-partx.sh`
* `usr/bin/kpartx`
* project `usbhid` / `usb-storage` / `uas`

Also stripped missing `bochs_drm` from nested
`/etc/dracut.conf.d/early-kms.conf` so rebuilds do not fail (module not
in this Azure Linux kernel module set).

### Packages on nested root (rpm)

Present:

* `azurelinux-desktop-policy` + both USB kmod RPMs
* `kernel-modules-extra`
* `iwlwifi-mvm-firmware`, `iwlwifi-dvm-firmware`, `iwlwifi-mld-firmware`

**Wi-Fi still blocked at kernel config:** `# CONFIG_WLAN is not set` on
AZL 4.0 x86_64. Firmware RPMs and `kernel-modules-extra` do **not** ship
`iwlwifi.ko`. See [`wifi-missing-on-bare-metal.md`](wifi-missing-on-bare-metal.md).

## Fresh nested reinstall (2026-08-03, iwlwifi kmod media)

Installer ISO release `2026.08.03` (checksum `ac6d63c5…`) onto host
container partition only. Standard partitions (not LVM). QEMU install +
first-boot SELinux autorelabel + GDM confirmed. Guest SSH checks:

* policy + usbhid + usb-storage + iwlwifi kmod RPMs installed
* all seven modules under `extra/azurelinux-desktop/`
* `modprobe iwlwifi` loads; `usbhid` from OOT path
* GRUB uses `gfxterm`; EFI `azurelinux/` has shim+grub
* nested root UUID `<uuid>`

Host dual-boot restage:

* staged `/boot/vmlinuz-azl-desktop-nested` +
  `/boot/initramfs-azl-desktop-nested.img`
* drop-in root=`UUID=<uuid>`, Fedora boot search
  `<uuid>`
* `13_azl_force_menu` keeps `timeout_style=menu` / `timeout=15`
* staged initrd contains `10-azl-nested-partx.sh`, `kpartx`, USB kmods
* `grub2-script-check` OK; BootOrder first entry still Fedora shim
* nested filesystems `e2fsck -n` clean

Bare metal: pick **Azure Linux Desktop (nested test install)** in
the Fedora GRUB menu. Wi-Fi bind is the remaining hardware proof.
