param(
    [ValidateSet("x64", "arm64")]
    # Default to the host architecture — deploying an x64 MSI on an ARM64
    # host (or vice versa) fails at install time.
    [string]$Platform = $(if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq "Arm64") { "arm64" } else { "x64" }),
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [switch]$SkipDeploy,
    [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

# The deploy step installs an MSI and requires elevation.
# Re-launch as admin if needed and deploy wasn't explicitly skipped.
if (-not $SkipDeploy) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "Elevation required for MSI install. Re-launching as Administrator..."
        Write-Host "Output is also logged to artifacts\build-wsl.log in case the elevated window closes."
        $logPath = Join-Path $WorkspaceRoot "artifacts\build-wsl.log"
        New-Item -ItemType Directory -Force (Split-Path $logPath) | Out-Null
        # -Command (not -File) so output can be teed to a log, the window stays
        # readable on failure, and the real exit code propagates back out.
        $inner = "try { & '$($MyInvocation.MyCommand.Path)' -Platform $Platform -Configuration $Configuration -WorkspaceRoot '$WorkspaceRoot' *>&1 | Tee-Object -FilePath '$logPath'; exit 0 } " +
                 "catch { `$_ | Out-String | Tee-Object -FilePath '$logPath' -Append; Write-Host 'Build failed - see $logPath' -ForegroundColor Red; Read-Host 'Press Enter to close'; exit 1 }"
        $proc = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $inner)
        exit $proc.ExitCode
    }
}

function Require-Tool([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Missing required tool '$name'. Run .\scripts\Setup-BuildEnv.ps1 to install prerequisites."
    }
}

Require-Tool git
Require-Tool cmake

$wslRepo = Join-Path $WorkspaceRoot "external\WSL"
if (-not (Test-Path (Join-Path $wslRepo "CMakeLists.txt"))) {
    throw "WSL submodule not found at $wslRepo. Run: git submodule update --init --recursive"
}

