# Installer admin shell is PowerShell

**Status:** Resolved

## Problem

The admin account from the installer used `/bin/bash` instead of
`/usr/bin/pwsh`.

## Cause

`kiwi/anaconda-launcher.sh` wrote the kickstart `user` line without
`--shell=`. Anaconda then ran `useradd` with no `-s`, so the system
default from `/etc/default/useradd` (`/bin/bash`) won.

## Notes

* pykickstart has supported `user --shell` for a long time.
* Anaconda maps it to `useradd -s`.
* `useradd` does not read `/etc/shells`. `chsh` and `pam_shells` do.
* GDM and the GNOME session do not depend on the login shell.
  `gnome-terminal` does use the passwd shell.
* TTY login checks `/etc/shells`. Installer `%post` already adds
  `/usr/bin/pwsh` there and sets root's shell.

## Fix

Inject `--shell=/usr/bin/pwsh` in `write_kickstart_with_admin_user`:

```bash
printf 'user --name=%s --groups=wheel --password=%s --iscrypted --shell=/usr/bin/pwsh\n' \
    "$ADMIN_USER" "$ADMIN_PASSWORD_HASH" > "$account_directive"
```

A post-install `usermod --shell` on wheel users is a documented fallback
only. Not required.

## Left alone

* GDM/GNOME session path
* Recovery and emergency targets (still bash/sh)
* `/etc/shells` handling in `azl-install.ks.in`

## Paths

* `kiwi/anaconda-launcher.sh`
* `kiwi/azl-install.ks.in`
* `gnome-desktop-defaults.md`
