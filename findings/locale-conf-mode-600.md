# /etc/locale.conf mode 600 breaks bash startup

**Status:** Fixed in image paths. Confirmed on nested install and QEMU.

## Problem

Default shell is PowerShell. Typing `bash` prints:

```text
/usr/bin/sed: can't read /etc/locale.conf: Permission denied
```

Same line can show from `gdm-wayland-session` in the journal.

## Cause

`/etc/locale.conf` was `root:root` mode 600.

Fedora's `/etc/profile.d/lang.sh` (sourced for interactive bash) runs
`sed` on that file. Unprivileged users cannot read mode 600. The error
is noisy; locale vars may also stay wrong.

Likely origin: Anaconda or localed write under a tight umask during
install. Same class of bug as mode-600 desktop files from umask 077.

Host Fedora keeps `locale.conf` at 644.

## Fix

In live, disk, and installer kickstart `%post`:

```bash
if [ -f /etc/locale.conf ]; then
    chmod 644 /etc/locale.conf || true
fi
```

Also applied live in a QEMU snapshot for verification.

## Related

* Always use `install -m` for kickstart asset copies (umask 077)
* Default shell is `pwsh`; users often switch to bash for scripts
