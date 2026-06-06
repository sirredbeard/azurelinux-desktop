param(
    [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$ImageTag = "azurelinux-xfce-xrdp:4.0",
    # wslc image stores are per-session. Empty = the default session (manual
    # builds). The app passes its own session name so the image lands where
    # the container actually runs.
    [string]$Session = ""
)

$ErrorActionPreference = "Stop"

$wslcDefaultPath = "C:\Program Files\WSL\wslc.exe"
$wslc = if (Get-Command wslc.exe -ErrorAction SilentlyContinue) {
    (Get-Command wslc.exe).Source
} elseif (Test-Path $wslcDefaultPath) {
    $wslcDefaultPath
} else {
    throw "wslc not found. Build WSL from main (with wslc support) and/or add C:\Program Files\WSL to PATH."
}

$containerDir = Join-Path $WorkspaceRoot "container"

# Stage the Bluecurve theme out of the external/Bluecurve submodule. The
# build context is container/ and COPY cannot reach outside it, so the theme
# is copied into container\.bluecurve (gitignored) before each build.
$bluecurve = Join-Path $WorkspaceRoot "external\Bluecurve"
if (-not (Test-Path (Join-Path $bluecurve "themes"))) {
    throw "Bluecurve submodule not found at $bluecurve. Run: git submodule update --init --recursive"
}
$staging = Join-Path $containerDir ".bluecurve"
Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $staging | Out-Null
foreach ($dir in "themes", "icons", "fonts", "wallpapers") {
    Copy-Item (Join-Path $bluecurve $dir) $staging -Recurse
}
# Azure Linux penguin for the panel's applications menu button.
Copy-Item (Join-Path $WorkspaceRoot "AzureLinuxDesktop.App\Assets\AzureLinuxLogo.png") (Join-Path $staging "azurelinux-logo.png")

$sessionArgs = @()
if ($Session) { $sessionArgs = @("--session", $Session) }

& $wslc build @sessionArgs -t $ImageTag -f (Join-Path $containerDir "Dockerfile") $containerDir
if ($LASTEXITCODE -ne 0) { throw "wslc build failed with exit code $LASTEXITCODE." }
& $wslc images @sessionArgs | Out-Host

Write-Host "Image built: $ImageTag"
