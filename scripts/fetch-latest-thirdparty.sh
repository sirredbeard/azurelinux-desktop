#!/usr/bin/env bash
# Fetch the current GitHub/Microsoft side-load assets that have no yum repo.
#
# Always resolves the *latest* release (no pinned version numbers). Used by:
#   - kickstart %post --nochroot (live + disk images)
#   - kiwi/config.sh (installer offline extras)
#   - scripts/build-canary-container.sh (canary)
#
# Usage:
#   fetch-latest-thirdparty.sh DEST_DIR
#
# Env:
#   GITHUB_TOKEN / GH_TOKEN  optional; raises API rate limits in CI
#   CURL_RETRIES             default 5
#
# Writes into DEST_DIR:
#   github-copilot.rpm
#   copilot-linux-x64.tar.gz
#   copilot-SHA256SUMS.txt
#   edit.tar.gz
#   flathub.flatpakrepo          (best-effort; missing is non-fatal)
#   thirdparty-versions.txt     (resolved URLs/tags for the build log)
set -euo pipefail

DEST="${1:?usage: $0 DEST_DIR}"
mkdir -p "$DEST"

RETRIES="${CURL_RETRIES:-5}"
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
AUTH=()
if [[ -n "$TOKEN" ]]; then
    AUTH=(-H "Authorization: Bearer ${TOKEN}")
fi

api_get() {
    local url="$1"
    curl -fsSL --retry "$RETRIES" --retry-all-errors \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${AUTH[@]}" \
        "$url"
}

download() {
    local url="$1" out="$2"
    curl -fL --retry "$RETRIES" --retry-all-errors -o "$out" "$url"
    test -s "$out"
}

VERSIONS="$DEST/thirdparty-versions.txt"
: > "$VERSIONS"
logv() { printf '%s\n' "$*" | tee -a "$VERSIONS" >&2; }

# JSON helpers: prefer python3, fall back to grep/sed so kiwi's lean
# installer image (no python3 in bootstrap) can still resolve latest.
json_tag() {
    local json="$1"
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tag_name",""))'
        return
    fi
    printf '%s' "$json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4
}

json_asset_url() {
    # $1=json  $2=ERE matched against asset name
    # Prefer python3 when present. Fedora container images often ship
    # without it, so the grep path must handle both .rpm and .tar.gz
    # assets (microsoft/edit uses edit-<ver>-x86_64-linux-gnu.tar.gz).
    local json="$1" pat="$2" url=""
    if command -v python3 >/dev/null 2>&1; then
        url="$(printf '%s' "$json" | PAT="$pat" python3 -c '
import sys, json, re, os
pat = re.compile(os.environ["PAT"], re.I)
for a in json.load(sys.stdin).get("assets") or []:
    name = a.get("name") or ""
    if pat.search(name):
        print(a.get("browser_download_url") or "")
        break
' 2>/dev/null || true)"
    fi
    if [[ -z "$url" ]]; then
        # Grep fallback: find a "name" field matching the ERE, then the
        # browser_download_url on a nearby line (release JSON is one object
        # per asset after tr '{' ).
        local chunk name
        while IFS= read -r chunk; do
            name="$(printf '%s' "$chunk" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
            [[ -n "$name" ]] || continue
            if printf '%s' "$name" | grep -Eiq -- "$pat"; then
                url="$(printf '%s' "$chunk" | grep -oE 'https://[^"]+' | head -1 || true)"
                [[ -n "$url" ]] && break
            fi
        done < <(printf '%s' "$json" | tr '{' '\n')
    fi
    if [[ -z "$url" ]]; then
        # Last resorts by common asset name patterns
        url="$(printf '%s' "$json" | grep -oE 'https://[^"]+x86_64-linux-gnu\.tar\.gz' | head -1 || true)"
    fi
    if [[ -z "$url" ]]; then
        url="$(printf '%s' "$json" | grep -oE 'https://[^"]+linux[-_]x64\.rpm' | head -1 || true)"
    fi
    printf '%s' "$url"
}

echo "=== fetch-latest-thirdparty → $DEST ===" >&2

# --- GitHub Copilot GUI (github/app) ---
COPILOT_GUI_JSON="$(api_get https://api.github.com/repos/github/app/releases/latest)"
COPILOT_GUI_TAG="$(json_tag "$COPILOT_GUI_JSON")"
# Prefer the linux x64 rpm; names have varied across releases.
# Try the stable latest/download name first (current github/app layout),
# then fall back to API asset scan.
COPILOT_GUI_URL=""
for cand in     "https://github.com/github/app/releases/latest/download/GitHub-Copilot-linux-x64.rpm"     "https://github.com/github/app/releases/latest/download/github-copilot-linux-x64.rpm"
do
    if curl -fsI --retry 2 "$cand" >/dev/null 2>&1; then
        COPILOT_GUI_URL="$cand"
        break
    fi
