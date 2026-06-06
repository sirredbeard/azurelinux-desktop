# Builds only the wslc C# SDK targets from an already-configured WSL build tree.
# Run Build-Wsl.ps1 first to do the full WSL build and install wslc itself.

param(
    [ValidateSet("x64", "arm64")]
    # Default to the host architecture, matching Build-Wsl.ps1.
    [string]$Platform = $(if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq "Arm64") { "arm64" } else { "x64" }),
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

function Require-Tool([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Missing required tool '$name'. Run external\WSL\tools\setup-dev-env.ps1 to install prerequisites."
    }
}

Require-Tool cmake

$wslRepo = Join-Path $WorkspaceRoot "external\WSL"
$artifacts = Join-Path $WorkspaceRoot "artifacts\wslc"

if (-not (Test-Path (Join-Path $wslRepo "CMakeLists.txt"))) {
    throw "WSL submodule not found at $wslRepo. Run: git submodule update --init --recursive"
}

Push-Location $wslRepo
try {
    # Build only the C# SDK targets — assumes cmake . was already run by Build-Wsl.ps1
    cmake --build . --config $Configuration --target wslcsdk wslcsdkcs
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed with exit code $LASTEXITCODE." }

    $binPath = Join-Path $wslRepo "bin\$Platform\$Configuration"
    if (-not (Test-Path $binPath)) {
        throw "Build output not found at $binPath. Run Build-Wsl.ps1 first to configure and build the full WSL tree."
    }

    New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
    Copy-Item (Join-Path $binPath "wslcsdk.dll") $artifacts -Force
    Copy-Item (Join-Path $binPath "wslcsdkcs.dll") $artifacts -Force
    Copy-Item (Join-Path $binPath "Microsoft.WSL.Containers.winmd") $artifacts -Force

    Write-Host "wslc SDK artifacts copied to: $artifacts"
    Write-Host "Set <EnableWslcSdk>true</EnableWslcSdk> in AzureLinuxDesktop.App.csproj before building the app."
}
finally {
    Pop-Location
}
