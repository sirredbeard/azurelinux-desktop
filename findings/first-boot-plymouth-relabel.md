# First-boot SELinux relabel covered by Plymouth

**Status:** Fix in tree (reboot drop-in + theme). Nested install patched
in place for local QA 2026-08-04. Needs installer/live rebuild so release
artifacts ship the corrected drop-in and theme.

## Original problem

First boot of a fresh installed system (installer ISO path touches
`/.autorelabel` in `kiwi/post-install.sh`) dropped to a black console and
printed stock SELinux autorelabel text:

```
*** Warning -- SELinux targeted policy relabel is required.
*** Relabeling could take a very long time...
Running: /sbin/fixfiles -T 0 restore
```

Then it reboots again. Disk-image first boot has a similar "extra work
then continue" feel when `azl-growroot` runs after `qemu-img resize`.

## Cause (console wall)

`/usr/libexec/selinux/selinux-autorelabel` does:

```bash
[ -x /bin/plymouth ] && plymouth --quit
```

then echoes the warnings to the console (`StandardOutput=journal+console`
on `selinux-autorelabel.service`). Plymouth was running under
`rhgb quiet`; the script tears it down on purpose.

## Nested QA 2026-08-04: hung after relabel

Fresh nested install from installer ISO. Host saw:

* Splash unit-name spam, brief expanding-disk text, then stuck on
  `selinux-autorelabel.service` for many minutes.
* Serial log useless (no `console=ttyS0` by design; only UEFI BdsDxe).
* Host `nvme0n1p4` I/O idle for 45s+ while splash still showed that unit
  name. Not a slow `fixfiles`.

Journal on nested root (`~/azl-work/azl-boot-logs-2026-08-04`):

```
Unknown key 'SuccessAction' in section [Service], ignoring.
Starting selinux-autorelabel.service ...
# azl-first-boot-prepare / fixfiles ~42s
Finished selinux-autorelabel.service
Reached target selinux-autorelabel.target
Startup finished ... = 53.922s
# no reboot; journal ends
```

`/var/log/azl-first-boot-fixfiles.log` completed cleanly. No grow log
(nested disk already fully partitioned).

### Why reboot never happened

1. Drop-in put `SuccessAction=reboot` under `[Service]`. That key is a
   `[Unit]` setting. Systemd ignored it.
2. Stock `selinux-autorelabel.service` has `RemainAfterExit=yes`. After
   a clean oneshot exit the unit stays active, so even a correct
   `SuccessAction` would not run (it fires on transition to
   inactive/failed).
3. Helper correctly exits 0 and does not call `systemctl reboot` (an
   earlier revision that rebooted from inside the oneshot was SIGTERM'd
   and marked `result=signal`). Without a working `SuccessAction`, boot
   stopped at `selinux-autorelabel.target` with Plymouth still up.

### Why unit names showed under the logo

Installer image still shipped a theme that hooked
`Plymouth.SetUpdateStatusFunction` into the same text line as
`display-message`. Systemd feeds every unit name through update-status,
so the splash painted `selinux-autorelabel.service` (and earlier boot
units) over the intentional first-boot line. Repo theme must not set
`SetUpdateStatusFunction`; only `SetMessageFunction` for deliberate
`plymouth display-message` text. Helper must not call
`plymouth update --status`.

## Fix

1. `assets/bin/azl-first-boot-prepare` keeps splash up, one
   `display-message` only:
   "Finishing setup and expanding disk. System will reboot."
   Grow root when tools allow; `fixfiles` quietly to
   `/var/log/azl-first-boot-fixfiles.log`; exit 0 (no in-helper reboot).
2. `assets/systemd/selinux-autorelabel.service.d/10-azurelinux-desktop.conf`
   sets `ExecStart` to the helper; journal-only stdio;
   `[Unit] SuccessAction=reboot`; `RemainAfterExit=no`.
3. Plymouth theme uses `SetMessageFunction` only (no update-status hook).
   `plymouth-plugin-label` is already in the package set.
4. Live/installer asset paths stage helper + drop-in + theme:
   `kickstart/azurelinux-desktop-live.ks`, `kiwi/azl-install.ks.in`,
   `kiwi/config.sh`.
5. `azl-growroot` posts the same Plymouth message on disk images.

## Verification

Nested host-partition QA 2026-08-03 (in-place patch, re-armed
`/.autorelabel`): splash stayed graphical; fixfiles log complete; next
boot GDM.

Nested 2026-08-04 inspect: root cause above; drop-in + theme patched on
nested root for retest (re-arm `/.autorelabel` to exercise full path).

Release check after rebuild:

* Fresh install first boot: animation only until the expanding-disk
  message; that message stays through grow/relabel; automatic reboot;
  second boot GDM. No unit-name spam, no fixfiles console wall.
* `systemctl cat selinux-autorelabel.service` shows `[Unit] SuccessAction`
  and `RemainAfterExit=no`.
* Journal must not contain `Unknown key 'SuccessAction'`.

## Paths

* `assets/bin/azl-first-boot-prepare`
* `assets/systemd/selinux-autorelabel.service.d/10-azurelinux-desktop.conf`
* `assets/plymouth/azurelinux/azurelinux.script`
* `plymouth-boot-animation.md`
* Upstream script: `/usr/libexec/selinux/selinux-autorelabel`
* Logs: `~/azl-work/azl-boot-logs-2026-08-04/`
