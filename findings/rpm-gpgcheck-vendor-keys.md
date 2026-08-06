# RPM OpenPGP checks for mixed vendor repos

**Status:** product path updated (live kickstart, installer target
repos, canary build, shared key installer). Needs a full image rebuild
to confirm the GNOME Software / `dnf` UI no longer shows "skipped
OpenPGP checks" for Fedora.

## Symptom

On a live session (2026-08-05), Software / dnf reported skipped OpenPGP
checks for `fedora43` and `fedora43-updates`. Root cause was not
missing Fedora trust in the host sense — the image **wrote** those
repos with `gpgcheck=0` on purpose from early mix days.

## Fix

1. Vendor keys under `assets/pki/rpm-gpg/` (Azure Linux 4.0 primary +
   arch symlinks, Fedora 43 primary, Microsoft, GitHub CLI, shiftkey
   Desktop, RPM Fusion free/nonfree 2020, project desktop kmods).
2. `scripts/install-rpm-gpg-keys.sh` stages and `rpm --import`s them.
3. Live `%post`, installer `kiwi/azl-install.ks.in` + `kiwi/config.sh`,
   and canary `build-canary-container.sh` set `gpgcheck=1` and
   `gpgkey=file:///etc/pki/rpm-gpg/...` for every third-party repo.
4. Preflight helpers (`test-repo-common.sh`,
   `test-installer-runtime-resolve.sh`, `podman-test-azl4-fedora.sh`)
   match the same policy.

## Local proof (2026-08-05)

```text
# installroot + vendored Fedora key, gpgcheck=1
dnf5 ... install --downloadonly tree
Complete!
# second pass / guest agents:
# no "skipped OpenPGP" line
```

Guest agent set also resolved with gpgcheck=1 (spice-vdagent,
qemu-guest-agent, hyperv-daemons, open-vm-tools,
open-vm-tools-desktop, virtualbox-guest-additions).

## Canary CI fail (run 31059375276 / 31061690060)

```text
cannot open file: (2) - No such file or directory [/etc/pki/rpm-gpg/RPM-GPG-KEY-shiftkey-desktop]
```

Keys were only under the installroot (`/mnt/azl/etc/pki/rpm-gpg`).
`dnf5 --installroot` still opens `gpgkey=file:///etc/pki/rpm-gpg/...`
on the **build host**. Fix: stage keys from `assets/pki/rpm-gpg` onto
the Fedora builder host path before the install transaction
(`scripts/build-canary-container.sh`). Same pattern for
`podman-test-azl4-fedora.sh`.

## Canary CI fail (run 31062231476 on f52affb)

Host path fixed; import of packagecloud key `BA3C3A2C` succeeded, then:

```text
OpenPGP check for package "github-desktop-..." has failed: Import of the key didn't help, wrong key?
```

mwt mirror RPMs are signed with Brendan Forster
`4E02A356A18314B00A481F067FC979028B1997C1` (`https://mirror.mwt.me/shiftkey-desktop/gpgkey`),
not the older packagecloud key alone. Vendored
`RPM-GPG-KEY-shiftkey-desktop` now carries **both** armored keys.

## Intentional exception

`scripts/build-desktop-kmods.sh` still uses
`--setopt=azl-base.gpgcheck=0` only when bootstrapping `kernel-devel`
inside the AZL build container via `--repofrompath`. That path is not
a product image repo file.

## Related

- `findings/gpg-key-rotation.md` — project signing key secrets
- `assets/pki/rpm-gpg/README.md` — key inventory
