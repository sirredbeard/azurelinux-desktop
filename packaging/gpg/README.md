# Project OpenPGP signing key

Same key as `sirredbeard/copilot-desktop-gtk` Pages Flatpak stream.

## Identity

- Name: Hayden Barnes (sirredbeard)
- Email: gpg@sirredbeard.github.io
- Key id: `8DA5774C35DA9BF9`
- Fingerprint: `09DCEFE2212F7881EE2058088DA5774C35DA9BF9`

## Actions secrets (`sirredbeard/azurelinux-desktop`)

| Secret | Contents |
| --- | --- |
| `GPG_PRIVATE_KEY` | Armored private key |
| `GPG_PUBLIC_KEY` | Armored public key |
| `GPG_KEY_ID` | Short key id |

```bash
gh secret list -R sirredbeard/azurelinux-desktop
gh secret set GPG_PRIVATE_KEY -R sirredbeard/azurelinux-desktop < private.asc
gh secret set GPG_PUBLIC_KEY -R sirredbeard/azurelinux-desktop < packaging/gpg/public.asc
gh secret set GPG_KEY_ID -R sirredbeard/azurelinux-desktop -b "$(tr -d ' \n' < packaging/gpg/keyid.txt)"
```

## Image seeding

- RPM: `assets/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop` ->
  `/etc/pki/rpm-gpg/` (`gpgcheck=1` on azl-desktop-kmods)
- Generic: `assets/gpg/signing-key.asc` ->
  `/usr/share/azurelinux-desktop/gpg/signing-key.asc` (Flatpak import helper)

## CI

`publish-desktop-kmods.yml` signs RPMs with `scripts/sign-desktop-rpms.sh`
before `createrepo_c`, then publishes `RPM-GPG-KEY-azurelinux-desktop` on Pages.
