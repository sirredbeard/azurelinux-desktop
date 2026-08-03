# Anaconda: `No match for argument: nvme-cli` on offline installer

**Status:** fixed in tree (needs installer ISO rebuild)

## Symptom

During offline installer software install on an NVMe-backed target, Anaconda
stopped in the TUI with:

```text
An unknown error has occurred, look at the /tmp/anaconda-tb* file(s)
...
pyanaconda.modules.common.errors.installation.NonCriticalInstallationError:
No match for argument: nvme-cli
```

Seen while re-testing the 2026.08.02 installer ISO in QEMU with only the host
container partition attached as a guest NVMe disk (nested dual-boot path).
Partitioning finished; failure was at "Installing the software".

## Root cause

1. **Blivet** tags NVMe disks with a hard-coded package list:
   `NVMeNamespaceDevice._packages = ["nvme-cli"]`
   (upstream `blivet/devices/disk.py`).
2. **Anaconda storage** folds `self.storage.packages` into payload
   requirements (`collect_requirements()` → BOSS → DNF resolve).
3. This project's offline ISO builds `/opt/azl-offline-repo` from
   `INSTALL_PKGS` + `EXTRA_REPO_PKGS` in `kiwi/config.sh`. **`nvme-cli` was
   in neither list**, so the offline repo had no match.
4. The kickstart `%packages` list never mentioned `nvme-cli`. Grep of the
   repo for that name was empty before the fix. The requirement is dynamic
   at install time when the install disk is NVMe.

The error class is `NonCriticalInstallationError` (resolver warning path).
In some UIs it may only warn; in this TUI run it blocked with the exception
screen and a Report/Shell/Debug/Quit menu. Treat missing offline packages
that Blivet injects as must-fix for a reliable installer.

## Package availability

- Azure Linux 4.0 publishes **`nvme-cli`** (base/components; also used in
  Microsoft's own VM base image). Same package name as Fedora.
- Prefer AZL via existing repo cost/priority; no Fedora-only package needed.

## Fix

Add `nvme-cli` to `EXTRA_REPO_PKGS` in `kiwi/config.sh` so
`dnf5 download --alldeps` puts it (and deps such as `libnvme`) in the
offline repo. That matches the existing comment on that array: Anaconda
runtime/bootloader-style deps not listed in kickstart `%packages`.

Do **not** paper over this with `ignored_packages = nvme-cli` long term.
NVMe tooling is useful on the installed system when Anaconda pulls it in.

## What this is not

- Not a host dual-boot layout bug. Guest NVMe disk was the container
  partition exposed as a whole disk; size matched the host container slice.
- Not the USB/hid issue (#5). Nested QEMU install used PS/2 (`console=tty0`,
  no serial device) so the TUI was usable without `usbhid`.
- Not a reason to drop NVMe emulation in QEMU. Bare metal on this class of
  laptop is NVMe; the offline repo must satisfy Blivet's NVMe requirement.

## Verification

1. Rebuild installer ISO (release workflow) after the `config.sh` change.
2. Confirm offline repo / package list includes `nvme-cli` (and ideally
   `libnvme`).
3. Re-run offline install to an NVMe target (QEMU NVMe backend or bare
   metal). Package resolve should not raise `No match for argument: nvme-cli`.

## Related

- `kiwi/config.sh` — `EXTRA_REPO_PKGS`
- `findings/kiwi-ng-installer-build.md` — offline repo construction
- `findings/dual-boot-nested-host-partition.md` — nested p4 QEMU install path
- `findings/usb-storage-missing-initrd.md` / issue #5 — separate input stack gap
