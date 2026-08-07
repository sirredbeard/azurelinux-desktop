# Passwordless sudo for wheel (live + installed)

**Status:** Product default. Live kickstart already had it. Installer
target (`kiwi/azl-install.ks.in`) matched on 2026-08-06. Metal host
confirmed `%wheel ALL=(ALL) NOPASSWD: ALL` via
`/etc/sudoers.d/90-wheel-nopasswd`.

## Why

Live ISO and VM workflows treat the `azurelinux` / wheel user as a
developer desktop account. Agents and humans need non-interactive `sudo`
for package and system work. Installed images from the installer ISO
must match that behavior.

## Where it is set

* `kickstart/azurelinux-desktop-live.ks` `%post` writes
  `/etc/sudoers.d/90-wheel-nopasswd`
* `kiwi/azl-install.ks.in` writes the same on the installed target

Contents:

```
%wheel ALL=(ALL) NOPASSWD: ALL
```

Mode `0440`. Do not commit account passwords.

## Metal note

Bare-metal install from an earlier image needed the drop-in applied by
hand once. New installer builds include it.
