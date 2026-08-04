# RPM / DNF GPG signing (desktop kmod Pages repo)

Same OpenPGP key as the Copilot Flatpak Pages stream
(`sirredbeard/copilot-desktop-gtk`). One key, two products:

* Flatpak OSTree tips on `copilot-desktop-gtk` Pages
* Desktop kmod RPMs on `azurelinux-desktop` Pages
  (`https://sirredbeard.github.io/azurelinux-desktop/repo/`)

## Why sign RPMs

Images used `gpgcheck=0` on `azl-desktop-kmods` while the repo was
unsigned. With package signatures and a seeded public key, clients can
use `gpgcheck=1` like any other DNF repo.

## Files

- `public.asc` / `keyid.txt` - public material (committed here)
- `assets/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop` - same public key
  staged into images at `/etc/pki/rpm-gpg/`
- Private key is **not** in git

## Actions secrets (`sirredbeard/azurelinux-desktop`)

| Secret | Contents |
| --- | --- |
| `FLATPAK_GPG_PRIVATE_KEY` | Armored private key (shared with copilot-desktop-gtk) |
| `FLATPAK_GPG_PUBLIC_KEY` | Armored public key |
| `FLATPAK_GPG_KEY_ID` | Short id (e.g. `C997DB034A0C0179`) |

Names match the Copilot app repo on purpose. Values are the same key.
GitHub never returns secret values after set.

```bash
gh secret list -R sirredbeard/azurelinux-desktop
# re-upload from a machine that still has the private key:
gh secret set FLATPAK_GPG_PRIVATE_KEY -R sirredbeard/azurelinux-desktop < private.asc
gh secret set FLATPAK_GPG_PUBLIC_KEY -R sirredbeard/azurelinux-desktop < packaging/rpm-gpg/public.asc
gh secret set FLATPAK_GPG_KEY_ID -R sirredbeard/azurelinux-desktop -b "$(tr -d ' \n' < packaging/rpm-gpg/keyid.txt)"
```

Also keep the same three secrets on `sirredbeard/copilot-desktop-gtk`.

## CI flow

`publish-desktop-kmods.yml` after merge + policy rebuild:

1. `scripts/rpm-gpg-import.sh` (from `FLATPAK_GPG_PRIVATE_KEY`)
2. `scripts/sign-desktop-rpms.sh site/repo` (`rpmsign --addsign` every RPM)
3. `createrepo_c`
4. Publish `RPM-GPG-KEY-azurelinux-desktop` at the Pages site root

## Client `.repo`

```ini
[azl-desktop-kmods]
name=Azure Linux Desktop kernel modules
baseurl=https://sirredbeard.github.io/azurelinux-desktop/repo
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop
cost=1
```

## Rotate

Rotate once for both repos (Flatpak + kmods). Replace public files here
and in copilot-desktop-gtk, update secrets on **both** GitHub repos,
resign Pages RPMs (`republish=true`), and ship a new Copilot Flatpak
release so `.flatpakref` `GPGKey=` updates.
