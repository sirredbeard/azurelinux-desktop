<#
.SYNOPSIS
    Installs all prerequisites for building the Azure Linux Desktop project.
.DESCRIPTION
    Checks and installs each minimum requirement from README.md:
      - Windows 10 or newer (check only)
      - Developer Mode enabled (required for WSL build symlinks)
      - Git with submodules initialized
      - .NET SDK 10
      - Visual Studio 2022 or newer with C++ Desktop, Windows SDK 26100, and WinUI workloads
      - CMake 3.25 or newer

    Run this before Build-Wsl.ps1. A UAC prompt will appear for the VS installer
    and Developer Mode steps.
.EXAMPLE
    .\scripts\Setup-BuildEnv.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$vsConfig      = Join-Path $workspaceRoot "external\WSL\.vsconfig"
$vsWhere       = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstaller   = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"

function Check([string]$label) { Write-Host "  [ ] $label" -ForegroundColor Cyan }
function Pass([string]$label)  { Write-Host "  [x] $label" -ForegroundColor Green }
function Warn([string]$label)  { Write-Host "  [!] $label" -ForegroundColor Yellow }
function Fail([string]$label)  { Write-Host "  [!] $label" -ForegroundColor Red }

Write-Host ""
Write-Host "Azure Linux Desktop — build environment setup" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor White
Write-Host ""

# ── 1. Windows version ───────────────────────────────────────────────
Check "Windows 10 or newer"
$build = [System.Environment]::OSVersion.Version
if ($build.Major -ge 10) {
    Pass "Windows $($build.Major).$($build.Minor) build $($build.Build)"
} else {
    throw "Windows 10 or newer is required. Current version: $build"
}

# ── 2. Developer Mode (WSL build needs symlink support) ──────────────
# Note: under Set-StrictMode, reading a property that does not exist on the
# Get-ItemProperty result throws — and AllowDevelopmentWithoutDevLicense is
# absent (not 0) on machines where Developer Mode has never been toggled.
# Treat "key missing", "value missing", and "value 0" all as disabled.
function Test-DeveloperMode {
    try {
        return (Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" `
            -Name AllowDevelopmentWithoutDevLicense -ErrorAction Stop) -eq 1
    } catch {
        return $false
    }
}

Check "Developer Mode"
if (Test-DeveloperMode) {
    Pass "Developer Mode is enabled"
} else {
    Warn "Developer Mode is off — enabling (a UAC prompt will appear)..."
    Start-Process powershell -Verb RunAs -Wait -ArgumentList `
        "-NoProfile -Command `"New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Force | Out-Null; Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' AllowDevelopmentWithoutDevLicense 1 -Type DWord`""
    if (Test-DeveloperMode) {
        Pass "Developer Mode enabled"
    } else {
        Fail "Could not enable Developer Mode (the WSL build needs it for symlink support)."
        Write-Host ""
        Write-Host "  Enable it manually, then re-run this script:" -ForegroundColor Yellow
        Write-Host "    Settings → System → For developers → Developer Mode → On" -ForegroundColor Yellow
        Write-Host "  or from an elevated PowerShell:" -ForegroundColor Yellow
        Write-Host "    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' AllowDevelopmentWithoutDevLicense 1 -Type DWord" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

# ── 3. Git + submodules ──────────────────────────────────────────────
Check "Git"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git not found. Install it from https://git-scm.com or: winget install Git.Git"
}
Pass "git $(git --version)"

Check "Submodules initialized"
if (-not (Test-Path $vsConfig)) {
    Warn "Submodules not initialized. Running: git submodule update --init --recursive"
    Push-Location $workspaceRoot
    git submodule update --init --recursive
    Pop-Location
}
if (Test-Path $vsConfig) { Pass "Submodules present" }
else { throw "Submodule init failed. Run: git submodule update --init --recursive" }

# ── 4. .NET SDK 10 ───────────────────────────────────────────────────
Check ".NET SDK 10"
$dotnetVersion = dotnet --version 2>$null
if ($dotnetVersion -and $dotnetVersion.StartsWith("10.")) {
    Pass ".NET SDK $dotnetVersion"
} else {
    Warn ".NET SDK 10 not found (found: $dotnetVersion). Installing..."
    winget install --id Microsoft.DotNet.SDK.10 --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw ".NET SDK 10 install failed. Install manually: winget install Microsoft.DotNet.SDK.10" }
    Pass ".NET SDK 10 installed. Open a new terminal if dotnet is not found after this script."
}

# ── 5. Visual Studio with required workloads ─────────────────────────
Check "Visual Studio 2022 or newer"
if (-not (Test-Path $vsWhere)) {
    Warn "Visual Studio not found. Installing VS 2022 Community..."
    winget install --id Microsoft.VisualStudio.2022.Community --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "VS install failed. Install manually from https://visualstudio.microsoft.com" }
}

