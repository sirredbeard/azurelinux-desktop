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
