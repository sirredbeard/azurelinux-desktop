# Shared OpenPGP key rotation

**Status:** Active. New key generated 2026-08-04. Pages resign required
before image rebuilds that trust it.

## Why

One OpenPGP key signs:

1. Copilot Desktop GTK Flatpak OSTree on GitHub Pages
2. azurelinux-desktop out-of-tree kmod RPMs on GitHub Pages

Earlier material used Flatpak-oriented UID and `FLATPAK_GPG_*` secret
names. Rotated to a generic UID and `GPG_*` secret names so RPM and
Flatpak share the same story.

## Identity

* Name: Hayden Barnes (sirredbeard)
* Email: gpg@sirredbeard.github.io
* Short id: `8DA5774C35DA9BF9`
* Fingerprint: `09DCEFE2212F7881EE2058088DA5774C35DA9BF9`

## Secrets

Repos: `sirredbeard/copilot-desktop-gtk` and
`sirredbeard/azurelinux-desktop`.

* `GPG_PRIVATE_KEY` - armored private key (CI only)
* `GPG_PUBLIC_KEY` - armored public key
* `GPG_KEY_ID` - short key id

Old `FLATPAK_GPG_*` secrets deleted. GitHub does not return secret
values after set. Keep an offline armored private copy outside git.

## In-tree public material

* `packaging/gpg/public.asc` + `keyid.txt` (+ README)
* `assets/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-desktop` (RPM clients)
* `assets/gpg/signing-key.asc` → image path
  `/usr/share/azurelinux-desktop/gpg/signing-key.asc`

## Publish order after rotation

1. Push key + script/workflow updates to both product repos.
2. Release Copilot Flatpak (new tag) so Pages OSTree and
   `.flatpakref` `GPGKey=` match the new key.
3. Dispatch `publish-desktop-kmods.yml` with `republish=true` so kmod
   RPMs and `RPM-GPG-KEY-azurelinux-desktop` match.
4. Only then rebuild live ISO / installer / disks that ship
   `gpgcheck=1` and seed the public key.

## Chicken/egg

Clients with `gpgcheck=1` or Flatpak `gpg-verify=true` fail if Pages
still has packages signed with the previous key. Resign Pages first.

## Offline recovery

Private key is not recoverable from GitHub. Offline copy lives outside
this repo. Re-set secrets with:

```bash
gh secret set GPG_PRIVATE_KEY -R OWNER/REPO < private.asc
gh secret set GPG_PUBLIC_KEY -R OWNER/REPO < packaging/gpg/public.asc
gh secret set GPG_KEY_ID -R OWNER/REPO -b "$(tr -d ' \n' < packaging/gpg/keyid.txt)"
```

## Republish gotcha (rpmsign)

Merging prior Pages RPMs into a new publish leaves packages that already
have a signature. `rpmsign --addsign` then fails with:

`already contains a legacy signature`

`scripts/sign-desktop-rpms.sh` runs `rpmsign --delsign` then `--addsign`
so key rotation and mixed old/new sets resign cleanly.

## Related

* `flatpak-untrusted-non-gpg-remote.md`
* `out-of-tree-usb-kmods-pages.md`
* `packaging/gpg/README.md`
