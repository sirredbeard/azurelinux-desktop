# RPM database ownership and mode

**Status:** Root ownership is correct. Mode `0600` on this metal host was
wrong relative to the `rpm` package ghost files (`0644`) and blocked
non-root `rpm -q`. Restored to world-readable on metal; image `%post`
now re-applies `a+r` after install.

## What the inventory said

Bare-metal inventory noted the RPM DB under `/usr/lib/sysimage/rpm` as
root-only, so agents used `pkexec`/`sudo rpm -qa`. That was accurate for
**this host at the time** (`rpmdb.sqlite` mode `0600`).

## What is correct

| Property | Expected | Why |
| --- | --- | --- |
| Owner | `root:root` | System package DB; only root installs |
| Directory | `/usr/lib/sysimage/rpm` (rpm 4.16+ / rpm 6) | `%_dbpath` |
| File mode (package ghosts) | `0644` on `rpmdb.sqlite*` | `rpm -q --dump rpm` |
| Directory mode | `0755` | Package lists `40755` |

Non-root users should be able to **query** (`rpm -qa`, `rpm -q`) but not
modify. Writes still need root/`dnf`.

## What we saw on metal (2026-08-06)

```
-rw------- 1 root root … /usr/lib/sysimage/rpm/rpmdb.sqlite   # bad for queries
```

Effect:

```
$ rpm -q rpm
error: Unable to open sqlite database … Operation not permitted
```

`sudo rpm -q` worked. After `chmod a+r` on the sqlite files, user
queries worked. A later `dnf5 swap` left modes at `0644`.

Package metadata still claims:

```
/usr/lib/sysimage/rpm/rpmdb.sqlite  0644 root root  (ghost)
```

So **do not change ownership** to the desktop user. Do **not** treat
root ownership as a bug. Optionally restore world-read if something
tightens mode to `0600` (image build umask / sqlite recreate).

## Product action

Live and installer `%post` (near passwordless sudo drop-in):

```sh
chmod a+r /usr/lib/sysimage/rpm/rpmdb.sqlite* 2>/dev/null || true
```

No installer-only special case beyond that. Canary rootfs queries use
`rpm --root=` from the host and do not depend on in-image world-read.

## Agent guidance

Prefer `sudo rpm -qa` when mode is unknown. After a normal image with
the `%post` fix, plain `rpm -q` as the desktop user should work.
