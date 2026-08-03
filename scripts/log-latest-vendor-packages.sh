#!/usr/bin/env bash
# Print the latest available NEVRAs for Microsoft/GitHub yum packages
# this project installs from third-party repos. Run at the start of ISO
# builds so the log shows what "latest" meant that day. Exit 1 if any
# required yum package cannot be resolved.
#
# .NET SDK is NOT from yum: preview/RC 11.x is side-loaded from Microsoft's
# linux-x64 tarball via scripts/fetch-latest-thirdparty.sh (releases.json /
# download page / aka.ms). This logger only records the resolved SDK version
# when network is available; it does not install packages named dotnet-sdk-*.
set -euo pipefail

OUT="${1:-/dev/stdout}"
DOTNET_OUT="${2:-}"  # optional: writes DOTNET_SDK_VERSION=... for callers

query() {
    local id="$1" url="$2" pkg="$3"
    dnf5 -q repoquery \
        --setopt=reposdir=/dev/null \
        --setopt=metadata_expire=0 \
        --refresh \
        --repofrompath="${id},${url}" \
        --repo="$id" \
        --available \
        --latest-limit=1 \
        --arch=x86_64,noarch \
        --qf '%{name}-%{version}-%{release}.%{arch}\n' \
        "$pkg" 2>/dev/null | head -1
}

require() {
    local label="$1" id="$2" url="$3" pkg="$4"
    local nev
    nev="$(query "$id" "$url" "$pkg" || true)"
    if [[ -z "$nev" ]]; then
        echo "error: no latest package for $label ($pkg from $url)" >&2
        return 1
    fi
    printf '%-22s %s\n' "$label" "$nev"
}

resolve_dotnet11_sdk_version() {
    local meta="https://builds.dotnet.microsoft.com/dotnet/release-metadata/11.0/releases.json"
    curl -fsSL --retry 3 "$meta" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d.get("latest-sdk") or "")
' 2>/dev/null || true
}

MS_PROD=https://packages.microsoft.com/rhel/9/prod/
DOTNET_SDK_VERSION="$(resolve_dotnet11_sdk_version)"
if [[ -n "$DOTNET_OUT" ]]; then
    {
        echo "DOTNET_SDK_VERSION=${DOTNET_SDK_VERSION:-unknown}"
        echo "DOTNET_INSTALL_METHOD=tarball-side-load"
        echo "DOTNET_CHANNEL=11.0"
    } > "$DOTNET_OUT"
fi

{
    echo "# Vendor package latest snapshot ($(date -u +%Y-%m-%dT%H:%MZ))"
    if [[ -n "$DOTNET_SDK_VERSION" ]]; then
        echo "# .NET 11 SDK (tarball side-load, not yum): ${DOTNET_SDK_VERSION}"
    else
        echo "# .NET 11 SDK (tarball side-load): version unresolved at log time (fetch-latest-thirdparty.sh is authoritative)"
    fi
    require powershell ms-prod "$MS_PROD" powershell
    require azure-cli ms-prod "$MS_PROD" azure-cli
    require code-insiders vscode https://packages.microsoft.com/yumrepos/vscode code-insiders
    require edge-canary edge https://packages.microsoft.com/yumrepos/edge-canary microsoft-edge-canary
    require gh gh-cli https://cli.github.com/packages/rpm gh
    require github-desktop ghd https://mirror.mwt.me/shiftkey-desktop/rpm github-desktop
} | tee "$OUT"
