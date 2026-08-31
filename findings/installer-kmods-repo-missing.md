# Installer target missing azl-desktop-kmods.repo

**Status:** Root cause fixed in tree. Needs a new installer ISO to land on
metal. Live kickstart already persisted the repo; installer chroot `%post`
did not.

## Symptom (ThinkPad metal install, 2026-08-31)

Bare-metal install from the installer ISO:

- Desktop kmod RPMs were present and loaded (`iwlwifi`, `btusb`,
  `thinkpad_acpi`, `usbhid`, …).
- `/etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop` was present.
- `/etc/yum.repos.d/` had fedora, Microsoft/GitHub, and RPM Fusion project
  repos, but **no** `azl-desktop-kmods.repo`.
- `dnf repolist` had no Pages kmod source, so a later kernel bump could not
  pull matching sibling kmods from
  `https://sirredbeard.github.io/azurelinux-desktop/repo/`.

## Evidence

`/var/log/anaconda-post.log` (early `post-install.sh` chroot):

```text
+ install -m 0644 /opt/azl-desktop-assets/yum.repos.d/azl-desktop-kmods.repo /etc/yum.repos.d/azl-desktop-kmods.repo
install: cannot stat '/opt/azl-desktop-assets/yum.repos.d/azl-desktop-kmods.repo': No such file or directory
```

`/var/log/azl-desktop-post.log` (later chroot `%post` with
`ASSETS=/root/assets`):

```text
+ install -m 0644 /root/assets/yum.repos.d/azl-desktop-fedora.repo /etc/yum.repos.d/azl-desktop-fedora.repo
+ install -m 0644 /root/assets/yum.repos.d/azl-desktop-microsoft-github.repo /etc/yum.repos.d/azl-desktop-microsoft-github.repo
+ install -m 0644 /root/assets/yum.repos.d/azl-desktop-rpmfusion.repo /etc/yum.repos.d/azl-desktop-rpmfusion.repo
```

No `azl-desktop-kmods.repo` install line in that log.

## Root cause

1. `kiwi/post-install.sh` runs first via `%post --nochroot` +
   `chroot /mnt/sysroot`. It looked for
   `/opt/azl-desktop-assets/yum.repos.d/azl-desktop-kmods.repo`. That path
   exists on the **installer live root**, not inside the target chroot.
   Same class of bug as `findings/rpm-gpg-keys-on-target.md`.
2. The real repo-persist path is the later chroot `%post` in
   `kiwi/azl-install.ks.in`, which already installs fedora / Microsoft /
   RPM Fusion from staged `/root/assets`. It never installed
   `azl-desktop-kmods.repo`.
3. Live media (`kickstart/azurelinux-desktop-live.ks`) already did the
   right `install -m 0644 .../azl-desktop-kmods.repo`. Installer parity
   gap only.

## Fix

- Persist `azl-desktop-kmods.repo` in `kiwi/azl-install.ks.in` next to the
  other project repos, fail closed if the file is missing after install.
- Stop attempting the kmods repo install from `kiwi/post-install.sh`
  (wrong path, wrong phase).

## Manual recovery on an already-installed host

```bash
sudo install -m 0644 assets/yum.repos.d/azl-desktop-kmods.repo \
  /etc/yum.repos.d/azl-desktop-kmods.repo
sudo dnf clean all
sudo dnf repolist | grep azl-desktop-kmods
```

## Verify after next installer ISO

On a fresh install or mounted installroot:

```bash
test -s /etc/yum.repos.d/azl-desktop-kmods.repo
grep -F 'sirredbeard.github.io/azurelinux-desktop/repo' \
  /etc/yum.repos.d/azl-desktop-kmods.repo
dnf repolist | grep azl-desktop-kmods
```
