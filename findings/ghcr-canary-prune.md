# GHCR canary version prune

**Status:** active in `release.yml` canary job

## Why

Each release push tags `ghcr.io/sirredbeard/azurelinux-desktop/canary:latest`
and `:YYYY.MM.DD`. Old versions pile up. Canary is a packaging/repo-policy
probe, not a long image archive.

## Keep policy

* Newest **two tagged** versions
* Delete older tagged versions
* Delete **all untagged** versions (retags leave digests behind)

## How

Script: `scripts/prune-ghcr-container.sh`

* REST: `GET/DELETE /users/{owner}/packages/container/{name}/versions`
* Nested package name `azurelinux-desktop/canary` encoded as
  `azurelinux-desktop%2Fcanary`
* CI: after canary push in `release.yml`, with `packages: write` on the job
* `GITHUB_TOKEN` is enough when the same repo published the package
  (admin role granted on first push)

Local `gh` without `read:packages` / `delete:packages` will 403. That is
expected outside Actions.

## Not used

Third-party cleanup actions. One small script in `/scripts/` is enough
for a single-arch canary.
