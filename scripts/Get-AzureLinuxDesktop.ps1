<#
.SYNOPSIS
    Downloads the latest azurelinux-desktop release assets - the live
    ISO, the installer ISO, or a bootable qcow2/VHDX/VDI/VMDK disk image
    of the live desktop - reassembles any split parts, and verifies the
    result against the published sha256 manifest.

.DESCRIPTION
    GitHub Releases caps a single asset at 2GiB. Every asset this project
    publishes (live ISO, installer ISO, qcow2, VHDX, VDI, VMDK) can run
    bigger than that, so the release workflows split anything that needs
    it into fixed-size .part files (<name>.split.00.part, .01.part, ...)
    plus a <name>.sha256 manifest. This script pulls the latest release
    from the GitHub API, downloads every part for the asset kind you
    asked for with aria2c (15 connections per file - much faster than a
    single-stream HTTP GET for files this size), concatenates them back
    into a single file with raw byte streams (no text-mode line-ending
    mangling), and checks the reassembled file's hash against the
    manifest before calling it good.

    Uses aria2c (https://aria2.github.io/ - `winget install aria2.aria2`,
    `choco install aria2`, or `scoop install aria2`) if it's on PATH - 15
    connections per file, much faster than a single-stream GET for files
    this size. If aria2c isn't found, falls back to PowerShell's own
    Invoke-WebRequest (single-stream, noticeably slower on multi-gigabyte
    files) and prints a note recommending aria2c instead of failing
    outright.

    VHDX, VDI, and VMDK ship 7z-compressed (qemu-img has no compression
    support at all for those three formats - only qcow2 gets that, via
    -c/--compress - so 7z is doing the work zstd does for the qcow2
    instead). This script downloads and reassembles the .7z, verifies
    it against the manifest, then decompresses it to produce the actual
    .vhdx/.vdi/.vmdk and deletes the .7z. It looks for a native 7-Zip
    binary first (7z/7zz/7za on PATH, then - Windows only - the
    registry/Program Files locations the official installer doesn't
    add to PATH by default) and only falls back to installing the
    7Zip4Powershell module (https://github.com/thoemmi/7Zip4Powershell)
    from the PowerShell Gallery if none is found, since that module is
    a Windows-only wrapper around native 7-Zip DLLs - confirmed on
    Linux it imports fine but throws `DllNotFoundException:
    kernel32.dll` the moment you try to actually use it. On Linux/macOS
    with no native 7z on PATH, this script fails outright with install
    instructions rather than pretending 7Zip4Powershell is an option.

.PARAMETER Live
    Download the live ISO (azurelinux-desktop-live.iso). This is the
    default if none of -Live, -Install, -Kvm, -Hyperv, -VirtualBox,
    -VMWare are given.

.PARAMETER Install
    Download the installer ISO (azurelinux-desktop-install.iso). Alias:
    -Installer. Not valid together with -Kvm/-Hyperv/-VirtualBox/-VMWare
    - the installer ISO installs onto whatever disk you point it at, it
    doesn't ship as a pre-built disk image.

.PARAMETER Kvm
    Download a pre-built, expandable qcow2 disk image of the live
    desktop instead of an ISO - boot it directly in QEMU/KVM with no
    install step. Implies the live image; not valid with -Install.
    Alias: -Qcow2.

.PARAMETER Hyperv
    Download a pre-built, expandable VHDX disk image of the live
    desktop instead of an ISO - boot it directly in Hyper-V with no
    install step. Implies the live image; not valid with -Install.
    Ships 7z-compressed; this script decompresses it for you and
    requires a 7-Zip of some kind to do so (see .DESCRIPTION).

.PARAMETER VirtualBox
    Download a pre-built, expandable VDI disk image of the live desktop
    instead of an ISO - attach it to a new VirtualBox VM (EFI enabled)
    with no install step. Implies the live image; not valid with
    -Install. This project doesn't run VirtualBox itself, so this
    format is converted from the same qcow2 as the others but hasn't
    been boot-tested here - see findings/gh-actions-live-iso-build.md.
    Ships 7z-compressed; this script decompresses it for you and
    requires a 7-Zip of some kind to do so (see .DESCRIPTION).

.PARAMETER VMWare
    Download a pre-built, expandable VMDK disk image of the live
    desktop instead of an ISO - attach it to a new VMware Workstation/
    Player VM (EFI enabled) with no install step. Implies the live
    image; not valid with -Install. This project doesn't run VMware
    itself, so this format is converted from the same qcow2 as the
    others but hasn't been boot-tested here - see
    findings/gh-actions-live-iso-build.md. Ships 7z-compressed; this
    script decompresses it for you and requires a 7-Zip of some kind to
    do so (see .DESCRIPTION).

.PARAMETER OutputDirectory
    Where to download parts and write the reassembled file. Defaults to
    the current directory.

.PARAMETER KeepParts
    Keep the downloaded .part files after reassembly instead of deleting
    them. Only applies to the .part files - the intermediate .7z that
    -Hyperv/-VirtualBox/-VMWare reassemble to is always deleted once
    it's been successfully decompressed into the real disk image,
    keeping it around serves no purpose once that's done.

.EXAMPLE
    .\Get-AzureLinuxDesktop.ps1
    .\Get-AzureLinuxDesktop.ps1 -Install
    .\Get-AzureLinuxDesktop.ps1 -Kvm -OutputDirectory C:\vms
    .\Get-AzureLinuxDesktop.ps1 -Hyperv -KeepParts
    .\Get-AzureLinuxDesktop.ps1 -VirtualBox -OutputDirectory C:\vms
    .\Get-AzureLinuxDesktop.ps1 -VMWare -OutputDirectory C:\vms
#>
param(
    [switch]$Live,
    [Alias("Installer")]
    [switch]$Install,
    [Alias("Qcow2")]
    [switch]$Kvm,
    [switch]$Hyperv,
    [switch]$VirtualBox,
    [switch]$VMWare,
    [Alias("OutDir")]
    [string]$OutputDirectory = ".",
    [switch]$KeepParts
)

$ErrorActionPreference = "Stop"
$repo = "sirredbeard/azurelinux-desktop"

# -Kvm/-Hyperv/-VirtualBox/-VMWare only exist for the live desktop image -
# the installer ISO installs onto whatever disk you give it, it has no
# pre-built disk image of its own to ship.
if ($Install -and ($Kvm -or $Hyperv -or $VirtualBox -or $VMWare)) {
    throw "-Install/-Installer can't be combined with -Kvm/-Hyperv/-VirtualBox/-VMWare - the installer ISO doesn't ship as a pre-built disk image."
}
$diskFormatCount = @($Kvm, $Hyperv, $VirtualBox, $VMWare) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count
if ($diskFormatCount -gt 1) {
    throw "-Kvm, -Hyperv, -VirtualBox, and -VMWare are mutually exclusive - pick one disk image format."
}
if ($Live -and $Install) {
    throw "-Live and -Install/-Installer are mutually exclusive - pick one ISO."
}

$useAria2 = [bool](Get-Command aria2c -ErrorAction SilentlyContinue)
if (-not $useAria2) {
    Write-Warning "aria2c not found on PATH - falling back to Invoke-WebRequest (single connection, slower on files this size). Install aria2c for faster downloads: winget install aria2.aria2 (or choco/scoop equivalent)."
}

# baseName/description drive both the GitHub release asset lookup
# (<baseName>.split.NN.part / <baseName>.sha256) and the log/error text
# below, so there's exactly one place that maps a flag combination to
# the asset it corresponds to. VHDX/VDI/VMDK ship 7z-compressed (qemu-
# img has no compression of its own for those three formats), so
# baseName is the .7z the release actually publishes and finalName is
# the disk image that comes out the other side of decompression -
# qcow2 needs neither, it's already zstd-compressed at the qemu-img
# level and ships uncompressed-on-top-of-that.
if ($Kvm) {
    $baseName = "azurelinux-desktop-live.qcow2"
    $finalName = $baseName
    $description = "live qcow2 disk image"
}
elseif ($Hyperv) {
    $finalName = "azurelinux-desktop-live.vhdx"
    $baseName = "$finalName.7z"
    $description = "live VHDX disk image"
}
elseif ($VirtualBox) {
    $finalName = "azurelinux-desktop-live.vdi"
    $baseName = "$finalName.7z"
    $description = "live VDI disk image"
}
elseif ($VMWare) {
    $finalName = "azurelinux-desktop-live.vmdk"
    $baseName = "$finalName.7z"
    $description = "live VMDK disk image"
}
elseif ($Install) {
    $baseName = "azurelinux-desktop-install.iso"
    $finalName = $baseName
    $description = "installer ISO"
}
else {
    $baseName = "azurelinux-desktop-live.iso"
    $finalName = $baseName
    $description = "live ISO"
}
$needsDecompress = $baseName -ne $finalName

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path

Write-Host "Looking up the latest release for $repo..."
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
    -Headers @{ "User-Agent" = "azurelinux-desktop-fetch" }
Write-Host "Latest release: $($release.tag_name)"

$escaped = [regex]::Escape($baseName)
$parts = $release.assets | Where-Object { $_.name -match "^$escaped\.split\.\d+\.part$" } | Sort-Object name
$manifest = $release.assets | Where-Object { $_.name -eq "$baseName.sha256" } | Select-Object -First 1

if (-not $parts) {
    throw "No $description (.split.*.part) assets found on release $($release.tag_name). Expected files named $baseName.split.NN.part."
}
if (-not $manifest) {
    throw "No $baseName.sha256 manifest asset found on release $($release.tag_name)."
}

$isoPath = Join-Path $OutputDirectory $baseName
$finalPath = Join-Path $OutputDirectory $finalName
$manifestPath = Join-Path $OutputDirectory $manifest.name

function Get-WithAria2 {
    param([string]$Url, [string]$Dir, [string]$OutFile)
    # aria2c -x 15 "<url>": 15 connections per file, matching the
    # download convention used throughout this project's scripts.
    # -c resumes a partial transfer if the output file already exists.
    # --max-tries and --retry-wait make transient GitHub asset failures
    # less likely to abort the whole fetch. If aria2c stalls or exits
    # badly, fall back to the single-stream PowerShell download below.
    $argList = @('-x', '15', '-c', '--max-tries=10', '--retry-wait=5', '-d', $Dir, '-o', $OutFile, $Url)
    $proc = Start-Process -FilePath 'aria2c' -ArgumentList $argList -PassThru -WorkingDirectory $Dir
    $completed = $proc.WaitForExit(600000)
    if (-not $completed) {
        Write-Warning "aria2c timed out downloading $Url; falling back to Invoke-WebRequest."
        $proc.Kill()
        Get-WithWebRequest -Url $Url -Dir $Dir -OutFile $OutFile
        return
    }

    if ($proc.ExitCode -ne 0) {
        Write-Warning "aria2c failed downloading $Url (exit $($proc.ExitCode)); falling back to Invoke-WebRequest."
        Get-WithWebRequest -Url $Url -Dir $Dir -OutFile $OutFile
        return
    }
}

function Get-WithWebRequest {
    param([string]$Url, [string]$Dir, [string]$OutFile)
    # Single-stream fallback for when aria2c isn't on PATH or when it
    # stalls on a GitHub release asset redirect. Slower on multi-gigabyte
    # files, but it stays reliable.
    Invoke-WebRequest -Uri $Url -OutFile (Join-Path $Dir $OutFile)
}

function Get-File {
    param([string]$Url, [string]$Dir, [string]$OutFile)
    if ($useAria2) {
        Get-WithAria2 -Url $Url -Dir $Dir -OutFile $OutFile
    }
    else {
        Get-WithWebRequest -Url $Url -Dir $Dir -OutFile $OutFile
    }
}

function Find-SevenZipExecutable {
    # Native 7-Zip binary first, on any OS - 7z is the usual name
    # everywhere (apt/dnf/brew packages, and Windows if it happens to
    # be on PATH), 7zz is the name the official 7-Zip Linux builds use,
    # 7za is the older p7zip standalone name. A native binary needs
    # nothing beyond itself and works identically cross-platform, so
    # it's always preferred over the Windows-only PowerShell module
    # below.
    foreach ($name in @("7z", "7zz", "7za")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    # $IsWindows doesn't exist on Windows PowerShell 5.1 - it's
    # implicitly always Windows there, unlike PowerShell 6+ which runs
    # cross-platform and sets $IsWindows/$IsLinux/$IsMacOS.
    $isWindowsPlatform = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }
    if (-not $isWindowsPlatform) {
        return $null
    }

    # The official 7-Zip Windows installer does not add 7z.exe to PATH
    # by default, so PATH alone isn't enough on Windows - check the
    # registry key it writes and the standard Program Files locations
    # too before giving up on finding a native binary.
    $candidates = @()
    try {
        $regPath = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\7-Zip" -Name "Path" -ErrorAction Stop
        if ($regPath) {
            $candidates += (Join-Path $regPath "7z.exe")
        }
    }
    catch {
        Write-Verbose "7-Zip registry discovery skipped: $($_.Exception.Message)"
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles "7-Zip\7z.exe")
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe")
    }

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Expand-SevenZipArchive {
    param([string]$ArchivePath, [string]$Dir)

    $sevenZip = Find-SevenZipExecutable
    if ($sevenZip) {
        Write-Host "Decompressing with $sevenZip..."
        & $sevenZip x -y "-o$Dir" "$ArchivePath" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "7z extraction of $ArchivePath failed (exit $LASTEXITCODE)."
        }
        return
    }

    $isWindowsPlatform = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }
    if (-not $isWindowsPlatform) {
        throw "No native 7-Zip found ($ArchivePath needs decompressing) and 7Zip4Powershell doesn't work outside Windows - confirmed it imports fine on Linux but throws DllNotFoundException: kernel32.dll the moment it's actually used, it's a wrapper around native Windows 7-Zip DLLs. Install 7-Zip and re-run: apt install 7zip (Debian/Ubuntu), dnf install 7zip (Fedora), or brew install sevenzip (macOS)."
    }

    Write-Warning "No native 7-Zip found on PATH or in the usual Windows install locations - falling back to the 7Zip4Powershell PowerShell Gallery module (installing it if needed). Installing 7-Zip itself (https://www.7-zip.org/) is recommended - it's faster and this fallback won't be needed next time."
    if (-not (Get-Module -ListAvailable -Name 7Zip4Powershell)) {
        Install-Module -Name 7Zip4Powershell -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module 7Zip4Powershell -ErrorAction Stop
    Expand-7Zip -ArchiveFileName $ArchivePath -TargetPath $Dir
}


