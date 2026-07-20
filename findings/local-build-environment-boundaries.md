# Local build environment boundaries

Local Podman builds are useful for catching package and configuration errors
before a CI run. They are not a requirement to reproduce every property of a
hosted Docker runner. This project should stop local emulation once it has
proved the product change and the remaining failure is attributable to the
host security model.

## KIWI and SELinux labels

The installer build now reaches KIWI's image preparation stage with the
complete offline package transaction, including Flatpak's matching SELinux
module and the required Azure policy utility closure. A loop-backed ext4
build volume also accepts `security.selinux` extended attributes when mounted
into privileged Podman, unlike this host's Podman overlay storage.

The remaining local failure is different:

```text
setfiles: Could not set context for ...smartdnotify: Invalid argument
setfiles: Could not set context for ...smartd_warning.sh: Invalid argument
```

KIWI invokes the target root's `setfiles`, but the host kernel validates each
`security.selinux` attribute against the host's loaded policy. Some target
policy types are not known to that policy, so the write fails even though
KIWI supplies the target policy file. Changing Podman labels or putting the
build tree on an xattr-capable filesystem cannot make the host accept an
unknown target label.

This is a known host-versus-target relabeling boundary. The relevant upstream
references are:

- [SELinux issue 437](https://github.com/SELinuxProject/selinux/issues/437)
- [KIWI issue 2192](https://github.com/OSInside/kiwi/issues/2192)
- [KIWI security troubleshooting](https://osinside.github.io/kiwi/troubleshooting/security.html)
- [KIWI self-contained builds](https://osinside.github.io/kiwi/plugins/self_contained.html)

The hosted build runs in a Docker environment without this host policy
constraint and is the authoritative path for a release-quality,
SELinux-labeled installer ISO. Do not weaken that workflow to accommodate a
local limitation.

## Local validation rule

The local build path may skip KIWI's final build-tree labeling only as a
disposable validation mode, after the package transaction has been proved.
It can validate ISO construction and a QEMU guest installation because the
installer boot path is permissive and the installed target schedules its own
relabel under the target policy. It cannot validate the installer runtime's
final SELinux labels.

Before calling the published artifact complete, boot an installed guest
through its relabel cycle and check:

```text
getenforce
ls -Z /usr/libexec/smartmontools/smartdnotify
journalctl -b | grep -Ei 'relabel|selinux|setfiles'
```

If the local skip itself fails to apply cleanly, do not keep iterating on
tool patching. Use the hosted build, then validate its downloaded artifact in
QEMU.

## Other observed local differences

- Root Podman needs `--cgroups=disabled` on this host because its normal
  device-filter setup fails before the container starts.
- Privileged Podman bind-mounted outputs can be root-owned and require
  ownership repair.
- The build needs `/dev` and privileged access for loop and image operations.
- A temporary ext4 volume is suitable when KIWI needs xattr-capable writable
  storage; Podman overlay storage here is not.
- `dnf5 install --assumeno` is not a success/failure oracle by exit status:
  it exits nonzero after a successful solve because the simulated user
  declined the transaction. Check explicit resolver errors instead.

These are local test-harness facts, not product behavior and not reasons to
change the hosted workflow.
