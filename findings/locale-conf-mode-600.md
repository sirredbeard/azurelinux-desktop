# `/etc/locale.conf` mode 600 breaks bash startup

**Status:** Fixed in image paths. Confirmed on nested install / QEMU guest.

## Observed

Default shell is PowerShell. Typing `bash` prints:

```text
/usr/bin/sed: can't read /etc/locale.conf: Permission denied
```

Same line appears from `gdm-wayland-session` in the journal.

## Root cause

`/etc/locale.conf` was installed as `root:root` mode **600**.

Fedora's `/etc/profile.d/lang.sh` (sourced for interactive bash) does:

```bash
eval $(/usr/bin/sed ... /etc/locale.conf)
```

Unprivileged users cannot read mode 600, so `sed` fails. Harmless but noisy;
locale vars may also stay wrong for the session.

Likely origin: Anaconda/`localed` write under a tight umask during install
(same class of problem as mode-600 desktop files from umask 077).

Host Fedora keeps `locale.conf` at **644** / `locale_t`.

## Fix

In live, disk, and installer kickstart `%post`:

```bash
if [ -f /etc/locale.conf ]; then
    chmod 644 /etc/locale.conf || true
fi
```

Also applied live in the QEMU snapshot session for verification
(`bash -lc` then prints no sed error).

## Related

* Asset staging note: always `install -m` for kickstart copies (umask 077)
* Default shell is `pwsh`; users often switch to `bash` for gather scripts
