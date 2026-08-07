# Anaconda: No match for argument nvme-cli on offline installer

**Status:** Fixed in tree (needs installer ISO rebuild)

## Symptom

During offline install on an NVMe target, Anaconda stopped in the TUI:

```text
An unknown error has occurred, look at the /tmp/anaconda-tb* file(s)
...
pyanaconda.modules.common.errors.installation.NonCriticalInstallationError:
No match for argument: nvme-cli
```

Seen re-testing the 2026.08.02 installer ISO in QEMU with the host
container partition attached as guest NVMe. Partitioning finished.
Failure was at "Installing the software".

## Cause

1. Blivet tags NVMe disks with a hard-coded package list:
   `NVMeNamespaceDevice._packages = ["nvme-cli"]`
   (upstream `blivet/devices/disk.py`).
2. Anaconda storage folds `self.storage.packages` into payload
   requirements.
3. This project's offline ISO builds `/opt/azl-offline-repo` from
   `INSTALL_PKGS` + `EXTRA_REPO_PKGS` in `kiwi/config.sh`. `nvme-cli`
   was in neither list, so the offline repo had no match.
4. Kickstart `%packages` never listed `nvme-cli`. The requirement is
   dynamic at install time when the install disk is NVMe.

The error class is `NonCriticalInstallationError`. In this TUI run it
blocked with Report/Shell/Debug/Quit. Treat missing offline packages
that Blivet injects as must-fix.

## Package source

Azure Linux 4.0 publishes `nvme-cli` (same name as Fedora). Prefer AZL
via existing repo cost/priority. No Fedora-only package needed.

## Fix

Add `nvme-cli` to `EXTRA_REPO_PKGS` in `kiwi/config.sh` so
`dnf5 download --alldeps` puts it (and deps such as `libnvme`) in the
offline repo. That matches the comment on that array: Anaconda support
deps not listed in kickstart `%packages`.

Do not paper over this with `ignored_packages = nvme-cli` long term.
NVMe tooling is useful on the installed system when Anaconda pulls it.

## What this is not

* Not a host dual-boot layout bug.
* Not the USB/hid input stack gap.
* Not a reason to drop NVMe emulation in QEMU. Bare metal on this class
  of laptop is NVMe; the offline repo must satisfy Blivet.

## Verification

1. Rebuild installer ISO after the `config.sh` change.
2. Confirm offline repo includes `nvme-cli` (and ideally `libnvme`).
3. Re-run offline install to an NVMe target. Package resolve should not
   raise `No match for argument: nvme-cli`.

## Related

* `kiwi/config.sh` (`EXTRA_REPO_PKGS`)
* `kiwi-ng-installer-build.md`
* `dual-boot-nested-host-partition.md`
* `usb-storage-missing-initrd.md`
