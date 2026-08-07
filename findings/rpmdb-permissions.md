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

## Product action (all three deliverables)

Same fix everywhere package installs finish — **not** installer-only:

| Artifact | Where |
| --- | --- |
| Live ISO / live disk / VMs from live | `kickstart/azurelinux-desktop-live.ks` chroot `%post` (near sudoers drop-in) |
| Installer ISO → installed OS | `kiwi/azl-install.ks.in` `%post` (same block) |
| Canary OCI | `scripts/build-canary-container.sh` after dnf into installroot; test checks mode |

```sh
chmod a+r /usr/lib/sysimage/rpm/rpmdb.sqlite \
  /usr/lib/sysimage/rpm/rpmdb.sqlite-shm \
  /usr/lib/sysimage/rpm/rpmdb.sqlite-wal 2>/dev/null || true
```

### Does installer need it?

**Yes.** Metal host was an installed image with `0600`; that is the
installer (or older live→disk) path. Restoring world-read on the
**installed target** is required so the desktop user can `rpm -q`
without sudo.

### Does it apply back to live ISO?

**Yes.** Live session users and agents hit the same sqlite DB under the
live root. Live `%post` runs the same `chmod` so the squash/erofs root
ships `0644`. VMs built from live inherit it.

### Should canary get it?

**Yes, for testing parity.** Canary tests run `rpm -q` inside the
image. Host-side `rpm --root=` as root would work either way, but
in-image non-root query and mode asserts catch regressions. Canary
build chmods the installroot DB; `test-canary-container.sh` fails if
`rpmdb.sqlite` is not world-readable.

Owner stays **root**. Never chown the DB to the desktop user.

## Agent guidance

Prefer `sudo rpm -qa` when mode is unknown. After a normal image with
the post-install fix, plain `rpm -q` as the desktop user should work.
