#!/usr/bin/env bash
# Build simple HTML directory listings for the desktop kmod Pages site.
# Usage: generate-kmod-repo-index.sh SITE_DIR
# Expects SITE_DIR/repo/*.rpm and SITE_DIR/repo/manifest.txt already present.
set -euo pipefail

SITE_DIR="${1:?usage: $0 SITE_DIR}"
REPO_DIR="$SITE_DIR/repo"
test -d "$REPO_DIR"
test -f "$REPO_DIR/manifest.txt"

# Touch .nojekyll so Pages never runs Jekyll on RPM paths.
: > "$SITE_DIR/.nojekyll"

generated_at="$(date -u +'%Y-%m-%d %H:%M UTC')"
repo_url="https://sirredbeard.github.io/azurelinux-desktop/repo/"

# --- /repo/index.html ---
{
  cat <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>azurelinux-desktop kmod repo (x86_64)</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, sans-serif; line-height: 1.45; max-width: 52rem;
         margin: 1.5rem auto; padding: 0 1rem; }
  h1 { font-size: 1.35rem; margin-bottom: 0.25rem; }
  h2 { font-size: 1.1rem; margin-top: 1.5rem; }
  p, li { max-width: 40rem; }
  code, .path { font-family: ui-monospace, monospace; font-size: 0.92em; }
  table { border-collapse: collapse; width: 100%; margin: 0.75rem 0 1.25rem; }
  th, td { text-align: left; padding: 0.35rem 0.5rem; border-bottom: 1px solid #8884; }
  th { font-weight: 600; }
  td.size { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .muted { opacity: 0.8; font-size: 0.92rem; }
  a { text-decoration-thickness: 1px; }
</style>
</head>
<body>
HTML
  cat <<HTML
<h1>Desktop kmod DNF repo (x86_64)</h1>
<p class="muted">Generated ${generated_at}. Base URL:
<code>${repo_url}</code></p>
<p>
Out-of-tree kernel modules for Azure Linux Desktop on <strong>x86_64</strong>:
USB HID/storage, Intel Wi-Fi, ALSA HDA/USB audio, Bluetooth, UVC cameras,
ThinkPad ACPI, and USB Type-C/UCSI. Built against each exact Azure
<code>kernel-devel</code> release. A policy RPM couples them so a kernel-only
update cannot orphan the modules.
</p>
<p>
This is a normal DNF/yum repository. Point a
<code>.repo</code> file at the base URL above (or install
<code>azurelinux-desktop-policy</code> from media that already does).
Browsers do not get automatic directory listings from GitHub Pages, so this
page is the human index.
</p>

<h2>Quick links</h2>
<ul>
  <li><a href="manifest.txt"><code>manifest.txt</code></a> — RPM filenames in this tree</li>
  <li><a href="repodata/repomd.xml"><code>repodata/repomd.xml</code></a> — DNF metadata</li>
  <li><a href="../">Site root</a></li>
  <li><a href="https://github.com/sirredbeard/azurelinux-desktop">GitHub repository</a></li>
  <li><a href="https://github.com/sirredbeard/azurelinux-desktop/blob/main/findings/out-of-tree-usb-kmods-pages.md">How the pipeline works</a></li>
</ul>

<h2>Packages</h2>
<table>
<thead><tr><th>File</th><th class="size">Size</th></tr></thead>
<tbody>
HTML

  # List RPMs (and other top-level files except index itself)
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    [[ "$base" == "index.html" ]] && continue
    size="$(wc -c < "$f" | tr -d ' ')"
    # human size
    if command -v numfmt >/dev/null 2>&1; then
      hsize="$(numfmt --to=iec --suffix=B "$size")"
    else
      hsize="${size}B"
    fi
    # escape nothing critical in filenames (ours are safe)
    printf '<tr><td><a href="%s"><code>%s</code></a></td><td class="size">%s</td></tr>\n' \
      "$base" "$base" "$hsize"
  done < <(find "$REPO_DIR" -maxdepth 1 -type f ! -name 'index.html' -print0 | sort -z)

  cat <<'HTML'
</tbody>
</table>

<h2>repodata/</h2>
<ul>
HTML
  if [[ -d "$REPO_DIR/repodata" ]]; then
    while IFS= read -r -d '' f; do
      base="$(basename "$f")"
      printf '<li><a href="repodata/%s"><code>%s</code></a></li>\n' "$base" "$base"
    done < <(find "$REPO_DIR/repodata" -maxdepth 1 -type f -print0 | sort -z)
  fi

  cat <<'HTML'
</ul>

<p class="muted">
Package names: <code>azurelinux-desktop-usbhid-kmod</code>,
<code>azurelinux-desktop-usb-storage-kmod</code>,
<code>azurelinux-desktop-iwlwifi-kmod</code>,
<code>azurelinux-desktop-policy</code>.
Each kmod RPM requires the matching <code>kernel-core-uname-r</code>.
</p>
</body>
</html>
HTML
} > "$REPO_DIR/index.html"

# --- site root index.html ---
{
  cat <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>azurelinux-desktop Pages</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, sans-serif; line-height: 1.45; max-width: 40rem;
         margin: 1.5rem auto; padding: 0 1rem; }
  h1 { font-size: 1.35rem; }
  code { font-family: ui-monospace, monospace; font-size: 0.92em; }
</style>
</head>
<body>
HTML
  cat <<HTML
<h1>azurelinux-desktop on GitHub Pages</h1>
<p>
This site hosts the project DNF repository of out-of-tree desktop kernel
modules for Azure Linux 4.0 on x86_64 (USB HID, USB mass storage, Intel
Wi-Fi), plus matching policy RPMs.
</p>
<ul>
  <li><a href="repo/"><strong>Browse the kmod repo</strong></a>
      (<code>${repo_url}</code>)</li>
  <li><a href="repo/manifest.txt"><code>repo/manifest.txt</code></a></li>
  <li><a href="https://github.com/sirredbeard/azurelinux-desktop">Source on GitHub</a></li>
</ul>
<p class="muted" style="opacity:0.8;font-size:0.92rem">Generated ${generated_at}.</p>
</body>
</html>
HTML
} > "$SITE_DIR/index.html"

echo "Wrote $SITE_DIR/index.html and $REPO_DIR/index.html"
