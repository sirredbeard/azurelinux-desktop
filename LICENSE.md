# License

Code original to this repository is licensed under the MIT License below. The projects this demo builds on keep their own licenses, acknowledged in the section after it.

## MIT License

Copyright (c) 2026 Hayden Barnes

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Third-party components

The container image and build scripts pull in software from other projects. Each keeps its own license. Nothing from these projects is vendored into this repository except the PowerShell icon noted below.

- **PowerShell** is MIT licensed at [github.com/PowerShell/PowerShell](https://github.com/PowerShell/PowerShell). The image unpacks the official Linux release tarball, and this repository carries `assets/Powershell_256.png` from that project as `container/powershell-icon.png` for the panel launcher.
- **Visual Studio Code** is distributed under the [Microsoft Software License Terms](https://code.visualstudio.com/license) and installed from packages.microsoft.com. The Code - OSS source it builds from is MIT licensed at [github.com/microsoft/vscode](https://github.com/microsoft/vscode).
- **WSL and wslc** are MIT licensed at [github.com/microsoft/WSL](https://github.com/microsoft/WSL). The build scripts compile them from source.
- **Bluecurve**, the theme recreation by neeeeow, is GPL-3.0 licensed at [github.com/neeeeow/Bluecurve](https://github.com/neeeeow/Bluecurve). It is fetched as the `external/Bluecurve` submodule and copied into the image at build time.
- **Azure Linux** packages come from [github.com/microsoft/azurelinux](https://github.com/microsoft/azurelinux). Every package carries its respective upstream license.
- **Fedora** packages, including xrdp and the XFCE desktop, come from the Fedora project. Every package carries its respective upstream license.
- **pipewire-module-xrdp** is built from source at [github.com/neutrinolabs/pipewire-module-xrdp](https://github.com/neutrinolabs/pipewire-module-xrdp) under its upstream license.

## Trademarks

This is a personal demo project, not affiliated with, sponsored by, or endorsed by Microsoft, the Fedora Project, Red Hat, or any other project named here. Microsoft, Windows, Azure, Visual Studio Code, and PowerShell are trademarks of the Microsoft group of companies. Fedora is a trademark of Red Hat, Inc. The Bluecurve look originated at Red Hat. Linux is the registered trademark of Linus Torvalds in the United States and other countries. All other trademarks, logos, and copyrights belong to their respective owners, and no ownership of any of them is claimed.
