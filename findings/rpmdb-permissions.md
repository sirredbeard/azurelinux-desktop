# RPM database ownership and mode

**Status:** Root ownership is correct. Mode `0600` on metal was wrong
relative to the `rpm` package ghost files (`0644`) and blocked non-root
`rpm -q`. Restored to world-readable on metal; image `%post` now
re-applies `a+r` after install.

## What the inventory said

Bare-metal inventory noted the RPM DB under `/usr/lib/sysimage/rpm` as
root-only, so agents used `pkexec`/`sudo rpm -qa`. That was accurate for
this host at the time (`rpmdb.sqlite` mode `0600`).

## What is correct

- Owner: `root:root` (system package DB; only root installs)
- Directory: `/usr/lib/sysimage/rpm` (rpm 4.16+ / rpm 6)
- File mode (package ghosts): `0644` on `rpmdb.sqlite*`
- Directory mode: `0755`

Non-root users should be able to query (`rpm -qa`, `rpm -q`) but not
modify. Writes still need root/`dnf`.

## What we saw on metal

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

Package metadata still claims ghost mode `0644`. Do not change
ownership to the desktop user. Do not treat root ownership as a bug.
Optionally restore world-read if something tightens mode to `0600`
(image build umask / sqlite recreate).

## Product action (all three deliverables)

Same fix everywhere package installs finish:

- Live ISO / live disk / VMs from live:
  `kickstart/azurelinux-desktop-live.ks` chroot `%post`
- Installer ISO to installed OS: `kiwi/azl-install.ks.in` `%post`
- Canary OCI: `scripts/build-canary-container.sh` after dnf into
  installroot; test checks mode

```sh
chmod a+r /usr/lib/sysimage/rpm/rpmdb.sqlite \
  /usr/lib/sysimage/rpm/rpmdb.sqlite-shm \
  /usr/lib/sysimage/rpm/rpmdb.sqlite-wal 2>/dev/null || true
```

Installer needs it: metal host was an installed image with `0600`.
Live needs it: live session users hit the same sqlite DB. Canary needs
it for testing parity (`rpm -q` inside the image and mode asserts).

Owner stays root. Never chown the DB to the desktop user.

## Agent guidance

Prefer `sudo rpm -qa` when mode is unknown. After a normal image with
the post-install fix, plain `rpm -q` as the desktop user should work.
