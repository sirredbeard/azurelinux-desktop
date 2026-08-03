#!/usr/bin/env python3
"""Configure Anaconda's EFI vendor directory for an image build."""

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--profile",
        type=Path,
        default=Path("/etc/anaconda/profile.d/fedora.conf"),
        help="Anaconda profile to update",
    )
    parser.add_argument(
        "--vendor",
        default="azurelinux",
        help="EFI vendor directory used by the selected shim and GRUB packages",
    )
    args = parser.parse_args()

    source = args.profile.read_text()
    old = "efi_dir = fedora"
    new = f"efi_dir = {args.vendor}"

    if new in source:
        print(f"{args.profile} already selects EFI/{args.vendor}")
        return
    if old not in source:
        raise SystemExit(
            f"ERROR: {args.profile} does not contain the expected '{old}' setting"
        )

    args.profile.write_text(source.replace(old, new))
    print(f"Configured {args.profile} to select EFI/{args.vendor}")


if __name__ == "__main__":
    main()
