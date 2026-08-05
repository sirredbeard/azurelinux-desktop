# RPM OpenPGP keys staged into images

These keys are installed to `/etc/pki/rpm-gpg/` on live, disk, installer
target, and canary images by `scripts/install-rpm-gpg-keys.sh`. Repo
files use `gpgcheck=1` and `gpgkey=file:///etc/pki/rpm-gpg/...`.

| File | Used by |
| --- | --- |
| `RPM-GPG-KEY-azurelinux-4.0-*` | Azure Linux base/microsoft (`azurelinux.repo`) |
| `RPM-GPG-KEY-azurelinux-desktop` | Project Pages kmod repo |
| `RPM-GPG-KEY-fedora-43-primary` | `fedora43`, `fedora43-updates` |
| `RPM-GPG-KEY-microsoft` | ms-prod, vscode, edge-canary |
| `RPM-GPG-KEY-githubcli` | gh-cli |
| `RPM-GPG-KEY-shiftkey-desktop` | github-desktop |
| `RPM-GPG-KEY-rpmfusion-*-fedora-2020` | rpmfusion-free/nonfree |

Do not leave third-party desktop repos at `gpgcheck=0` once the matching
key is here. Refresh keys from upstream when Fedora major or vendor
keyrings rotate.
