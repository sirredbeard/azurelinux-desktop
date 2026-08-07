# Release assets upload inside build jobs

**Status:** Implemented 2026-08-04

## Problem

`release.yml` used parent `upload-*` jobs that `needs: build-live` (the
whole reusable workflow call). GitHub only finishes that call when every
nested job ends. A green `build-disk-image` sat as an Actions artifact
while live ISO and VHDX/VDI/VMDK were still running. qcow2 did not appear
on the GitHub Release until the entire live graph completed.

## Change

* `release_tag` input on `build-live-iso.yml` and `build-installer-iso.yml`
* `scripts/ci-upload-release-asset.sh` does sha256, `split -b 1900M`,
  and `gh release upload --clobber`
* Each product job publishes when it finishes (live ISO, installer ISO,
  qcow2, then each 7z convert)
* Parent `upload-*` jobs removed from `release.yml` (no double upload)
* qcow2 still uploads as Actions artifact `azurelinux-desktop-live-qcow2`
  so convert jobs can download it
* VHDX/VDI/VMDK: when `release_tag` is set, release only (no Actions
  artifact). When empty (build-only), keep the Actions artifact

## Caller graph

`build-live` / `build-installer` now
`needs: [plan, kmods, create-release]` so the tag exists before the
first product finishes. `finalize` only checks release assets against
plan flags. It does not re-upload.

## In-flight runs

Runs that checked out the old workflows keep the old upload path until
they finish.

## Step order inside build jobs

Publish the deliverable before bookkeeping:

1. Upload ISO/qcow2 artifact (and `gh release upload` when
   `release_tag` is set)
2. Upload build logs (`if: always()` so failures still get logs)
3. Extract package list / verify payload / commit findings

Installer: logs and fail-fast on KIWI failure first, then ISO publish,
then payload verify.

## Faster VHDX/VDI/VMDK 7z

Cause of long convert jobs: `7z a -mx=9` on large sparse disks. Ultra
compression buys little extra size vs moderate levels and saturates the
runner.

Change:

```text
7z a -t7z -m0=lzma2 -mx=3 -mmt=on -bsp1 …
```

* `-mx=3` is much faster and still shrinks sparse VM disks
* `-mmt=on` uses all cores
* Still `.7z` so `Get-AzureLinuxDesktop.ps1` is unchanged

If size ever becomes a problem, try `-mx=5` before going back to 9.
Do not default convert formats on every focused debug run if you only
need live ISO and qcow2.
