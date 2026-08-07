# Azure kernel USB HID kmod and GitHub Pages repo

**Status:** resolved for HID; broader desktop kmod set documented in `out-of-tree-usb-kmods-pages.md` and `desktop-kmod-waves-1-5.md`

## Context

The Azure Linux x86_64 kernel disables `CONFIG_USB_HID` and weakens mouse support in `base/comps/kernel/6.18-x86_64-azl.config`. QEMU's USB tablet and a normal physical USB mouse both need `usbhid.ko`.

The project builds out-of-tree modules as sibling RPMs and publishes them to a GitHub Pages DNF repo with `azurelinux-desktop-policy` so the kernel and matching modules only update together.

HID package: `azurelinux-desktop-usbhid-kmod`. Storage sibling is now `azurelinux-desktop-storage-kmod` (was `usb-storage-kmod`). Full family list: `out-of-tree-usb-kmods-pages.md`.

## Kernel module build (HID)

Per Azure kernel release:

1. Query Azure Linux package metadata for the newest kernel NEVRA.
2. Install the exact `kernel-devel` in an Azure Linux container.
3. Download matching Azure kernel source; verify SHA-512 against Azure's checksum.
4. Set `CONFIG_USB_HID=m` (and matching module ccflags).
5. Build `drivers/hid/usbhid` as an external module against that release's `.config` and `Module.symvers`.
6. Check vermagic; package with exact `kernel-core-uname-r` Requires.

Azure enables module versioning. An older usbhid RPM cannot load into a newer kernel. Do not force it with `--force` or `modprobe -f`.

## The policy package

`azurelinux-desktop-policy` couples one exact kernel EVR to every sibling kmod RPM from the same publish. With policy installed, a kernel-only update is not a complete transaction. When Pages gains the next full set, DNF can move them together.

USB mass-storage is a sibling RPM, not files stuffed into the usbhid package. HID and storage stay independent while sharing one policy channel and one Pages repo.

## GitHub Pages repository

URL: `https://sirredbeard.github.io/azurelinux-desktop/repo/`

Repo ID in `.repo` files: `azl-desktop-kmods` (low cost).

Layout under `repo/`: policy and kmod RPMs, `manifest.txt`, `repodata/repomd.xml`. Older kernel sets are kept by default so installs that have not moved still resolve. `prune_old=true` on publish drops other-kernel RPMs.

## Publisher workflow

Workflow: `publish-desktop-kmods.yml`. Hybrid schedule (`17 4 * * *` UTC), dispatch, and `workflow_call` from `release.yml`. No push trigger.

* detect: newest kernel NEVRA + manifest completeness for all current families
* prepare: one kernel source fetch
* build-family: matrix of families
* package: RPMs + policy
* publish: merge or prune, GPG sign, createrepo, deploy Pages

Inputs:

* `republish=true` - rebuild even if Pages already has this kernel set
* `prune_old=true` - keep only the current kernel's RPMs on publish
* `families=` - optional subset for debug

Concurrency group `azurelinux-desktop-kmod-repository` serializes Pages writes (`cancel-in-progress: false`).

Permissions needed: `pages: write`, `id-token: write`. Callers through a release wrapper must grant these too. Reusable workflow permissions only stay the same or get narrower.

## Secure Boot

Project-built module, not signed by Azure Linux's kernel key. Works when Secure Boot module enforcement is off. Not a Secure Boot solution.

## How images consume the repo

* Live kickstart and installer offline-repo builder: Pages repo + install `azurelinux-desktop-policy`
* Installer post-install: leaves the same `.repo` on the installed target
* Canary: resolve kernel + policy + kmod siblings (container does not load modules)
* Installed system: last matching set stays bootable; moves forward when the publisher adds the next set

## Early CI bugs (fixed, keep signatures)

* Malformed `kernel-devel--` NEVRA from a query string bug: `No match for argument: kernel-devel--.`
* Malformed URL in a validation curl: `curl: (3) URL rejected: Malformed input to a URL function`

## Virtio input is a VM workaround

Azure ships `virtio_input.ko`. QEMU can use `-device virtio-tablet-pci` for pointer input. Physical USB mice still need usbhid. Shipping without it is not a complete desktop path.

## USB mass-storage sibling

AZL 4.0 x86_64 also leaves `# CONFIG_USB_STORAGE is not set` (and no UAS). That blocks USB-stick boot even when usbhid is present. See `usb-storage-missing-initrd.md`.

`scripts/build-desktop-kmods.sh` builds HID and storage (and the rest of the families) in one pipeline against the same `kernel-devel` / source / vermagic checks.

* usbhid: `usbhid.ko` + dracut `add_drivers+=" usbhid "`
* storage: `usb-storage.ko`, `uas.ko` + dracut `add_drivers+=" usb-storage uas "`

Specialty `ums-*` unusual drivers are not shipped. Stick/UAS boot only needs the core pair.

## Verification

```bash
curl --fail --location \
  https://sirredbeard.github.io/azurelinux-desktop/repo/repodata/repomd.xml
```

Meaningful package check: Azure Linux container with Azure kernel repo + this Pages repo. Install `kernel` and `azurelinux-desktop-policy`, then verify `usbhid.ko` path and vermagic. `scripts/test-canary-container.sh` does the same class of checks in the published canary.

## References

* `out-of-tree-usb-kmods-pages.md` - full pipeline and family list
* `usb-storage-missing-initrd.md` - stick boot
* `live-iso-installer-parity.md` - parity matrix
* `canary-container.md` - canary transaction check
* Azure config: `microsoft/azurelinux` `base/comps/kernel/6.18-x86_64-azl.config`
