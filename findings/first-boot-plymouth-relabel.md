# First-boot SELinux relabel covered by Plymouth

**Status:** Fix staged in tree. Needs installer/live rebuild for release
artifacts. Nested install can be patched in place for local QA.

## Observed failure

First boot of a fresh installed system (installer ISO path touches
`/.autorelabel` in `kiwi/post-install.sh`) dropped to a black console and
printed stock SELinux autorelabel text:

```
*** Warning -- SELinux targeted policy relabel is required.
*** Relabeling could take a very long time...
Running: /sbin/fixfiles -T 0 restore
```

Then the system reboots once more. Disk-image first boot has a similar
"extra work then continue" feel when `azl-growroot` runs after
`qemu-img resize`.

## Root cause

`/usr/libexec/selinux/selinux-autorelabel` (Fedora/Azure SELinux package)
does:

```bash
[ -x /bin/plymouth ] && plymouth --quit
```

then echoes the warnings to the console (`StandardOutput=journal+console`
on `selinux-autorelabel.service`). Plymouth was running under `rhgb quiet`;
the script tears it down on purpose.

## Fix

1. `assets/bin/azl-first-boot-prepare` — keep splash up, show one message:
   "Expanding disk and finishing setup. The system will reboot once more."
   Grow root when `azl-growroot` / `growpart` are available, run
   `fixfiles` quietly to `/var/log/azl-first-boot-fixfiles.log`, then
   reboot (same cleanup as upstream: initramfs restore, EFI BootNext,
   grub2-editenv).
2. `assets/systemd/selinux-autorelabel.service.d/10-azurelinux-desktop.conf`
   — replace `ExecStart` with the helper; journal-only stdio.
3. Plymouth theme (`assets/plymouth/azurelinux/azurelinux.script`) draws
   `display-message` / update-status text under the dots (needs
   `plymouth-plugin-label`, already in the package set).
4. Live/installer asset install paths stage the helper and drop-in:
   `kickstart/azurelinux-desktop-live.ks`, `kiwi/azl-install.ks.in`,
   `kiwi/config.sh`.
5. `azl-growroot` also posts the same Plymouth message when it runs on
   disk images.

## Verification

Nested host-partition QA 2026-08-03 (in-place patch of the installed root,
then re-armed `/.autorelabel`):

- Boot stayed on the Azure Linux Plymouth splash (no fixfiles console wall).
- Helper ran as `selinux-autorelabel.service` ExecStart (`azl-first-boot-`
  in audit).
- `/var/log/azl-first-boot-fixfiles.log` shows a full `fixfiles -T 0 restore`.
- `/.autorelabel` removed; next boot reached GDM (user `azurelinux`).
- Screendumps: `~/azl-work/azl-firstboot-t*.png` (splash → GRUB → GDM).
- First helper revision called `systemctl reboot` from inside the oneshot and
  was SIGTERM'd during reboot (`result=signal` in journal) even though the
  reboot succeeded. Fixed: helper exits 0; drop-in uses `SuccessAction=reboot`.

Release check after rebuild:

- Fresh install first boot: splash stays graphical; status line when label
  plugin can render text; no fixfiles wall; one reboot; second boot GDM.
- `systemctl cat selinux-autorelabel.service` shows the drop-in ExecStart.

## References

- `assets/bin/azl-first-boot-prepare`
- `assets/systemd/selinux-autorelabel.service.d/10-azurelinux-desktop.conf`
- `findings/plymouth-boot-animation.md`
- Upstream script: `/usr/libexec/selinux/selinux-autorelabel`