Push-Location $wslRepo
try {
    # Configure UserConfig.cmake to include C# SDK and enable thin package for faster builds
    if (-not (Test-Path "UserConfig.cmake")) {
        Copy-Item "UserConfig.cmake.sample" "UserConfig.cmake"
    }

    # Match only *active* set() lines — UserConfig.cmake.sample ships these
    # settings as comments, so a bare substring match would always "find" them
    # and silently skip enabling the C# SDK build.
    $userConfig = Get-Content "UserConfig.cmake" -Raw
    $additions = @()
    foreach ($setting in "WSL_INCLUDE_SDK_CSHARP", "WSL_NUGET_SINGLE_PLATFORM", "WSL_BUILD_THIN_PACKAGE") {
        if ($userConfig -notmatch "(?m)^\s*set\($setting\b") {
            $additions += "set($setting true)"
        }
    }
    if ($additions) {
        Add-Content "UserConfig.cmake" ("`n" + ($additions -join "`n") + "`n")
    }

    # Detect the installed Visual Studio version for the cmake generator
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vsWhere)) {
        throw "vswhere.exe not found. Install Visual Studio 2022 or newer with Desktop C++ and Windows SDK 26100."
    }
    # -products * -prerelease widens the search; note vswhere reports an
    # instance as incomplete (and hides it) while the VS installer is actively
    # modifying it, so a "not found" here can be transient.
    $vsInfo = & $vsWhere -latest -products * -prerelease -requires Microsoft.Component.MSBuild -format json 2>$null | ConvertFrom-Json
    if (-not $vsInfo) {
        throw ("No usable Visual Studio installation found. If the Visual Studio Installer is currently " +
               "installing or modifying VS, wait for it to finish and re-run this script. Otherwise run " +
               ".\scripts\Setup-BuildEnv.ps1 to install Visual Studio with the required components.")
    }
    $vsMajor = [int]($vsInfo.installationVersion.Split('.')[0])
    # Map major version to cmake generator name: 17=VS2022, 18=VS2026, etc.
    $vsYear = switch ($vsMajor) {
        16 { "2019" }
        17 { "2022" }
        18 { "2026" }
        default { throw "Unknown Visual Studio major version $vsMajor. Update Build-Wsl.ps1." }
    }
    Write-Host "Detected: $($vsInfo.displayName)"

    # Lowercase "arm64" — WSL's CMakeLists matches CMAKE_GENERATOR_PLATFORM
    # against "arm64" case-sensitively (uppercase ARM64 hits the
    # "Unsupported platform" FATAL_ERROR); the VS generator itself doesn't care.
    $targetPlatform = if ($Platform -eq "arm64") { "arm64" } else { "x64" }
    $cmakeArgs = @("-G", "Visual Studio $vsMajor $vsYear", "-DCMAKE_BUILD_TYPE=$Configuration", "-A", $targetPlatform)

    # A previous configure with a different -A platform poisons the cache and
    # CMake refuses to reconfigure ("generator platform ... does not match").
    # Detect the mismatch and clean the stale cache instead of failing.
    if (Test-Path "CMakeCache.txt") {
        $cached = (Select-String -Path "CMakeCache.txt" -Pattern '^CMAKE_GENERATOR_PLATFORM:[^=]*=(.+)$' |
            Select-Object -First 1).Matches.Groups[1].Value
        # -cne: CMake compares the generator platform case-sensitively, so an
        # "ARM64" cache poisons an "arm64" configure even though PowerShell's
        # default -ne would call them equal.
        if ($cached -and $cached -cne $targetPlatform) {
            Write-Host "CMake cache was configured for '$cached' but target is '$targetPlatform' — removing stale CMakeCache.txt/CMakeFiles..."
            Remove-Item "CMakeCache.txt" -Force
            Remove-Item "CMakeFiles" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Native commands do not honor $ErrorActionPreference — check exit codes
    # explicitly so a failed configure/build stops here instead of rolling
    # into the deploy step.
    Write-Host "Configuring WSL build..."
    cmake . @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed with exit code $LASTEXITCODE." }

    Write-Host "Building WSL (this takes 20-45 minutes)..."
    cmake --build . -- -m
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed with exit code $LASTEXITCODE." }

    if (-not $SkipDeploy) {
        Write-Host "Installing WSL from built MSI..."
        & powershell -ExecutionPolicy Bypass -File "tools\deploy\deploy-to-host.ps1" `
            -BuildType $Configuration -BuildOutputPath $wslRepo
        if ($LASTEXITCODE -ne 0) { throw "deploy-to-host.ps1 failed with exit code $LASTEXITCODE." }

        # Shut down any VMs left over from the previous WSL install - stale
        # HNS/NAT state from the old version breaks wslc session networking
        # with an opaque E_UNEXPECTED (GNS route-add failure).
        Write-Host "Shutting down running WSL VMs so the new install starts clean..."
        wsl --shutdown
        Write-Host "WSL installed. Verify with: wsl --version"
    }

    # Copy C# SDK artifacts to the app's artifacts directory
    $binPath = Join-Path $wslRepo "bin\$Platform\$Configuration"
    $artifacts = Join-Path $WorkspaceRoot "artifacts\wslc"
    New-Item -ItemType Directory -Path $artifacts -Force | Out-Null

    foreach ($file in @("wslcsdk.dll", "wslcsdkcs.dll", "Microsoft.WSL.Containers.winmd")) {
        $src = Join-Path $binPath $file
        if (Test-Path $src) {
            Copy-Item $src $artifacts -Force
            Write-Host "Copied: $file"
        } else {
            Write-Warning "Not found: $src (build may not have produced this target)"
        }
    }

    Write-Host ""
    Write-Host "Done. Next: set <EnableWslcSdk>true</EnableWslcSdk> in AzureLinuxDesktop.App.csproj then dotnet build."
}
finally {
    Pop-Location
}
