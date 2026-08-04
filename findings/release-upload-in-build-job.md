# Release assets upload inside build jobs

**Status:** implemented (2026-08-04)

## Problem

`release.yml` used parent `upload-*` jobs that `needs: build-live` (the
whole reusable workflow call). GitHub only finishes that call when every
nested job ends. So a green `build-disk-image` sat as an Actions artifact
while live ISO and VHDX/VDI/VMDK were still running; qcow2 did not appear
on the GitHub Release until the entire live graph completed.

## Change

* `release_tag` input on `build-live-iso.yml` and `build-installer-iso.yml`.
* `scripts/ci-upload-release-asset.sh` - sha256, `split -b 1900M`,
  `gh release upload --clobber`.
* Each product job publishes when it finishes (live ISO, installer ISO,
  qcow2, then each 7z convert).
* Parent `upload-*` jobs removed from `release.yml` (no double upload).
* **qcow2** still uploads as Actions artifact `azurelinux-desktop-live-qcow2`
  so convert jobs can download it.
* **VHDX/VDI/VMDK**: when `release_tag` is set, release only (no Actions
  artifact). When empty (build-only), keep the Actions artifact.

## Caller graph

`build-live` / `build-installer` now `needs: [plan, kmods, create-release]`
so the tag exists before the first product finishes. `finalize` only
checks release assets against plan flags; it does not re-upload.

## Does not apply mid-run

In-flight runs that checked out the old workflows keep the old upload
path until they finish.

## Step order inside build jobs

Publish the deliverable before bookkeeping:

1. Upload ISO/qcow2 artifact (+ `gh release upload` when `release_tag` set)
2. Upload build logs (`if: always()` so failures still get logs)
3. Extract package list / verify payload / commit findings

Installer: logs + fail-fast on KIWI failure first, then ISO publish, then
payload verify.

## Faster VHDX/VDI/VMDK 7z

Cause of ~20+ min convert jobs: `7z a -mx=9` on ~11 GiB sparse disks.
Ultra compression buys little extra size vs moderate levels and saturates
the runner for a long time.

Change: `7z a -t7z -m0=lzma2 -mx=3 -mmt=on -bsp1 …`

* `-mx=3` — much faster; still real shrink for sparse VM disks  
* `-mmt=on` — all cores (runners were showing Threads:4 with mx=9)  
* Still `.7z` so `Get-AzureLinuxDesktop.ps1` is unchanged  

If size ever becomes a problem, try `-mx=5` before going back to 9.
Do not default convert formats on every focused debug run if you only
need live ISO + qcow2.
