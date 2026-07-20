# Test suite implementation - what landed and why

Implementation of `findings/test-suite-research.md`. The research
settled the intent (openQA-style boot/update/app checks, Alma-style
in-guest execution, Rocky-style Flathub smoke test); this file is the
concrete shape.

## What landed

- `scripts/test-container-repos.sh` - fast podman repo-origin assertions,
  with `repo --name=...` lines parsed from the live kickstart at runtime
  by `scripts/test-repo-common.sh`.
- `scripts/test-boot-smoke.sh` - headless QEMU/OVMF smoke boot (serial
  log, pure TCG, no KVM assumption).
- `scripts/render-test-kickstart.sh` - generates a test-only disk-image
  kickstart from the shared live kickstart.
- `scripts/test-in-guest-checks.sh` - runs inside the test image on
  first boot as a oneshot systemd unit.
- `scripts/test-post-boot-checks.sh` - host-side wrapper, waits for
  `AZL_TEST_RESULT PASS`/`FAIL` over serial console.
- `.github/workflows/test-images.yml` - manual workflow: fast container
  check, then test qcow2 build, then boot-smoke and post-boot checks.

## Why a test-only systemd unit, not serial-console typing

The live/session path is graphical autologin with PowerShell as default
shell, and GitHub-hosted runners only get TCG emulation. A oneshot unit
in an otherwise identical test image is simpler and more deterministic.

## The repo-origin check

The research proposed `dnf repoquery --installed --qf '%{name}
%{repoid}'`, but installed packages report `repoid` as `@System`. The
implemented check uses two signals:

- **Release tag** (`rpm -q --qf '%{release}'`): `*.azl4*` vs Fedora.
- **Current winning repo** (`dnf repoquery --available`): confirms
  configured repos still resolve from the expected side today.

## Scope choices

Manual-only (`workflow_dispatch`) for now. Builds a dedicated test
qcow2, not the release artifact - the extra guest-check unit shouldn't
ship in release images. The variant is rendered from the shared
kickstart (one source of truth).

## Two real bugs in the oneshot test unit, both hit only via real CI boots

Neither of these showed up until the guest was actually booted end to
end in CI - static kickstart review and `bash -n`/shellcheck passes on
the scripts caught neither.

**Unit ordering blocked on network-online.target.** The unit was
originally `After=network-online.target gdm.service`. QEMU's usermode
networking never satisfies `NetworkManager-wait-online.service` cleanly
under TCG, so the unit sat queued behind `network-online.target` for
the guest's entire life - the guest booted fully to a login prompt, but
the unit itself never even attempted to start, and the 40-minute host-
side wait timed out with nothing in the serial log at all (no `AZL_TEST:`
markers, no journal output, nothing). Fix: dropped the network and gdm
ordering entirely, moved the unit to `WantedBy=multi-user.target`, and
put the retry logic where it belongs - inside
`scripts/test-in-guest-checks.sh` itself (`wait_for_repo_access`,
`wait_for_gdm`), which already needed to tolerate a slow dnf mirror
regardless.

**`%post` has no access to /workspace.** After the ordering fix, the
unit started failing immediately (`[FAILED] Failed to start
azl-image-test.service`, with zero output before it - because the
script's own `log()`/`fail()` helpers are defined after a
`source /usr/local/lib/azl-test-repo-common.sh` line, and `set -euo
pipefail` exits before either helper exists if that file is missing).
Mounting the built qcow2's root partition directly with `qemu-nbd`
confirmed why: `/usr/local/sbin/azl-image-test` and
`/usr/local/lib/azl-test-repo-common.sh` were never created, only the
systemd unit file was. The test-suite's own post-install log
(`/var/log/azl-desktop-test-suite-post.log`) had the exact answer -
`install: cannot stat '/workspace/scripts/test-in-guest-checks.sh': No
such file or directory`. `render-test-kickstart.sh` had appended a
regular (chrooted) `%post` block that reads straight from `/workspace`,
but regular `%post` runs inside anaconda's chroot, where `/workspace`
(the build container's own repo checkout) isn't mounted at all - only
`%post --nochroot` can see it. The main live kickstart already solved
this exact problem for its icon/Plymouth-theme assets (copy from
`/workspace` to `/mnt/sysimage/...` in a `--nochroot` block first, then
a regular `%post` picks the files up from inside the chroot);
`render-test-kickstart.sh` just hadn't followed that same pattern for
the two test scripts. Fixed by splitting the appended block into a
`%post --nochroot` copy step followed by the regular `%post` that
writes the unit file and enables it.

**Debugging note for next time**: when a systemd unit fails
"instantly," with no application-level log output at all, suspect the
`ExecStart` binary/library not existing or not being executable before
suspecting the script's own logic - `systemctl status
<unit>`/`journalctl -u <unit>` (or, without guest access, mounting the
disk image directly via `qemu-nbd` and checking the files landed where
the kickstart expected) settles it in seconds, versus much longer spent
re-reading application code that never got a chance to run.
