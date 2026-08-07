# RPM GPG keys missing on installed systems

**Status:** Root cause fixed 2026-08-06. Installer nochroot now copies
`assets/pki/rpm-gpg` onto the target `/etc/pki/rpm-gpg`. Live and
installer posts **fail closed** if a required key file is absent.

## Symptom (this metal host)

Repos under `/etc/yum.repos.d` use `gpgcheck=1` and
`gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-…`, but several key **files**
were missing:

| Key | Needed by |
| --- | --- |
| `RPM-GPG-KEY-fedora-43-primary` | fedora43 / updates |
| `RPM-GPG-KEY-rpmfusion-*-fedora-2020` | rpmfusion free/nonfree |
| `RPM-GPG-KEY-microsoft` | Edge, VS Code, ms-prod |
| `RPM-GPG-KEY-githubcli` | gh-cli |
| `RPM-GPG-KEY-shiftkey-desktop` | github-desktop |

Effect: `dnf install` failed with “cannot open file … RPM-GPG-KEY-…”
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

`/opt/azl-desktop-assets` exists on the **installer ISO** root (kiwi
`assets.tar.gz`), not on the **installed** system. The chroot runs
inside `/mnt/sysroot`. The `--nochroot` block never copied the key tree
onto the target, so the `if` was always false after install and only
whatever Anaconda/azurelinux-repos dropped remained.

Import loop used `if [ -e key ]; then import; fi` with no failure — silent
gap.

## Live ISO path

Live image `%post` copies keys from `/workspace/assets/pki/rpm-gpg`
during the **image build** (host workspace mounted). That path is correct
for live media. Hardened to **exit 1** if any required key is still
missing after the copy (build-time catch).

Live→disk VMs inherit the live root’s `/etc/pki/rpm-gpg` when the live
build staged keys correctly.

## Fix

1. **Installer `--nochroot`:** copy every `RPM-GPG-KEY-*` (and AZL
   relative symlinks; skip `*.md`) from
   `/opt/azl-desktop-assets/pki/rpm-gpg` →
   `/mnt/sysroot/etc/pki/rpm-gpg`.
2. **Installer chroot `%post`:** require all eight material keys; fail
   install if any missing; then `rpm --import`.
3. **Live `%post`:** same fail-closed require list after asset stage.
4. **kiwi `config.sh` (installer ISO itself):** symlink-safe key stage +
   fail-closed require list (so the ISO root used at install time is also
   complete).
5. **Helper:** `scripts/install-rpm-gpg-keys.sh` remains the shared
   implementation for canary and manual repair; packed into installer
   build-helpers.

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

* `rpm-gpgcheck-vendor-keys.md` — why gpgcheck=1
* `assets/pki/rpm-gpg/README.md` — vendored key set
* `h264-intel-media-stack.md` — needed RPM Fusion keys for media driver
