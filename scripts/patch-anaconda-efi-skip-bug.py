#!/usr/bin/env python3
"""patch-anaconda-efi-skip-bug.py

Purpose: Patch the Fedora anaconda EFI "bootable partition" skip bug before
  livemedia-creator --make-disk (see findings/github-actions-build.md).
Usage:   python3 scripts/patch-anaconda-efi-skip-bug.py (inside build container)
Needs:   Python 3; anaconda installed in the build root.
CI:      Yes. build-live-iso.yml disk image path.
"""

import glob
import sys

EFI_PY_PATHS = glob.glob(
    "/usr/lib64/python3*/site-packages/pyanaconda/modules/storage/bootloader/efi.py"
)

OLD = """    def efibootmgr(self, *args, **kwargs):
        if not conf.target.is_hardware:
            log.info("Skipping efibootmgr for image/directory install.")
            return ""

        if "noefi" in kernel_arguments:
            log.info("Skipping efibootmgr for noefi")
            return ""

        if kwargs.pop("capture", False):"""

NEW = """    def efibootmgr(self, *args, **kwargs):
        capture_expected = kwargs.pop("capture", False)
        if not conf.target.is_hardware:
            log.info("Skipping efibootmgr for image/directory install.")
            return "" if capture_expected else 0

        if "noefi" in kernel_arguments:
            log.info("Skipping efibootmgr for noefi")
            return "" if capture_expected else 0

        if capture_expected:"""


def main():
    if len(sys.argv) > 1:
        path = sys.argv[1]
    elif len(EFI_PY_PATHS) == 1:
        path = EFI_PY_PATHS[0]
    else:
        sys.exit("ERROR: unable to locate anaconda's efi.py")
    with open(path) as f:
        src = f.read()

    if NEW in src:
        print(f"{path} is already patched, nothing to do")
        return

    if OLD not in src:
        sys.exit(
            f"ERROR: {path} efibootmgr() shape changed - "
            "this patch needs updating to match the new source"
        )

    with open(path, "w") as f:
        f.write(src.replace(OLD, NEW))
    print(f"Patched {path}: efibootmgr() skip-path return value bug fixed")


if __name__ == "__main__":
    main()
