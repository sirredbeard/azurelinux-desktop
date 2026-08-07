# Surface HID OOT build failure (hid-ids.h) and BTF/vmlinux

## Symptom (CI)

`publish-desktop-kmods` family `surface` failed after platform modules linked:

```
hid-microsoft.c:20:10: fatal error: hid-ids.h: No such file or directory
```

Log also showed:

```
Skipping BTF generation for surfacepro3_button.ko due to unavailability of vmlinux
```

## Do we need vmlinux?

**No.** The BTF skip is a **warning only**. Out-of-tree modules built against
`kernel-devel` often lack `/boot/vmlinux-$KVER` (or the matching BTF image).
`pahole` then skips BTF embedding; modules still load and depmod works.
We do **not** need to ship or generate vmlinux for desktop kmods.

## Real failure

Upstream `drivers/hid/hid-microsoft.c` and `hid-multitouch.c` include local
headers that live only under `drivers/hid/` in the full kernel source tree:

* `hid-ids.h` (required by hid-microsoft, hid-multitouch, hid-lenovo)
* `hid-haptic.h` (multitouch on newer trees)

`kernel-devel` does **not** install those private headers. Copying only the
`.c` files into the OOT `M=` directory is not enough.

Surface SSAM clients and `surface_hid` also need:

```
#include <linux/surface_aggregator/*.h>
```

Those headers are omitted from stock AZL `kernel-devel` when
`CONFIG_SURFACE_*` is off.

## Fix (builder)

In `scripts/build-desktop-kmods.sh` surface stage:

1. Copy `include/linux/surface_aggregator/` from the CBL-Mariner tarball into
   `$BUILD_DIR/include/linux/` (container-local) and the surface workdir.
2. Copy `hid-ids.h` (+ `hid-haptic.h` when present) next to the HID sources.
3. Add `ccflags-y += -I$(src)` (and `-I$(src)/../include` for SSAM HID).
4. Same `hid-ids.h` treatment for thinkpad `hid-lenovo`.

## Scope

Upstream-only / matching Azure kernel tarball. **No** linux-surface fork.

## Related

* `findings/intel-surface-kmod-families.md`
* `findings/kmod-family-expansion-stock-vs-oot.md`
