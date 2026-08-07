# GitHub Copilot GUI: bundled dugite git vs Azure Linux libcurl

**Status:** Fixed and metal-verified. Product fix forces system git via
`LOCAL_GIT_DIRECTORY=/usr` (configure script + wrapper). Wired into live
kickstart, installer (`azl-install.ks.in` + kiwi `config.sh` + installer
ISO workflow build-helpers), and canary. We already pull the correct
upstream GUI RPM.

## What failed (metal)

App: GitHub Copilot desktop (`github` RPM from github/app), not the
Microsoft Copilot GTK Flatpak and not GitHub Desktop.

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

Yes. Image build and metal install both track upstream latest via
`scripts/fetch-latest-thirdparty.sh` to `github-copilot.rpm` from
`GitHub-Copilot-linux-x64.rpm`.

Upstream ships one Linux x64 RPM for all RPM distros. There is no
separate "Fedora git" or "RHEL git" build of the app. RPM runtime
Requires cover GTK/WebKit indicators only. No `git`, no
`libcurl-gnutls`. The app assumes its private git tree will work.

We already learned `libayatana-appindicator-gtk3` must be listed
explicitly so `rpm -i` does not fail quietly.

## What the app does with git

The Tauri binary embeds a private git distribution and extracts it on
first use under the user cache:

```
~/.cache/github-copilot-git-<version>/
  bin/git
  libexec/git-core/git-remote-https -> git-remote-http
  etc/gitconfig # dugite-style system config
  ssl/cacert.pem
```

Evidence this is the dugite lineage (same idea as GitHub Desktop's
portable git), not "whatever is on PATH":

- Cache directory name: `github-copilot-git-<version>`
- `etc/gitconfig` header says it is dugite's custom system-wide
  gitconfig
- Private `ssl/cacert.pem`
- App symbols: `embedded_git`, `USE_BUNDLED_GIT_ENABLED`,
  `local_git_directory_override`
- UI string: use the git binary shipped with the app instead of system
  git (bundled git is the product default)

Default resolution order:

1. If `LOCAL_GIT_DIRECTORY` is set and
   `$LOCAL_GIT_DIRECTORY/bin/git` exists, use override
2. Else use extracted bundled tree
3. If override path is wrong, fall back with a log line

## Why that bundled git is Debian/Ubuntu-shaped

On this machine the HTTPS helper needs a library Azure Linux does not
have:

```
$ ldd ~/.cache/github-copilot-git-.../libexec/git-core/git-remote-http
  libcurl-gnutls.so.4 => not found
```

That soname and version node (`CURL_GNUTLS_3`) are how Debian/Ubuntu
package curl when git is built against the GnuTLS flavor of libcurl.
dugite-native Linux git builds have long used Ubuntu CI images so one
glibc-linked tarball runs on "most" distros, but the curl linkage stays
GnuTLS/Debian.

On Fedora, RHEL, and Azure Linux:

- Distro git uses OpenSSL libcurl: `libcurl.so.4` (`CURL_OPENSSL_*`)
- There is no `libcurl-gnutls` package in Fedora or Azure Linux repos

This is a packaging ABI mismatch, not a wrong app version and not a
missing "install more RPMs" gap we can close with a real package. A
`libcurl.so.4` to `libcurl-gnutls.so.4` symlink is a hack and is not a
supported dependency.

Related upstream: github/app issues about Fedora clone failures for the
same missing libcurl-gnutls.

## What works on this OS without hacks

System git is already installed and healthy. It links
`git-remote-https` against `libcurl.so.4` (OpenSSL). Plain
`git clone https://...` succeeds.

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
2. After install of `github-copilot.rpm`, run
   `scripts/configure-github-copilot-system-git.sh [root]`:
   - `/etc/environment.d/50-azurelinux-desktop-github-copilot.conf`
     sets `LOCAL_GIT_DIRECTORY=/usr`
   - `/usr/local/bin/azl-github-copilot` wrapper exports the same and
     execs `/usr/bin/github`
   - rewrite `GitHub Copilot.desktop` `Exec=` to the wrapper (GNOME
     often resolves `github` to `/usr/bin/github` and skips PATH)
3. Wire points: live kickstart nochroot + chroot `%post`, installer
   `azl-install.ks.in` + `config.sh` extras staging, installer ISO
   workflow `build-helpers`, canary build + `test-canary-container.sh`.

Do not ship a `libcurl-gnutls.so.4` symlink as the supported fix.

## Metal evidence summary

```
# Wrong path (bundled)
~/.cache/github-copilot-git-.../git-remote-https
  -> libcurl-gnutls.so.4 not found

# Right path (system) after configure script
LOCAL_GIT_DIRECTORY=/usr
azl-github-copilot -> exec /usr/bin/github
desktop Exec=/usr/local/bin/azl-github-copilot %u

# App log after GUI clone
using git from LOCAL_GIT_DIRECTORY override path=/usr/bin/git
git clone completed
```

## Not the same app

- GitHub Copilot GUI: `github` RPM (`github/app`) - this finding
- GitHub Copilot CLI: `/usr/local/bin/copilot` - separate tarball
- Microsoft Copilot GTK: Flatpak
  `com.github.sirredbeard.copilot-desktop-gtk`
- GitHub Desktop: `github-desktop` (shiftkey)

## Related

- `latest-vendor-packages.md`
- `scripts/fetch-latest-thirdparty.sh`
- `scripts/configure-github-copilot-system-git.sh`
- `assets/bin/azl-github-copilot`
