# Azure kernel USB HID kmod and GitHub Pages repo

**Status:** resolved; superseded in scope by out-of-tree-usb-kmods-pages.md and desktop-kmod-waves-1-5.md

## Context

The Azure Linux x86_64 kernel (`6.18.x-azl4`) explicitly disables `CONFIG_USB_HID` and `CONFIG_INPUT_MOUSE` in `base/comps/kernel/6.18-x86_64-azl.config`. QEMU's USB tablet and a normal physical USB mouse both require `usbhid.ko`. The project builds out-of-tree **usbhid** and **usb-storage/uas** modules as separate RPMs (`azurelinux-desktop-usbhid-kmod`, `azurelinux-desktop-usb-storage-kmod`) and publishes them to a GitHub Pages DNF repository with an `azurelinux-desktop-policy` coupling package, so the kernel and matching modules can only update together.

## Kernel module build

Build procedure per Azure kernel release:
1. Query Azure Linux package metadata for the newest kernel NEVRA.
2. Install the exact `kernel-devel` package in an Azure Linux container.
3. Download the matching Azure kernel source; verify its SHA-512 against Azure's published checksum.
4. Set `CONFIG_USB_HID=m` in the kernel config.
5. Build `drivers/hid/usbhid` as an external module against that release's `.config` and `Module.symvers`.
6. Check vermagic; package with an exact `kernel-core-uname-r` `Requires:`.

**Azure enables module versioning.** An older `usbhid` RPM cannot load into a newer kernel. Do not try to force it with `--force` or `modprobe -f`.

## The policy package

`azurelinux-desktop-policy` is a coupling package: each policy RPM requires the exact kernel and **both** kmod RPMs from its own build (`usbhid` and `usb-storage`). With the policy installed, a kernel-only update has no complete transaction and stays out of the update set. When the publisher adds the matching four-package set (kernel + policy + usbhid kmod + usb-storage kmod), DNF can select all of them together. This prevents a gap where the Azure kernel updates but a matching module has not been published yet.

USB mass-storage is a **sibling** RPM, not files stuffed into the usbhid package, so HID and storage can be described and replaced independently while still sharing one policy channel and one Pages repo.

## GitHub Pages repository

**URL:** `https://sirredbeard.github.io/azurelinux-desktop/repo/`

Repo ID in `.repo` files: `azl-desktop-kmods` (low cost).

Layout:
```
repo/
  azurelinux-desktop-policy-<kernel-release>.x86_64.rpm
  azurelinux-desktop-usbhid-kmod-<kernel-release>.x86_64.rpm
  azurelinux-desktop-usb-storage-kmod-<kernel-release>.x86_64.rpm
  manifest.txt
  repodata/
    repomd.xml
    ...
```

`manifest.txt` is a compact inventory used by the publisher when preserving older matching pairs. `repodata/repomd.xml` is the public DNF entry point. Older kernel+policy+kmod pairs are retained so installs that haven't moved to the newest Azure kernel can still resolve the right module.

## Publisher workflow (`publish-desktop-kmods.yml`)

- Runs every four hours (event-driven, not calendar-cadenced — Azure kernel publishes on May 5, 7, 11, 12, 14, 19, 28, then July 18 for the 4.0 series; no useful cadence).
- Step 1: query Azure package metadata for newest kernel NEVRA.
- Step 2: check `manifest.txt`. If the matching policy RPM exists, stop (no expensive work).
- Step 3: if missing, start Azure Linux container, run `scripts/build-desktop-kmods.sh`.
- Step 4: regenerate RPM metadata, test a fresh DNF transaction against the staged repo.
- Step 5: `actions/configure-pages` + `actions/upload-pages-artifact` + `actions/deploy-pages`.
- Step 6: `curl --fail` against public `repomd.xml` to verify deployment.

**Concurrency group:** serializes repository writes. Image/installer/canary callers all run the same fast metadata-check before building. The live release wrapper runs the preflight once, then starts separate ISO and disk-image calls with their internal preflight disabled (avoids a race over the shared repo).

**`republish` input:** forces a new build+deployment even when the current policy RPM already exists. Used for repository maintenance (fixing metadata or removing superseded files) without waiting for a new Azure kernel.

