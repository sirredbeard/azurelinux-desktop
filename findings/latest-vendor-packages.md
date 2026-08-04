# Always-latest Microsoft / GitHub packages

**Status:** implemented for live ISO, disk image, installer ISO, canary

## Goal

Every live ISO, installer ISO, disk image, and canary build should ship the
current Microsoft and GitHub desktop tools from their real feeds, not a hand-pinned
version from an old commit.

## What "latest" means here

| Source | Packages | How latest is enforced |
| --- | --- | --- |
| `packages.microsoft.com` (rhel/9/prod, vscode, edge-canary) | powershell, azure-cli, dotnet-*, code-insiders, microsoft-edge-canary | Unversioned yum names; dnf resolves at build time |
| `cli.github.com` | gh | Same |
| `mirror.mwt.me/shiftkey-desktop/rpm` | github-desktop | Same (official shiftkey.dev TLS was broken; mirror kept) |
| GitHub Releases `github/app` | Copilot GUI RPM | `scripts/fetch-latest-thirdparty.sh` |
| GitHub Releases `github/copilot-cli` | copilot binary + SHA256SUMS | same helper |
| GitHub Releases `microsoft/edit` | edit tarball | same helper |
| Flathub | `flathub.flatpakrepo` | same helper (best-effort) |

Yum paths already preferred latest because kickstarts never pin EVR. The gap was
side-loads and soft failures: live used to `WARNING` and continue if Copilot GUI
or edit failed to download, so images could ship without them.

## Shared helpers

- `scripts/fetch-latest-thirdparty.sh DEST`
  - Resolves `/releases/latest` for Copilot GUI/CLI and microsoft/edit
  - Verifies Copilot CLI against published SHA256SUMS
  - Writes `thirdparty-versions.txt` (tag + URL) for the build log and
    `/var/log/azl-desktop-thirdparty-versions.txt` on the image when installed
  - Uses `GITHUB_TOKEN` / `GH_TOKEN` when set (CI rate limits)
  - JSON parse prefers python3; grep fallback for lean images
  - **microsoft/edit:** assets are versioned
    (`edit-2.0.0-x86_64-linux-gnu.tar.gz`). Prefer
    `releases/latest/download/edit-${ver}-x86_64-linux-gnu.tar.gz` before
    API asset scan. Fedora container images often have no python3; the old
    RPM-only grep fallback failed canary with
    `error: no x86_64-linux-gnu.tar.gz on microsoft/edit latest (v2.0.0)`
    even though the asset existed (run `30849555777`).
- `scripts/log-latest-vendor-packages.sh [OUT]`
  - `dnf5 repoquery --refresh --latest-limit=1` against each vendor repo
  - Fails if a required package cannot be resolved
  - Run at the start of live / disk / installer CI builds

## Path wiring

| Artifact | Side-load path | Hard fail |
| --- | --- | --- |
| Live ISO | `%post --nochroot` → fetch helper → chroot install | yes (`test -s` + no `\|\| true` on rpm/tar) |
| Disk qcow2 | same via generated `azurelinux-desktop-live-disk.ks` (sed from live.ks) | yes |
| Installer ISO | CI prefetches into `assets/thirdparty-latest/`, packs into `assets.tar.gz`; `kiwi/config.sh` copies to `/opt/azl-offline-extras/`; install kickstart installs on target | yes |
| Canary | `build-canary-container.sh` mounts `scripts/` and runs fetch helper | yes |

Installer offline yum downloads also use `dnf5 download --refresh` and
`metadata_expire=0` so Microsoft/Fedora NEVRAs are not a stale layer cache.

## CI notes

- Live and disk `docker run` pass `-e GITHUB_TOKEN -e GH_TOKEN` from
  `secrets.GITHUB_TOKEN`.
- Installer packs thirdparty on the runner (token available) before kiwi, so
  chrooted `config.sh` does not need GitHub API access or a secret in the image.
- Vendor NEVRA snapshot is written under `build-meta/` (or `disk-result/`)
  first, then copied next to the ISO after livemedia-creator. Do not
  pre-create a non-empty `--resultdir` for lmc.
- Installer: `installer-result/vendor-packages-latest.txt`.

## What this does not do

- It does not pin or freeze a known-good Microsoft stack for reproducibility.
  Builds from the same commit on different days can ship different tool NEVRAs.
- It does not auto-upgrade an already-installed system; runtime repos stay
  configured so the user can `dnf upgrade` themselves.
- Canary still does not ship a full GNOME BT stack; it only proves the
  same package/repo/side-load policy.

## Verify

```bash
# Local: resolve current side-loads
./scripts/fetch-latest-thirdparty.sh /tmp/tp && cat /tmp/tp/thirdparty-versions.txt

# Inside a Fedora build container with network:
./scripts/log-latest-vendor-packages.sh
```

After a CI build, check the job log for the vendor snapshot and that the image
contains `/usr/local/bin/copilot`, `/usr/local/bin/edit`, and the Copilot GUI RPM.


## .NET 11 SDK (tarball side-load)

Preview/RC .NET is **not** on `packages.microsoft.com` yum feeds (Microsoft
docs: install previews via binary archive). Builds always take the current
**11.0** linux-x64 SDK from, in order:

1. `https://builds.dotnet.microsoft.com/dotnet/release-metadata/11.0/releases.json` (same metadata the [download page](https://dotnet.microsoft.com/en-us/download/dotnet/11.0) uses)
2. Scrape of that download page for `builds.dotnet.microsoft.com` ... `linux-x64.tar.gz`
3. `aka.ms/dotnet/11.0/preview/...` then non-preview shortlink

`scripts/fetch-latest-thirdparty.sh` hard-fails if none resolve.
`scripts/install-dotnet-sdk-tarball.sh` lays out `/usr/share/dotnet` +
`/usr/bin/dotnet` + `DOTNET_ROOT` profile. Wired into live kickstarts,
installer `kiwi/config.sh` + `azl-install.ks.in`, and the canary container.

Do **not** pin `dotnet-sdk-9.0` from ms-prod (EOL-bound). Fedora's
`dotnet-sdk-10.0` is not the default for this desktop image.

