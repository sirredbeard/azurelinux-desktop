# Test suite

**Status:** Active script index companion

Prior art research and implementation of the automated test suite.

## Prior art that shaped the design

**Fedora openQA (`fedora-qa/os-autoinst-distri-fedora`):** too heavy to
deploy wholesale, but the test intent is the model: boot to Anaconda /
graphical login, update-health with dnf5 locking race retries, and
expected-vs-actual package versions after update (directly what this
project needs for AZL/Fedora repo priority check post-upgrade).

**AlmaLinux `compose-tests`:** best public example of `tmt`/`fmf` from
GitHub Actions. Boots via Vagrant, runs `tmt ... provision --how=local`
inside. Shape to copy: boot the image, run tests inside via SSH/serial.
`tmt`'s virtual provisioner (libvirt/testcloud + KVM) has no working
public example on hosted runners; multiplies boot timeouts without
`/dev/kvm`.

**Rocky openQA fork (`os-autoinst-distri-rocky`):** working
Flatpak/Flathub test (add remote, install `org.gnome.clocks`, confirm
install). Reusable pattern.

**KIWI:** no built-in appliance self-test. Nothing to borrow.

**DNF/repo-priority regression testing:** no ready-made framework
anywhere (DNF5's own test suite has a TODO for priority testing).

## What landed

* `scripts/test-container-repos.sh` - fast podman repo-origin assertions,
  with `repo --name=...` lines parsed from the live kickstart at runtime
  by `scripts/test-repo-common.sh`
* `scripts/test-boot-smoke.sh` - headless QEMU/OVMF smoke boot (serial
  log, pure TCG, no KVM assumption)
* `scripts/render-test-kickstart.sh` - generates a test-only disk-image
  kickstart from the shared live kickstart
* `scripts/test-in-guest-checks.sh` - runs inside the test image on
  first boot as a oneshot systemd unit
* `scripts/test-post-boot-checks.sh` - host-side wrapper, waits for
  `AZL_TEST_RESULT PASS`/`FAIL` over serial console

The former GitHub Actions guest-test workflow was removed. These helpers
are kept for local artifact checks, where QEMU can use normal hardware
acceleration instead of a multi-hour CI emulation run.

## Why a test-only systemd unit, not serial-console typing

The live/session path is graphical autologin with PowerShell as default
shell. A oneshot unit in an otherwise identical test image is simpler and
more deterministic than typing commands through a serial console.

## The repo-origin check

The research proposed
`dnf repoquery --installed --qf '%{name} %{repoid}'`, but installed
packages report `repoid` as `@System`. The implemented check uses two
signals:

* Release tag (`rpm -q --qf '%{release}'`): `*.azl4*` vs Fedora
* Current winning repo (`dnf repoquery --available`): confirms
  configured repos still resolve from the expected side today

## Scope choices

Local-only. Builds a dedicated test qcow2, not the release artifact. The
extra guest-check unit should not ship in release images. The variant is
rendered from the shared kickstart (one source of truth).

## Two real bugs in the oneshot test unit

Neither showed up until the guest was actually booted end to end. Static
kickstart review and `bash -n`/shellcheck passes caught neither.

### Unit ordering blocked on network-online.target

The unit was originally `After=network-online.target gdm.service`.
QEMU's usermode networking never satisfies
`NetworkManager-wait-online.service` cleanly under TCG, so the unit sat
queued behind `network-online.target` for the guest's entire life. The
guest booted fully to a login prompt, but the unit never started, and
the 40-minute host-side wait timed out with nothing in the serial log.

Fix: drop the network and gdm ordering, move the unit to
`WantedBy=multi-user.target`, and put retry logic inside
`scripts/test-in-guest-checks.sh` (`wait_for_repo_access`,
`wait_for_gdm`), which already needed to tolerate a slow dnf mirror.

### %post has no access to /workspace

After the ordering fix, the unit failed immediately with zero output.
The script's `log()`/`fail()` helpers are defined after
`source /usr/local/lib/azl-test-repo-common.sh`, and `set -euo pipefail`
exits before either helper exists if that file is missing.

Mounting the built qcow2 root with `qemu-nbd` confirmed why:
`/usr/local/sbin/azl-image-test` and
`/usr/local/lib/azl-test-repo-common.sh` were never created, only the
systemd unit file was. The test-suite post-install log had:

```
install: cannot stat '/workspace/scripts/test-in-guest-checks.sh': No such file or directory
```

`render-test-kickstart.sh` had appended a regular (chrooted) `%post`
that reads from `/workspace`, but regular `%post` runs inside anaconda's
chroot where `/workspace` is not mounted. Only `%post --nochroot` can
see it. The main live kickstart already solved this for icon/Plymouth
assets (copy from `/workspace` to `/mnt/sysimage/...` in `--nochroot`,
then regular `%post` picks up inside the chroot).
`render-test-kickstart.sh` had not followed that pattern for the two
test scripts.

Fix: split the appended block into a `%post --nochroot` copy step
followed by the regular `%post` that writes the unit file and enables it.

### Debugging note

When a systemd unit fails instantly with no application-level log
output, suspect the `ExecStart` binary or library not existing or not
being executable before suspecting the script's own logic. Mount the
disk image and check the files landed where the kickstart expected.