Write-Host "Downloading manifest: $($manifest.name)"
Get-File -Url $manifest.browser_download_url -Dir $OutputDirectory -OutFile $manifest.name

$partPaths = @()
foreach ($part in $parts) {
    Write-Host "Downloading part: $($part.name) ($([math]::Round($part.size / 1MB, 1)) MiB)"
    Get-File -Url $part.browser_download_url -Dir $OutputDirectory -OutFile $part.name
    $partPaths += (Join-Path $OutputDirectory $part.name)
}

Write-Host "Reassembling $($partPaths.Count) parts into $baseName..."
$outStream = [System.IO.File]::Create($isoPath)
try {
    foreach ($partPath in $partPaths) {
        $inStream = [System.IO.File]::OpenRead($partPath)
        try {
            $inStream.CopyTo($outStream)
        }
        finally {
            $inStream.Dispose()
        }
    }
}
finally {
    $outStream.Dispose()
}

Write-Host "Verifying sha256 against the published manifest..."
$expected = (Get-Content $manifestPath -Raw).Split(" ")[0].Trim()
$actual = (Get-FileHash -Path $isoPath -Algorithm SHA256).Hash.ToLower()

if ($expected -ne $actual) {
    throw "Checksum mismatch. Expected $expected, got $actual. The reassembled file is not trustworthy, delete it and try again."
}

Write-Host "Checksum OK: $actual"

if ($needsDecompress) {
    Write-Host "Decompressing $baseName into $finalName..."
    Expand-SevenZipArchive -ArchivePath $isoPath -Dir $OutputDirectory
    if (-not (Test-Path $finalPath)) {
        throw "Decompressed $isoPath but $finalPath wasn't produced - the archive's contents don't match the expected file name."
    }
    Write-Host "Removing intermediate archive $baseName..."
    Remove-Item -Path $isoPath -Force
}

Write-Host "$description ready at $finalPath"

if (-not $KeepParts) {
    Write-Host "Cleaning up downloaded .part files..."
    $partPaths | Remove-Item -Force
}
