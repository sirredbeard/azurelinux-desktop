# Installer-created administrator defaults to Bash

**Status:** Resolved

## Observed failure

The administrator account created by the installer interactive flow had
`/bin/bash` as its login shell instead of PowerShell (`/usr/bin/pwsh`).

## Root cause

`kiwi/anaconda-launcher.sh` function `write_kickstart_with_admin_user`
generated:

```bash
printf 'user --name=%s --groups=wheel --password=%s --iscrypted\n' \
    "$ADMIN_USER" "$ADMIN_PASSWORD_HASH" > "$account_directive"
```

No `--shell=` option. Anaconda therefore called `useradd` without `-s`, so
the system default from `/etc/default/useradd` (`/bin/bash`) won.

## Research notes (verified in upstream source)

- `pykickstart` has supported `user --shell` since Fedora Core 6
  (`pykickstart/commands/user.py`, SHA `4d09a47`).
- Anaconda applies it as `useradd -s <shell>`
  (`rhinstaller/anaconda` `pyanaconda/core/users.py`).
- `useradd` does **not** consult `/etc/shells`. `chsh` and `pam_shells` do.
- GDM graphical login does not use `pam_shells`. GNOME session startup does
  not depend on the login shell. `gnome-terminal` does use `/etc/passwd`
  shell for interactive terminals.
- TTY `login` does check `/etc/shells`. The installer kickstart `%post`
  already appends `/usr/bin/pwsh` to `/etc/shells` and sets root's shell.
- PowerShell 7.x documents `pwsh` as a valid login shell when listed in
  `/etc/shells` (`PowerShell/PowerShell` manpage SHA `98320cc`).

## Resolution

Option A (shipped): inject `--shell=/usr/bin/pwsh` in
`kiwi/anaconda-launcher.sh`:

```bash
printf 'user --name=%s --groups=wheel --password=%s --iscrypted --shell=/usr/bin/pwsh\n' \
    "$ADMIN_USER" "$ADMIN_PASSWORD_HASH" > "$account_directive"
```

Option B (not required): post-process wheel users with `usermod --shell` in
`post-install.sh`. Kept as a documented fallback only.

## What did not need changing

- GDM/GNOME session path: unaffected by login shell.
- Recovery/emergency targets: still use `/bin/bash` or `/bin/sh` directly.
- `/etc/shells` handling: already present in `azl-install.ks.in` `%post`.

## Gaps noted at research time

- GNOME Keyring PAM with a non-bash login shell should be re-checked on a
  fresh installed session (autologin + `pam_gnome_keyring` path). Expected
  fine; was listed as a test item, not a known break.

## References

- `kiwi/anaconda-launcher.sh`
- `kiwi/azl-install.ks.in` (`/etc/shells` + root `usermod`)
- `gnome-desktop-defaults.md` (GDM/autologin context)
