# What this directory is

These five files are a pinned snapshot of the official Azure Linux 4.0
x86_64 installer media, not paraphrases. They came from mounting that ISO
and its nested images:

```
mount -o loop,ro AzureLinux-4.0-x86_64.iso /mnt/iso        # LiveOS/squashfs.img
mount -o loop,ro /mnt/iso/LiveOS/squashfs.img /mnt/squash  # LiveOS/rootfs.img
mount -o loop,ro /mnt/squash/LiveOS/rootfs.img /mnt/rootfs # the real installer environment
```

Inside `/mnt/rootfs`, straight `cp`:

- `azl-install.ks` from `/root/azl-install.ks`
- `azl-install-encrypted.ks` from `/root/azl-install-encrypted.ks`
- `post-install.sh` from `/root/post-install.sh`
- `post-bootloader.sh` from `/root/post-bootloader.sh`
- `anaconda-launcher.sh` from `/usr/local/bin/anaconda-launcher.sh`

The project's own installer path is `kiwi/` (KIWI-NG), adapted from the same
upstream layout. See [`findings/kiwi-ng-installer-build.md`](../findings/kiwi-ng-installer-build.md).

## Are these also on GitHub?

Yes. Microsoft publishes this installer's source in `microsoft/azurelinux`,
under `base/images/vm-iso-installer/`:

- `anaconda-launcher.sh`, `post-install.sh`, `post-bootloader.sh` were
  **byte-for-byte identical** to this folder at upstream commit `0e77e25`
  (plain `diff`, zero output).
- `azl-install.ks` and `azl-install-encrypted.ks` here are the **rendered**
  output of upstream's `azl-install.ks.in` / `azl-install-encrypted.ks.in`
  templates - identical except for one substitution: upstream's
  `@@PACKAGES@@` placeholder gets filled in at ISO build time with the
  real `%packages --nocore` block you see in the copy here.

**Upstream status as of 2026-07-23:** All five files unchanged since `0e77e25`.
Commit `3c2a74a` (2026-05-27) updated `post-bootloader.sh` to prefer
`EFI/azurelinux/` over `EFI/fedora/` for EFI vendor path detection. That
fix is already present in `0e77e25`. Our `kiwi/post-bootloader.sh` follows
the same EFI priority order, plus a copy step when Fedora-signed shim/grub
land under `EFI/fedora/` but NVRAM points at `EFI/azurelinux/`. See
[`findings/efi-vendor-path-azurelinux.md`](../findings/efi-vendor-path-azurelinux.md).

## Upstream links (pinned)

- https://github.com/microsoft/azurelinux/blob/0e77e25/base/images/vm-iso-installer/anaconda-launcher.sh
- https://github.com/microsoft/azurelinux/blob/0e77e25/base/images/vm-iso-installer/post-install.sh
- https://github.com/microsoft/azurelinux/blob/0e77e25/base/images/vm-iso-installer/post-bootloader.sh
- https://github.com/microsoft/azurelinux/blob/0e77e25/base/images/vm-iso-installer/azl-install.ks.in
- https://github.com/microsoft/azurelinux/blob/0e77e25/base/images/vm-iso-installer/azl-install-encrypted.ks.in

## Why keep local copies instead of just linking

- The copies here are pinned to the **exact ISO version this project was
  researched against**, including fully rendered `.ks` files with real
  package lists. The upstream `.ks.in` templates alone do not show that.
- Notes in `findings/` that reference these files stay readable offline
  and do not drift when upstream moves.
- Upstream remains the link for current live source beyond this snapshot.
