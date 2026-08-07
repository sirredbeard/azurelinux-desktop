# GitHub Copilot GUI: bundled dugite git vs Azure Linux libcurl

**Status:** Fixed and metal-verified 2026-08-06. Product fix forces
system git via `LOCAL_GIT_DIRECTORY=/usr` (configure script + wrapper).
Wired into live kickstart, installer (`azl-install.ks.in` + kiwi
`config.sh` + installer ISO workflow build-helpers), and canary. We
already pull the correct upstream GUI RPM (`github` 1.1.4).

## What failed (metal)

App: **GitHub Copilot** desktop (`github` RPM from
[github/app](https://github.com/github/app)), not the Microsoft Copilot
GTK Flatpak and not GitHub Desktop.

UI error when adding a repository:

```
Couldn't add this repository
Failed to clone project: Cloning into '/home/azurelinux/.copilot/repos/...'
.../.cache/github-copilot-git-2.53.0-3/libexec/git-core/git-remote-https:
error while loading shared libraries: libcurl-gnutls.so.4:
cannot open shared object file: No such file or directory
fatal: remote helper 'https' aborted session
```

## Are we pulling the right GUI version?

**Yes.** Image build and this metal install both track upstream latest.

| Check | Value |
| --- | --- |
| Installed NEVRA | `github-0:1.1.4-1.x86_64` |
| RPM summary | "Tauri Copilot Application" |
| Build host (RPM) | GitHub Actions (`runnervmliwqe...cloudapp.net`) |
| Build time | 2026-08-05 |
| Upstream latest tag | `v1.1.4` (published 2026-08-06) |
| Asset we fetch | `GitHub-Copilot-linux-x64.rpm` |
| Fetch helper | `scripts/fetch-latest-thirdparty.sh` → `github-copilot.rpm` |
| On-disk note | `/var/log/azl-desktop-thirdparty-versions.txt` records `github-copilot-gui v1.1.4` and the same latest/download URL |

Upstream ships **one** Linux x64 RPM for all RPM distros (Fedora, RHEL,
Azure Linux, openSUSE, etc.). There is no separate "Fedora git" or
"RHEL git" build of the app. Same release also publishes `.deb` and
`.AppImage`. Our kickstart/canary path correctly prefers:

```
https://github.com/github/app/releases/latest/download/GitHub-Copilot-linux-x64.rpm
```

RPM runtime Requires (from the package we install):

```
libayatana-appindicator3.so.1()(64bit)
libgtk-3.so.0()(64bit)
libwebkit2gtk-4.1.so.0()(64bit)
```

No `git`, no `libcurl-gnutls`. The app assumes its private git tree will
work. We already learned `libayatana-appindicator-gtk3` must be listed
explicitly so `rpm -i` does not fail quietly (live kickstart comment).

## What the app does with git

The Tauri binary embeds a **private git distribution** and extracts it
on first use under the user cache:

```
~/.cache/github-copilot-git-2.53.0-3/
  bin/git
  libexec/git-core/git-remote-https → git-remote-http
  etc/gitconfig          # dugite-style system config
  ssl/cacert.pem
  share/...
  .integrity-<sha256>
```

Evidence this is the dugite lineage (same idea as GitHub Desktop's
portable git), not "whatever is on PATH":

* Cache directory name: `github-copilot-git-<version>`
* `etc/gitconfig` header literally says it is **dugite's** custom
  system-wide gitconfig and `[include] path=/etc/gitconfig`
* Private `ssl/cacert.pem` (hermetic CA bundle)
* App symbols/modules: `github_app::embedded_git`,
  `USE_BUNDLED_GIT_ENABLED`, `local_git_directory_override`,
  `decompress_zstd`, build-time `GIT_VERSION` / `GIT_TAR_HASH`
* UI/settings string: **"Use the git binary shipped with the app
  instead of the system git"** (bundled git is the product default)

Default resolution order inside the app (from strings / symbols):

1. If `LOCAL_GIT_DIRECTORY` is set and
   `$LOCAL_GIT_DIRECTORY/bin/git` exists →
   **"using git from LOCAL_GIT_DIRECTORY override"**
2. Else use extracted bundled tree → **"using bundled git"**
3. If override path is wrong →
   **"LOCAL_GIT_DIRECTORY does not contain the expected git binary;
   falling back"**

So the app does not "accidentally" pick Debian git. It **intentionally
ships and prefers** a fixed git build so every user gets the same git
features, config defaults, and credential trampoline wiring
(`git-credential-copilot`, `COPILOT_TRAMPOLINE_*`). System git is a
supported escape hatch, not the primary path.

## Why that bundled git is Debian/Ubuntu-shaped

On this machine the HTTPS helper needs a library Azure Linux does not
have:

```
$ ldd ~/.cache/github-copilot-git-2.53.0-3/libexec/git-core/git-remote-http
  libcurl-gnutls.so.4 => not found
  libz.so.1 => /lib64/libz.so.1
  libc.so.6 => /lib64/libc.so.6

$ readelf -d .../git-remote-http | grep NEEDED
  Shared library: [libcurl-gnutls.so.4]
  Shared library: [libz.so.1]
  Shared library: [libc.so.6]

$ readelf -V .../git-remote-http   # version need
  File: libcurl-gnutls.so.4
  Name: CURL_GNUTLS_3
```

That soname and version node are how **Debian/Ubuntu** package curl when
git is built against the GnuTLS flavor of libcurl (`libcurl3-gnutls` /
`libcurl-gnutls.so.4`). dugite-native and Desktop-style Linux git builds
have long used Ubuntu CI images as the Linux builder so one glibc-linked
tarball runs on "most" distros — but the **curl linkage stays
GnuTLS/Debian**.

On Fedora, RHEL, and Azure Linux:

* Distro git uses **OpenSSL** libcurl: `libcurl.so.4` (version node
  `CURL_OPENSSL_*`, not `CURL_GNUTLS_3`)
* There is **no** `libcurl-gnutls` package in Fedora 43 or Azure Linux
  4.0 repos (`dnf repoquery --whatprovides 'libcurl-gnutls.so.4*'` is
  empty)

So:

| Piece | Debian/Ubuntu | Azure Linux / Fedora |
| --- | --- | --- |
| System git HTTPS | often `libcurl-gnutls.so.4` | `libcurl.so.4` (OpenSSL) |
| Bundled `github-copilot-git` | matches | **breaks at dynamic link** |
| Package providing gnutls curl | yes | **no** |

This is a **packaging ABI mismatch**, not a wrong app version and not a
missing "install more RPMs from Fedora" gap we can close with a real
package. A `libcurl.so.4` → `libcurl-gnutls.so.4` symlink is a hack:
it may limp along (we proved a clone once with a symlink +
`GIT_EXEC_PATH`) but it lies about SONAME and version nodes and is not
a supported dependency.

Related upstream pain (same product family / Linux packaging):

* [github/app#2244](https://github.com/github/app/issues/2244) — Fedora:
  cannot clone (libcurl-gnutls missing)
* [github/app#1394](https://github.com/github/app/issues/1394) —
  AppImage `LD_LIBRARY_PATH` leaking into spawned git (different
  failure mode, same "private git + Linux library soup" theme)

## What works on this OS without hacks

System git is already installed and healthy:

```
git-2.55.0-1.fc43 / git-core-2.55.0-1.fc43
/usr/bin/git
/usr/libexec/git-core/git-remote-https → libcurl.so.4 (OpenSSL)
git clone https://github.com/...   # succeeds
```

The supported app override:

```
LOCAL_GIT_DIRECTORY=/usr
# requires /usr/bin/git
```

That is the correct product fix on Azure Linux: keep distro git, tell
the GUI to use it, do not invent a GnuTLS curl package.

## Image / canary policy (shipped fix)

1. Explicit `git` on live `%packages`, installer TARGET_PKGS
   (`kiwi/config.sh`), and canary `PKGS` so `/usr/bin/git` exists.
2. After `rpm -i` / `dnf install` of `github-copilot.rpm`, run
   `scripts/configure-github-copilot-system-git.sh [root]`:
   * `/etc/environment.d/50-azurelinux-desktop-github-copilot.conf`
     → `LOCAL_GIT_DIRECTORY=/usr`
   * `/usr/local/bin/azl-github-copilot` wrapper exports the same and
     execs `/usr/bin/github`
   * rewrite `GitHub Copilot.desktop` `Exec=` to the wrapper (GNOME
     often resolves `github` to `/usr/bin/github` and skips PATH)
3. Wire points: live kickstart nochroot + chroot `%post`, installer
   `azl-install.ks.in` + `config.sh` extras staging, installer ISO
   workflow `build-helpers`, canary build + `test-canary-container.sh`.

Do **not** ship a `libcurl-gnutls.so.4` symlink as the supported fix.

## Metal evidence summary (2026-08-06)

```
# Wrong path (bundled)
~/.cache/github-copilot-git-2.53.0-3/.../git-remote-https
  → libcurl-gnutls.so.4 not found

# Right path (system) after configure script on this host
/etc/environment.d/50-azurelinux-desktop-github-copilot.conf
  LOCAL_GIT_DIRECTORY=/usr
/usr/local/bin/azl-github-copilot → exec /usr/bin/github
GitHub Copilot.desktop Exec=/usr/local/bin/azl-github-copilot %u

# App log (github-app.*.log) after GUI clone of azurelinux-desktop
using git from LOCAL_GIT_DIRECTORY override path=/usr/bin/git
Detected git version 2.55.0
git clone completed … azurelinux-desktop
Created project from clone

# Version parity
rpm -q github  → github-1.1.4-1
upstream latest → v1.1.4 GitHub-Copilot-linux-x64.rpm
thirdparty log → github-copilot-gui v1.1.4
```

## Not the same app

| App | Package / ID | Role |
| --- | --- | --- |
| GitHub Copilot GUI | `github` RPM (`github/app`) | Broken clone (this finding) |
| GitHub Copilot CLI | `/usr/local/bin/copilot` | Separate tarball; also may unpack `github-copilot-git` under `~/.cache` for some flows |
| Microsoft Copilot GTK | Flatpak `com.github.sirredbeard.copilot-desktop-gtk` | WebView wrapper; not this clone path |
| GitHub Desktop | `github-desktop` (shiftkey) | Different product |

## Related

* `latest-vendor-packages.md` — always-latest thirdparty fetch
* live kickstart `libayatana-appindicator-gtk3` note — earlier silent
  `github` RPM install failure
* `scripts/fetch-latest-thirdparty.sh`
* `scripts/configure-github-copilot-system-git.sh`
* `assets/bin/azl-github-copilot`
