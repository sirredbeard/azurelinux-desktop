# RPM GPG keys missing on installed systems

**Status:** Root cause fixed. Installer nochroot now copies
`assets/pki/rpm-gpg` onto the target `/etc/pki/rpm-gpg`. Live and
installer posts fail closed if a required key file is absent.

## Symptom (this metal host)

Repos under `/etc/yum.repos.d` use `gpgcheck=1` and
`gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-…`, but several key files
were missing:

- `RPM-GPG-KEY-fedora-43-primary` (fedora43 / updates)
- `RPM-GPG-KEY-rpmfusion-*-fedora-2020` (rpmfusion free/nonfree)
- `RPM-GPG-KEY-microsoft` (Edge, VS Code, ms-prod)
- `RPM-GPG-KEY-githubcli` (gh-cli)
- `RPM-GPG-KEY-shiftkey-desktop` (github-desktop)

Effect: `dnf install` failed with "cannot open file … RPM-GPG-KEY-…"
(or skipped OpenPGP checks). Manual copy from `assets/pki/rpm-gpg`
unblocked metal.

AZL primary keys from `azurelinux-repos` were present; third-party keys
were not.

## Root cause (installer path)

`kiwi/azl-install.ks.in` chroot `%post` did:

```sh
if [ -d /opt/azl-desktop-assets/pki/rpm-gpg ]; then
    cp -a /opt/azl-desktop-assets/pki/rpm-gpg/. /etc/pki/rpm-gpg/
fi
```

`/opt/azl-desktop-assets` exists on the installer ISO root (kiwi
`assets.tar.gz`), not on the installed system. The chroot runs inside
`/mnt/sysroot`. The `--nochroot` block never copied the key tree onto
the target, so the `if` was always false after install.

Import loop used `if [ -e key ]; then import; fi` with no failure.
Silent gap.

## Live ISO / live disk path

`%post --nochroot` runs on the build host and can read `/workspace`.
The chrooted `%post` under livemedia-creator `--no-virt` cannot. An
early fail-closed key check that only looked under `/workspace/assets`
exited 1 before dconf, iHD link, growroot, polkit, and the rest of
chrooted `%post` ran. Disk build log signature (run 31160972564):

```
error: required RPM GPG key missing after asset stage: RPM-GPG-KEY-azurelinux-desktop
exit 1
ERROR:anaconda... Error code 1 running the kickstart script at line 110
```

Fix: nochroot copies the full `assets/` tree to `/mnt/sysimage/root/assets`,
chrooted `%post` sets `ASSETS=/root/assets` and installs from there, then
removes `/root/assets`. Fail-closed key list is unchanged.

Live to disk VMs inherit the live root's `/etc/pki/rpm-gpg` when the
live build staged keys correctly.

## Fix

1. Installer `--nochroot`: copy every `RPM-GPG-KEY-*` (and AZL relative
   symlinks; skip `*.md`) from `/opt/azl-desktop-assets/pki/rpm-gpg`
   to `/mnt/sysroot/etc/pki/rpm-gpg`. Also copy the full assets tree to
   `/mnt/sysroot/root/assets` so chrooted `%post` can install repos,
   dconf, polkit, growroot, and the rest without `/opt` (ISO-only).
2. Installer chroot `%post`: `ASSETS=/root/assets`; require all eight
   material keys; fail install if any missing; then `rpm --import`.
   Remove `/root/assets` at end of post.
3. Live: nochroot copies `/workspace/assets` to `/root/assets`; chroot
   uses `ASSETS=/root/assets`; fail-closed key list; remove tree at end.
4. kiwi `config.sh` (installer ISO itself): symlink-safe key stage +
   fail-closed require list; static LIBVA `environment.d` asset.
5. Canary Dockerfile: same key COPY + `AZL_DESKTOP_ASSETS` for iHD link.
6. Helper: `scripts/install-rpm-gpg-keys.sh` remains the shared
   implementation for canary and manual repair.

Required key basenames:

```
RPM-GPG-KEY-azurelinux-4.0-primary
RPM-GPG-KEY-azurelinux-desktop
RPM-GPG-KEY-fedora-43-primary
RPM-GPG-KEY-microsoft
RPM-GPG-KEY-githubcli
RPM-GPG-KEY-shiftkey-desktop
RPM-GPG-KEY-rpmfusion-free-fedora-2020
RPM-GPG-KEY-rpmfusion-nonfree-fedora-2020
```

## Metal repair

```sh
sudo ./scripts/install-rpm-gpg-keys.sh /
```

## Related

- `rpm-gpgcheck-vendor-keys.md`: why gpgcheck=1
- `assets/pki/rpm-gpg/README.md`: vendored key set
- `h264-intel-media-stack.md`: needed RPM Fusion keys for media driver
