# "Azure Linux Desktop"

**Azure Linux 4, WinUI 3, wslc, Microsoft UI Reactor, .NET 10, and XRDP**

This is a fun thing that brings together a handful of the projects highlighted at Microsoft Build 2026.

This app is a .NET 10-based WinUI 3 app built using
[Microsoft UI Reactor](https://github.com/microsoft/microsoft-ui-reactor) (no XAML). On launch it starts an
embedded [wslc](https://www.boxofcables.dev/wslc-a-native-linux-container-runtime-for-windows/) container
based on [Azure Linux 4.0](https://github.com/microsoft/azurelinux), and boots to a fun XFCE desktop.

The purpose is to show off:

* The [wslc API](https://www.boxofcables.dev/wslc-a-native-linux-container-runtime-for-windows/)
* [Azure Linux 4.0](https://github.com/microsoft/azurelinux)
* [Microsoft UI Reactor](https://github.com/microsoft/microsoft-ui-reactor)

This is a one-off toy. Do not expect ongoing maintenance of this project. The build steps require building
unstable WSL from main to get wslc early (yay open source!). wslc will be available in a few weeks via
`wsl.exe --update --pre-release` before it GA's into WSL officially.

[Azure Linux 4.0](https://github.com/microsoft/azurelinux) doesn't include desktop/GUI packages, but
because it's based on a snapshot of Fedora Linux 43, shoving them in from Fedora repos *sort of* works
(yay open source!). This is a bad hack. **Do not do this in production.**

This is also built with an early build from source of
[Microsoft UI Reactor](https://github.com/microsoft/microsoft-ui-reactor). Again, this is a one-off.
Expect breaking changes from upstream.

I was inspired in part by [@craigloewen-msft](https://github.com/craigloewen-msft)'s [Herbert demo](https://x.com/unixterminal/status/2061906163588051193?s=20).

I have themed the XFCE 4 desktop with a recreation of the [Bluecurve theme](https://github.com/neeeeow/Bluecurve)
by [@neeeeow](https://github.com/neeeeow), for nostalgia reasons. IYKYK.

The image also installs [Visual Studio Code](https://code.visualstudio.com/) because a desktop needs an
editor. And PowerShell.

## Minimum Requirements

- Windows 10 22H2 (build 19045) or later, Windows 11 recommended
- .NET SDK 10
- Visual Studio 2022 or newer with the components from `external\WSL\.vsconfig` (Desktop C++, Clang/LLVM,
  Windows SDK 10.0.26100.0) and the .NET WinUI app development tools
- CMake 3.25+

The fastest way to get all the dependencies in place is to run the setup script:

```powershell
.\scripts\Setup-BuildEnv.ps1
```

## Some Cool Things

- Audio should work
- GPU acceleration should work
- Copy and paste should work
- The display supports dynamic resizing
- The container comes with VS Code and PowerShell pre-installed

## Building

### 1. Clone with submodules

```powershell
git clone --recurse-submodules https://github.com/sirredbeard/azurelinux-desktop
cd azurelinux-desktop
```

### 2. Build and install WSL from source

There is no public preview of wslc yet. Build WSL from the `external/WSL` submodule and install it. This
replaces the system WSL with a fresh build from main. *You should probably not do this.*

```powershell
# Run as Administrator. The deploy step installs the MSI.
.\scripts\Build-Wsl.ps1
```

This takes a minute. It configures the WSL build tree with the C# SDK targets enabled, builds everything,
installs `wsl.msi`, and copies the SDK artifacts to `artifacts\wslc\`.

Confirm it worked:

```powershell
wsl --version
wslc version
```

### 3. Confirm the wslc SDK artifacts

The app project enables the wslc SDK automatically when the artifacts from step 2 exist, so there is
nothing to edit. Confirm these three files exist in `artifacts\wslc\` before building:

- `wslcsdk.dll`
- `wslcsdkcs.dll`
- `Microsoft.WSL.Containers.winmd`

If you rebuild WSL later and only need to refresh the SDK artifacts, run `scripts\Build-WslcSdk.ps1`. It
targets only the C# SDK and skips the full build.

### 4. Build the Azure Linux XRDP container image

```powershell
.\scripts\Build-AzureLinuxRdpImage.ps1
```

The app runs this automatically on first launch if the image is missing. Building it ahead of time just
makes the first launch fast.

Confirm the image is registered:

```powershell
wslc images
```

You should see `azurelinux-xfce-xrdp:4.0` in the output.

### 5. Build and run the app

```powershell
dotnet build .\AzureLinuxDesktop.slnx
dotnet run --project .\AzureLinuxDesktop.App
```

### 6. Optional: publish a release build

```powershell
dotnet publish .\AzureLinuxDesktop.App -c Release -r win-arm64   # or win-x64
```

## License

Code original to this repository is MIT licensed. The container image pulls in PowerShell, Visual Studio
Code, a community Bluecurve theme, and packages from Azure Linux and Fedora, each under its own license.
See [LICENSE.md](LICENSE.md) for the full text and acknowledgements.

This is a personal demo project. It is not affiliated with, sponsored by, or endorsed by Microsoft, the
Fedora Project, Red Hat, or any other project named here. Microsoft, Windows, Azure, Visual Studio Code,
and PowerShell are trademarks of the Microsoft group of companies. Fedora is a trademark of Red Hat, Inc.
The Bluecurve look originated at Red Hat, and this project uses the open recreation by @neeeeow. Linux is
the registered trademark of Linus Torvalds in the United States and other countries. All other trademarks,
logos, and copyrights belong to their respective owners, and I claim no ownership of any of them.