**Pages setup:** Pages must be enabled (`build_type: workflow`) before the workflow can deploy. First setup was done via GitHub API; the workflow then uses `configure-pages` with `enablement: true` so it remains safe if settings need to be restored. Required workflow permissions: `pages: write`, `id-token: write`. A workflow calling an image build through a release wrapper must grant these too — reusable workflow permissions can only stay the same or become narrower, never broader.

Evidence (Pages enable step):
```
Get Pages site failed. Please verify that the repository has Pages enabled
and configured to build using GitHub Actions...
Create Pages site failed. Error: Resource not accessible by integration.
```
Resolved by the correct API call sequence / permissions.

## Secure Boot

This is a project-built module, not signed by Azure Linux's kernel key. Works for the project's test path where Secure Boot module enforcement is not enabled. Not a Secure Boot solution.

## How images consume the repo

- **Live kickstart and installer offline-repo builder:** add the Pages repo and install `azurelinux-desktop-policy`.
- **Installer post-install script:** leaves the same `.repo` file on the installed target.
- **Canary container:** adds the Pages repo, checks that DNF can resolve `kernel` + `azurelinux-desktop-policy` + `azurelinux-desktop-usbhid-kmod` together. The container cannot load the module (not bootable), but the transaction check catches a stale Pages repo or broken dependency before an ISO build does.
- **Installed system:** keeps the last kernel with a matching module bootable; moves forward (kernel + policy + kmod together) when the publisher adds the matching RPM pair.

## Known issues

- **`kernel-devel--` NEVRA query bug (2026-07-22).** The NEVRA query step briefly produced `kernel-devel--` (malformed package name). DNF:
```
Failed to resolve the transaction:
No match for argument: kernel-devel--.
```
Root cause was a string-interpolation error in the query script; fixed.
- **Malformed URL in URL check (2026-07-22).** Validation step URL construction bug:
```
curl: (3) URL rejected: Malformed input to a URL function
```
Fixed.
- **Virtio input is a VM workaround, not a product fix.** Azure's `virtio_input.ko` is present. QEMU test VMs can use `-device virtio-tablet-pci` to get pointer input. Physical USB mice still need `usbhid`; shipping without it is not a complete desktop kernel.

## Verification

Smallest external check:
```bash
curl --fail --location \
  https://sirredbeard.github.io/azurelinux-desktop/repo/repodata/repomd.xml
```

Meaningful package check: Azure Linux container with only the Azure kernel repo and this Pages repo enabled. Install `kernel` and `azurelinux-desktop-policy`, then verify the `usbhid.ko` path and vermagic. `scripts/test-canary-container.sh` performs the same checks in the published canary.

## Current state

Module builds successfully for each Azure kernel release. Pages repo is live. Live ISO, qcow2, and installed targets all carry the Pages `.repo` file and `azurelinux-desktop-policy`. Canary container transaction check in place. Module vermagic matches installed kernel confirmed in 2026-07-22 release artifacts.

## References

- `live-iso-installer-parity.md` — how the module fits into parity matrix
- `canary-container.md` — canary transaction check
- Azure Linux kernel config: `microsoft/azurelinux` `base/comps/kernel/6.18-x86_64-azl.config`


## USB mass-storage sibling package

AZL 4.0 x86_64 also leaves `# CONFIG_USB_STORAGE is not set` (and no UAS).
That blocks USB-stick boot of live/installer media even when usbhid is
present. See `usb-storage-missing-initrd.md`.

`scripts/build-desktop-kmods.sh` builds **both** kmod packages in one run
against the same `kernel-devel` / source tarball / vermagic check:

- `azurelinux-desktop-usbhid-kmod` — `usbhid.ko` + dracut `add_drivers+=" usbhid "`
- `azurelinux-desktop-usb-storage-kmod` — `usb-storage.ko`, `uas.ko` +
  dracut `add_drivers+=" usb-storage uas "`

Build flags force `CONFIG_USB_STORAGE_MODULE` / `CONFIG_USB_UAS_MODULE` so
upstream `IS_ENABLED()` paths match a normal `=m` build. Specialty `ums-*`
unusual drivers are not shipped; stick/UAS boot only needs the core pair.

Secure Boot caveat is identical to usbhid: project-built, unsigned by the
Azure kernel key.