done
if [[ -z "$COPILOT_GUI_URL" ]]; then
    COPILOT_GUI_URL="$(json_asset_url "$COPILOT_GUI_JSON" 'linux[-_]?x64.*\.rpm$')"
fi
[[ -n "$COPILOT_GUI_URL" ]] || {
    echo "error: no linux x64 RPM on github/app latest ($COPILOT_GUI_TAG)" >&2
    exit 1
}
download "$COPILOT_GUI_URL" "$DEST/github-copilot.rpm"
logv "github-copilot-gui ${COPILOT_GUI_TAG} ${COPILOT_GUI_URL}"

# --- GitHub Copilot CLI ---
COPILOT_CLI_JSON="$(api_get https://api.github.com/repos/github/copilot-cli/releases/latest)"
COPILOT_CLI_TAG="$(json_tag "$COPILOT_CLI_JSON")"
COPILOT_ARCHIVE="copilot-linux-x64.tar.gz"
download \
    "https://github.com/github/copilot-cli/releases/latest/download/${COPILOT_ARCHIVE}" \
    "$DEST/${COPILOT_ARCHIVE}"
download \
    "https://github.com/github/copilot-cli/releases/latest/download/SHA256SUMS.txt" \
    "$DEST/copilot-SHA256SUMS.txt"
(
    cd "$DEST"
    grep -E " [*]?${COPILOT_ARCHIVE}$" copilot-SHA256SUMS.txt | sha256sum -c -
)
tar -tzf "$DEST/${COPILOT_ARCHIVE}" copilot >/dev/null
logv "github-copilot-cli ${COPILOT_CLI_TAG} latest/download/${COPILOT_ARCHIVE}"

# --- microsoft/edit ---
# Asset names look like edit-2.0.0-x86_64-linux-gnu.tar.gz (versioned).
# Prefer the deterministic latest/download URL so this works in lean
# containers that have curl but no python3 (canary build host).
EDIT_JSON="$(api_get https://api.github.com/repos/microsoft/edit/releases/latest)"
EDIT_TAG="$(json_tag "$EDIT_JSON")"
EDIT_VER="${EDIT_TAG#v}"
EDIT_URL=""
for cand in \
    "https://github.com/microsoft/edit/releases/latest/download/edit-${EDIT_VER}-x86_64-linux-gnu.tar.gz" \
    "https://github.com/microsoft/edit/releases/download/${EDIT_TAG}/edit-${EDIT_VER}-x86_64-linux-gnu.tar.gz"
do
    if curl -fsI --retry 2 "$cand" >/dev/null 2>&1; then
        EDIT_URL="$cand"
        break
    fi
done
if [[ -z "$EDIT_URL" ]]; then
    EDIT_URL="$(json_asset_url "$EDIT_JSON" 'x86_64-linux-gnu\.tar\.gz$')"
fi
[[ -n "$EDIT_URL" ]] || {
    echo "error: no x86_64-linux-gnu.tar.gz on microsoft/edit latest ($EDIT_TAG)" >&2
    exit 1
}
download "$EDIT_URL" "$DEST/edit.tar.gz"
# Archive root entry is the `edit` binary (not ./edit on all releases).
if ! tar -tzf "$DEST/edit.tar.gz" edit >/dev/null 2>&1 \
    && ! tar -tzf "$DEST/edit.tar.gz" ./edit >/dev/null 2>&1; then
    echo "error: edit tarball does not contain the edit binary" >&2
    exit 1
fi
logv "microsoft-edit ${EDIT_TAG} ${EDIT_URL}"

# --- Flathub remote definition (network at image build only) ---
if curl -fsSL --retry "$RETRIES" -o "$DEST/flathub.flatpakrepo" \
    https://dl.flathub.org/repo/flathub.flatpakrepo \
    && test -s "$DEST/flathub.flatpakrepo"; then
    logv "flathub.flatpakrepo ok"
else
    rm -f "$DEST/flathub.flatpakrepo"
    echo "warning: flathub.flatpakrepo fetch failed (non-fatal)" >&2
    logv "flathub.flatpakrepo MISSING"
fi


# --- .NET SDK 11 (linux-x64 binary archive; not in yum yet) ---
# Microsoft does not publish preview/RC .NET to packages.microsoft.com
# yum feeds. Live/installer images always side-load the current 11.0
# linux-x64 SDK tarball. Resolution order:
#   1) Official channel metadata (same feed the download site uses):
#      https://builds.dotnet.microsoft.com/dotnet/release-metadata/11.0/releases.json
#   2) Scrape https://dotnet.microsoft.com/en-us/download/dotnet/11.0 for
#      a builds.dotnet.microsoft.com linux-x64 SDK tar.gz URL
#   3) aka.ms floating shortlinks (preview, then GA)
# Hard-fail if none work: this image ships bleeding-edge .NET 11, not 9.x.
DOTNET_TGZ="$DEST/dotnet-sdk-linux-x64.tar.gz"
DOTNET_URL=""
DOTNET_VER=""
DOTNET_FINAL=""
DOTNET_META_URL="https://builds.dotnet.microsoft.com/dotnet/release-metadata/11.0/releases.json"
DOTNET_PAGE_URL="https://dotnet.microsoft.com/en-us/download/dotnet/11.0"

