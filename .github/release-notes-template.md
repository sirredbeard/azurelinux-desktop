## Azure Linux Desktop Proof of Concept

This puts a real GNOME desktop from [Fedora](https://fedoraproject.org/) on top of Microsoft's [Azure Linux 4.0](https://github.com/microsoft/azurelinux).

* [Azure Linux](https://github.com/microsoft/AzureLinux) 4.0 base
* [GNOME](https://www.gnome.org/) from [Fedora](https://fedoraproject.org/)
* [Microsoft VS Code Insiders](https://code.visualstudio.com/insiders/)
* [GitHub CLI](https://github.com/cli/cli)
* [GitHub Copilot CLI](https://github.com/github/copilot-cli)
* [GitHub Copilot App](https://github.com/github/app)
* [Github Desktop](https://github.com/shiftkey/desktop) (Linux fork by [Shiftkey](https://github.com/shiftkey/))
* [PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/linux-overview) (default shell)
* [Edit](https://github.com/microsoft/edit) (default terminal editor)
* [.NET 11 Runtime and SDK](https://dotnet.microsoft.com/en-us/download/dotnet/11.0)
* [Microsoft Edge Canary](https://explore.microsoft.com/en-us/edge) (default web browser)
* [GNOME Evolution](https://help.gnome.org/evolution/mail-account-manage-microsoft-exchange.html) with Exchange support

The package mixing required to accomplish this *will likely result in broken dependencies at some point*. Be prepared to handle that. **I do not recommend running this in production.** That's why live ISOs and VM images are available for you to explore this. An installer ISO is available if you dare to install on bare metal.

This is a personal side project, explored for fun. **It is not affiliated with, sponsored by, or endorsed by Microsoft, the Fedora Project, Red Hat, the GNOME Foundation, or GitHub.** 

## Download tl;dr

**PowerShell:**
```powershell
irm https://raw.githubusercontent.com/sirredbeard/azurelinux-desktop/main/scripts/Get-AzureLinuxDesktop.ps1 -OutFile Get-AzureLinuxDesktop.ps1
./Get-AzureLinuxDesktop.ps1 -Live
```

Swap `-Live` for whichever you want:

| Flag | Description |
| --- | --- |
| `-Live` | Live desktop ISO (default, boot/try it, no install) |
| `-Install` | Installer ISO (installs to a real or virtual disk) |
| `-Kvm` | Live desktop, pre-built qcow2 for QEMU/KVM |
| `-Hyperv` | Live desktop, pre-built VHDX for Hyper-V |
| `-VirtualBox` | Live desktop, pre-built VDI for VirtualBox |
| `-VMWare` | Live desktop, pre-built VMDK for VMware |

Don't have [PowerShell](https://github.com/PowerShell/PowerShell)? [Get it](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell).

See [README](https://github.com/sirredbeard/azurelinux-desktop#readme) for more.

## License

Code original to this repository is MIT licensed. The built images pull in Azure Linux, Fedora, GNOME, PowerShell, Visual Studio Code Insiders, Microsoft Edge Canary, .NET, GitHub CLI, GitHub Desktop, GitHub Copilot CLI, GitHub Copilot, and edit, each under its own license - see [LICENSE](https://github.com/sirredbeard/azurelinux-desktop/blob/main/LICENSE) in the repo for the full text, per-component attribution, and trademark disclaimers.