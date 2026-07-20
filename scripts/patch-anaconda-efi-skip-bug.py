#!/usr/bin/env python3
"""Patch anaconda-core's efi.py to fix a real skip-path return-value bug.

The packaged anaconda-core used for the disk-image build still carries a bug
upstream already fixed on rhinstaller/anaconda's main branch:

bootloader/efi.py's efibootmgr() is supposed to skip the real efibootmgr
call for image/directory installs (there is no hardware NVRAM to write to
in that case) and return a value the caller can safely check. The installed
version does `return ""` unconditionally on that skip path, but
_add_single_efi_boot_target() does `if rc != 0: raise` - and `"" != 0` is
always True in Python, so every image-mode EFI install fails with "Failed
to set new efi boot target. This is most likely a kernel or firmware bug."
even though nothing actually went wrong.

Upstream's fix (confirmed via a GitHub source search of
rhinstaller/anaconda main) pops "capture" up front and returns
`"" if capture_expected else 0` on both skip paths, so a non-capturing
caller sees a falsy 0 instead of a truthy non-zero string. This script
applies that same fix in place, before livemedia-creator ever runs
anaconda, rather than wait for Fedora to backport it.

Run inside the Fedora build container, after `dnf5 install
anaconda-core` and before `livemedia-creator --make-disk` runs. See
findings/gh-actions-live-iso-build.md for the full bug writeup.
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