$vsInfo = & $vsWhere -all -latest -format json 2>$null | ConvertFrom-Json
if (-not $vsInfo) { throw "No Visual Studio installation found after install attempt." }
$vsPath  = $vsInfo.installationPath
$vsMajor = [int]($vsInfo.installationVersion.Split('.')[0])
if ($vsMajor -lt 17) { throw "Visual Studio 2022 (v17) or newer is required. Found version $vsMajor." }
Pass $vsInfo.displayName

Check "VS components from external\WSL\.vsconfig (C++ Desktop, Clang/LLVM, Windows SDK 26100, WinUI)"
# Check every component the WSL build's .vsconfig declares — checking a single
# marker component (the old behavior) reports success while still missing
# pieces CMake hard-requires, e.g. VC.Llvm.Clang.
#
# Some component IDs differ across VS releases: the Spectre-mitigated libs
# live under VC.Runtimes.* in current VS 2022 and VS 2026 catalogs, while the
# WSL .vsconfig declares the legacy VC.Tools.* spellings. The installer
# silently ignores IDs it does not know (and still exits 0), so never guess
# from the version number: track every known spelling per component, install
# with all of them, and count the component present when any spelling is.
$componentAliases = @{
    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64.Spectre" = "Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre"
    "Microsoft.VisualStudio.Component.VC.Tools.ARM64.Spectre"   = "Microsoft.VisualStudio.Component.VC.Runtimes.ARM64.Spectre"
}
# Each entry is the array of acceptable spellings for one required component.
$requiredComponents = @((Get-Content $vsConfig -Raw | ConvertFrom-Json).components | ForEach-Object {
    , @(@($_) + @($componentAliases[$_]) | Where-Object { $_ })
})
function Test-VsComponentInstalled([string[]] $ids) {
    foreach ($id in $ids) {
        if (& $vsWhere -all -latest -prerelease -products * -requires $id -property installationPath 2>$null) {
            return $true
        }
    }
    return $false
}
$missing = @($requiredComponents | Where-Object { -not (Test-VsComponentInstalled $_) })
if (-not $missing) {
    Pass "All $($requiredComponents.Count) required VS components already installed"
} else {
    Warn "Missing VS components: $(($missing | ForEach-Object { $_[0] }) -join ', ')"
    Warn "Running VS installer to add them (UAC prompt will appear; this can take a while)..."
    # --add every spelling of each missing component; the installer ignores
    # the spellings this VS release does not know. --config with the raw
    # .vsconfig would only feed it the legacy IDs.
    $addArgs = (@($missing | ForEach-Object { $_ }) | ForEach-Object { "--add $_" }) -join " "
    $modifyArgs = "modify --installPath `"$vsPath`" $addArgs --quiet --norestart --force"
    $proc = Start-Process -FilePath $vsInstaller -ArgumentList $modifyArgs -Verb RunAs -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "VS installer exited with code $($proc.ExitCode). Open Visual Studio Installer and manually import external\WSL\.vsconfig."
    }
    # Don't trust the exit code alone — setup.exe exits 0 when another
    # installer instance holds the singleton lock and nothing was installed.
    # Re-verify against the .vsconfig before declaring success.
    $stillMissing = @($missing | Where-Object { -not (Test-VsComponentInstalled $_) })
    if ($stillMissing) {
        Fail "VS components still missing after the installer ran: $(($stillMissing | ForEach-Object { $_[0] }) -join ', ')"
        Write-Host ""
        Write-Host "  If another Visual Studio Installer window is already running (its singleton" -ForegroundColor Yellow
        Write-Host "  lock blocks this one), wait for it to finish and re-run this script." -ForegroundColor Yellow
        Write-Host "  Otherwise open Visual Studio Installer manually and import external\WSL\.vsconfig." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
    Pass "VS components installed"
}

# ── 6. CMake 3.25+ ───────────────────────────────────────────────────
Check "CMake 3.25 or newer"
$cmakeVer = cmake --version 2>$null | Select-Object -First 1
if ($cmakeVer) {
    $verNum = [version](($cmakeVer -replace '[^0-9.]','').Trim('.'))
    if ($verNum -ge [version]"3.25") {
        Pass $cmakeVer
    } else {
        Warn "CMake $verNum is too old (need 3.25+). Updating..."
        winget install --id Kitware.CMake --silent --accept-package-agreements --accept-source-agreements
        Pass "CMake updated. Open a new terminal if cmake is not found after this script."
    }
} else {
    Warn "CMake not found. Installing..."
    winget install --id Kitware.CMake --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "CMake install failed. Install manually: winget install Kitware.CMake" }
    Pass "CMake installed. Open a new terminal if cmake is not found after this script."
}

Write-Host ""
Write-Host "All prerequisites satisfied." -ForegroundColor Green
Write-Host "Next: run .\scripts\Build-Wsl.ps1 (as Administrator for the deploy step)." -ForegroundColor White
Write-Host ""
