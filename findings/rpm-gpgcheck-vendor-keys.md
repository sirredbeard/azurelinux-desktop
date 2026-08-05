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

## Intentional exception

`scripts/build-desktop-kmods.sh` still uses
`--setopt=azl-base.gpgcheck=0` only when bootstrapping `kernel-devel`
inside the AZL build container via `--repofrompath`. That path is not
a product image repo file.

## Related

- `findings/gpg-key-rotation.md` — project signing key secrets
- `assets/pki/rpm-gpg/README.md` — key inventory
