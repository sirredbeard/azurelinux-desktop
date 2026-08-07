# CI prebuilt GHCR build containers

**Status:** active

## Why

Live ISO, installer ISO, and kmod matrix jobs used to start from stock
`fedora:43` or Azure Linux core and `dnf install` lorax, kiwi, or the
compiler stack every run. That costs minutes on every job, churns glibc on
the bind-mounted workspace (installer mkdir flakes), and makes free-disk
more necessary on small runners.

## What we ship

All GHCR lifecycle is owned by `.github/workflows/containers.yml`:

* `ghcr.io/sirredbeard/azurelinux-desktop/build-lorax` (`:latest`, `:YYYY.MM.DD`, `:f43`)
  - Source: `containers/build-lorax/Dockerfile` (Fedora 43 + lorax/anaconda)
* `ghcr.io/sirredbeard/azurelinux-desktop/build-kiwi` (`:latest`, `:YYYY.MM.DD`, `:f43`)
  - Source: `containers/build-kiwi/Dockerfile` (Fedora 43 + python3-kiwi)
* `ghcr.io/sirredbeard/azurelinux-desktop/build-kmods` (`:latest`, `:YYYY.MM.DD`, `:azl4`)
  - Source: `containers/build-kmods/Dockerfile` (Azure Linux 4 + gcc/make/rpm-build)
  - Still installs matching `kernel-devel` at build time (EVR moves upstream)
* `ghcr.io/sirredbeard/azurelinux-desktop/canary` (`:latest`, `:YYYY.MM.DD`)
  - Source: `containers/canary/Dockerfile` (docker build, repo-root context)
  - Wrapper: `scripts/build-canary-container.sh`
  - Repos/pkglist/dconf: `assets/yum.repos.d`, `assets/canary/pkglist.txt`, `assets/dconf`

## Versioning and prune

Same policy for every package:

* Tag `:latest` and `:UTC-date` on every push (`scripts/ghcr-tag-push.sh`)
* Fedora tools also get `:f43`; kmods get `:azl4`
* Prune keeps the newest 2 tagged versions and drops untagged digests
  (`scripts/prune-ghcr-container.sh`, keep=2)

## When images rebuild

* Weekly schedule Monday 03:15 UTC
* Manual `workflow_dispatch` with optional force
* `release.yml` calls:
  * `tool-images` → **schedule only** (lorax/kiwi/kmods, 7-day skip). Focused
    manual ISO/VM runs skip this and pull existing GHCR tags.
  * `canary-containers` → only when canary flag is on (schedule always; manual default off)
  * Schedule sets `force_canary=true`. Manual canary=true keeps the 7-day skip.
  * Manual default `kmods=false` / `canary=false`. Turn them on only when needed.
* Age helper: `scripts/ghcr-image-age-days.sh` (rebuild if age >= 7 or missing)

Canary build/test no longer live in `release.yml`.

## Runners and free-disk

Repo variables (optional):

* Every job defaults to `ubuntu-24.04`. Pickup beats peak cores.
* Optional repo vars only if you want larger labels:
  `AZL_RUNNER_HEAVY` (ISO/disk), `AZL_RUNNER_CONVERT` (VHDX/VDI/VMDK),
  `AZL_RUNNER_KMOD` (kmod matrix), `AZL_RUNNER_LIGHT` (plan/canary/finalize).
* Larger labels often queue a long time; leave the vars unset unless the
  account has spare larger-runner capacity.

Free-disk (`jlumbroso/free-disk-space`) runs only when free space is under
about 40–50G. Convert jobs never free-disk. Prebuilt images remove the
need to wipe the runner just to reinstall lorax/kiwi.

## Cancel friendliness

Long jobs split host steps: check disk → pull tool image → prestage
(short) → livemedia/kiwi (long) → publish. Cancel can land between those
steps more often. Mid-lorax/kiwi still will not die cleanly; that is a
tool limitation, not something free-disk fixes.

## Kmod matrix

`max-parallel` is 8 (twelve families). Image is `build-kmods:azl4` with
fallback to MCR Azure Linux core if GHCR pull fails.

## Artifact storage (prefer runners over GB-hours)

Actions artifact storage accrues hourly. Prefer GitHub Release assets and
short-lived bridges:

* Live/installer ISO: upload Actions artifact only when `release_tag` is
  empty (build-only). Release nights go straight to the GitHub Release.
* qcow2: keep as a short-lived Actions artifact (2 days) so VHDX/VDI/VMDK
  convert jobs can download it. Not a long-term store.
* VHDX/VDI/VMDK: release-only when `release_tag` is set (no Actions artifact).
* Build logs and package lists: 3-day retention. Package lists also commit
  into `findings/` when extract succeeds.
* Canary test logs: 3-day retention.
* Kmod prepare/family artifacts: 2-day retention (bridge only). Pages is
  the durable kmod store.

## Caching

* `containers.yml` builds lorax/kiwi/kmods with `docker/build-push-action`
  and GHA cache scopes (`build-lorax`, `build-kiwi`, `build-kmods`).
* Do not cache Azure Linux / Fedora **product** package trees for Anaconda
  or KIWI rootfs builds (stale risk).
* Tool images themselves are the main cache: pull `build-*:f43` / `:azl4`
  instead of dnf installing compilers every job.

## Dockerfile lint

Do not run hadolint in CI. Lint Dockerfiles locally before push
(`hadolint containers/*/Dockerfile`). Canary uses
`containers/canary/build.sh` (installroot); its Dockerfile is a unit
marker only.

## Parallel builds

After the plan job, `build-lorax`, `build-kiwi`, `build-kmods`, and
`build-canary` all start together. Only `canary-test` waits on canary.

## What stays on the runner (not in a container)

* GitHub Pages deploy for the kmod DNF repo (token + `actions/deploy-pages`)
* `gh release upload` / tag cleanup
* Lightweight plan/finalize jobs

Everything that compiles or runs lorax/kiwi/kmod toolchains should run
inside the prebuilt images.


## Canary build notes

Docker only. Canary uses installroot → scratch so AZL identity packages win. Static assets under `assets/`. One prune script: `scripts/prune-ghcr-container.sh PACKAGE [KEEP]`. Prefer runner pickup time over larger labels for GHCR jobs.

## Failure: BUILD_KIWI_IMAGE unbound

Installer job died immediately after GHCR login:

```
BUILD_KIWI_IMAGE: unbound variable
```

`build-live-iso.yml` sets workflow `env.BUILD_LORAX_IMAGE`. Installer was
missing the kiwi equivalent. Fix: workflow-level

`BUILD_KIWI_IMAGE: ghcr.io/${{ github.repository }}/build-kiwi:f43`

in `build-installer-iso.yml`.

## Live chroot assets (2026.08.07)

Chrooted kickstart `%post` cannot use `/workspace`. Stage assets to
`/root/assets` in nochroot. See `findings/rpm-gpg-keys-on-target.md`.
Missing keys aborted the rest of desktop polish on disk image builds.