resolve_dotnet11_from_releases_json() {
    local out
    command -v python3 >/dev/null 2>&1 || return 1
    # Pipe JSON on stdin (do not pass the body via argv/env - releases.json is large).
    out="$(curl -fsSL --retry "$RETRIES" "$DOTNET_META_URL" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sdk_ver = d.get("latest-sdk") or ""
best_url, best_ver = "", sdk_ver

def sdk_list(rel):
    out = []
    if isinstance(rel.get("sdk"), dict):
        out.append(rel["sdk"])
    for s in rel.get("sdks") or []:
        if isinstance(s, dict):
            out.append(s)
    return out

def linux_x64_sdk_url(s):
    for f in s.get("files") or []:
        name = f.get("name") or ""
        url = f.get("url") or ""
        if not url:
            continue
        if name == "dotnet-sdk-linux-x64.tar.gz":
            return url
        if "linux-x64" in name and name.endswith(".tar.gz") and "sdk" in name.lower():
            return url
    return ""

for rel in d.get("releases") or []:
    for s in sdk_list(rel):
        ver = s.get("version") or ""
        url = linux_x64_sdk_url(s)
        if not url:
            continue
        if sdk_ver and ver == sdk_ver:
            print(ver)
            print(url)
            raise SystemExit(0)
        if not best_url:
            best_url, best_ver = url, (ver or best_ver)
if best_url:
    print(best_ver or "11.0")
    print(best_url)
    raise SystemExit(0)
raise SystemExit(1)
')" || return 1
    DOTNET_VER="$(printf '%s\n' "$out" | sed -n '1p')"
    DOTNET_URL="$(printf '%s\n' "$out" | sed -n '2p')"
    DOTNET_FINAL="$DOTNET_URL"
    [[ -n "$DOTNET_URL" ]]
}

resolve_dotnet11_from_download_page() {
    local html url
    html="$(curl -fsSL --retry "$RETRIES" "$DOTNET_PAGE_URL" 2>/dev/null || true)"
    [[ -n "$html" ]] || return 1
    url="$(printf '%s' "$html" | grep -oE 'https://builds\.dotnet\.microsoft\.com/dotnet/Sdk/[^"[:space:]]+linux-x64\.tar\.gz' | head -1 || true)"
    [[ -n "$url" ]] || return 1
    DOTNET_URL="$url"
    DOTNET_FINAL="$url"
    DOTNET_VER="${DOTNET_VER:-from-download-page}"
}

resolve_dotnet11_from_aka() {
    local cand final
    for cand in \
        "https://aka.ms/dotnet/11.0/preview/dotnet-sdk-linux-x64.tar.gz" \
        "https://aka.ms/dotnet/11.0/dotnet-sdk-linux-x64.tar.gz"
    do
        final="$(curl -fsSL -o /dev/null -w '%{url_effective}' --retry 2 "$cand" 2>/dev/null || true)"
        if [[ -z "$final" || "$final" == *bing.com* || "$final" == *www.bing* ]]; then
            continue
        fi
        if [[ "$final" == *dotnet-sdk* || "$final" == *.tar.gz* ]]; then
            DOTNET_URL="$cand"
            DOTNET_FINAL="$final"
            DOTNET_VER="${DOTNET_VER:-aka.ms}"
            return 0
        fi
    done
    return 1
}

if ! resolve_dotnet11_from_releases_json; then
    DOTNET_URL=""
    if ! resolve_dotnet11_from_download_page; then
        DOTNET_URL=""
        resolve_dotnet11_from_aka || true
    fi
fi
[[ -n "$DOTNET_URL" ]] || {
    echo "error: could not resolve .NET 11 linux-x64 SDK tarball (releases.json, download page, aka.ms)" >&2
    exit 1
}
download "$DOTNET_URL" "$DOTNET_TGZ"
magic="$(head -c 2 "$DOTNET_TGZ" | od -An -tx1 | tr -d ' \n')"
[[ "$magic" == "1f8b" ]] || {
    echo "error: $DOTNET_TGZ is not gzip (got magic $magic)" >&2
    exit 1
}
# Avoid tar|grep -q under pipefail (SIGPIPE from early grep exit looks like failure).
if ! tar -tzf "$DOTNET_TGZ" ./dotnet >/dev/null 2>&1 \
    && ! tar -tzf "$DOTNET_TGZ" dotnet >/dev/null 2>&1; then
    echo "error: tarball does not contain the dotnet host binary" >&2
    exit 1
fi
logv "dotnet-sdk-11-tarball ${DOTNET_VER:-unknown} ${DOTNET_FINAL:-$DOTNET_URL}"

echo "=== thirdparty assets ready in $DEST ===" >&2
