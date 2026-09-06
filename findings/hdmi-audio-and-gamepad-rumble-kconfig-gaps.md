# HDMI audio missing sink + gamepad rumble/LED silently off

## Symptom

- External HDMI monitor's speaker never showed up in GNOME Sound
  Settings / `wpctl status` on real hardware (Skylake ThinkPad,
  `snd_hda_intel`). `dmesg` showed:
  `snd_hda_codec_intelhdmi hdaudioC0D2: No i915 binding for Intel
  HDMI/DP codec`, then `Unable to configure, disabling`.
- Xbox/PS3/PS4/PS5 controllers built by `azurelinux-desktop-gamepad-kmod`
  loaded fine but had no rumble, and the Xbox 360 controller's Guide
  button LED ring didn't light.

## Root cause (same class, two places)

`scripts/build-desktop-kmods.sh` builds these OOT modules against real
upstream kernel source using a fake Kconfig (either `make CONFIG_X=y/n`
for the `sound`/`bluetooth`/`intel` full-subsystem stages, or
`ccflags-y -DCONFIG_X=1` per file for the smaller single-driver
stages). A Kbuild `CONFIG_X=y` on the `make` command line only steers
`obj-y`/`obj-m` file selection - it is **not** visible to C preprocessor
`#ifdef CONFIG_X` checks inside the .c files unless a matching
`#define` is also supplied (this project's `force-*.h` `-include`
header pattern for the big stages, or the same `-DCONFIG_X=1` flag
inline for the small ones). Miss the `#define`, and the driver silently
takes its "feature not built" branch even though the enclosing module
compiles and loads without any error.

- **HDMI audio**: `sound/hda/controllers/intel.c` requires
  `CONFIG_SND_HDA_I915` to call `snd_hdac_i915_init()`, which registers
  the DRM "audio component" the HDMI/DP codec needs
  (`sound/hda/codecs/hdmi/intelhdmi.c` bails with exactly the observed
  error if that never happened). The `sound` stage's `make` line had
  `CONFIG_SND_HDA_I915=n` and no matching `#define` in `force-snd.h`.
  Fix: flip to `=y` and add `#define CONFIG_SND_HDA_I915 1` to
  `force-snd.h`. `CONFIG_SND_HDA_I915` is a Kconfig `bool` that compiles
  straight into `snd-hda-core.ko` (which this project already builds
  `=m`), so this is a plain flag fix, not a "needs vmlinux" case like
  `PINCTRL_AMD`.
- **Gamepad rumble/LED**: `JOYSTICK_XPAD_FF`/`_LEDS` (xpad.c),
  `SONY_FF` (hid-sony.c), `PLAYSTATION_FF` (hid-playstation.c) are all
  plain Kconfig `bool`s depending only on `INPUT_FF_MEMLESS` and
  `LEDS_CLASS` - both already stock `=m` on the real AZL kernel. The
  `gamepad` stage's Makefile never forced these four, so `xpad_play_effect`/
  `sony_play_effect`/`dualshock4_play_effect`/`dualsense_play_effect`
  and the LED ring code were compiled out. Fix: add the four `-D` lines
  to the stage's `ccflags-y`.

## How the gamepad gap was found

After finding the HDMI bug, audited every `#ifdef`/`#if defined`/
`IS_ENABLED`/`IS_MODULE` reference to a `CONFIG_` symbol across every
`.c`/`.h` file this script copies from upstream (~50 files, all 28
build stages), then diffed that set against every `-D`/`make CONFIG_X=`
flag the script actually forces. Anything referenced-but-unforced was
checked against the real kernel's `/boot/config-$(uname -r)`: already
`=y`/`=m` there means no OOT work needed (the real `kernel-devel`
headers already report it correctly); genuinely absent and gating real
functionality (not debug/legacy/hardware-not-present) is a bug.
Everything else found this way (`CONFIG_OF`, `PM`/`PM_SLEEP`/`SUSPEND`/
`ACPI*` - already stock; `THINKPAD_ACPI_DEBUG*`/`_UNSAFE_LEDS` -
debug/safety default; `HID_HAPTIC` - upstream `default n`, single niche
touchpad model) was not a bug.

A separate, much larger gap was flagged but **not fixed**: the HDA
smart-amp side-codecs (`CS35L41`/`CS35L56`/`TAS2781`, common on 2019+
Dell/HP/Lenovo laptops) and the whole SOF/ASoC audio path both
`depends on SND_SOC`, which is off and pulls in firmware-topology
loading (`FW_CS_DSP`, `SND_SOC_*_FMWLIB`) - out of the "in-tree, no
blobs" scope for these OOT kmods. Worth a future issue if it matters
enough to take on the firmware question deliberately; not a silent
one-flag miss like the two above.

## Verification

Compiled the real `sound` and `gamepad` stages (not an isolated stand-in)
inside a podman container with matching `kernel-devel` for
`6.18.31-1.16.azl4.x86_64`, using `DESKTOP_KMOD_WORKDIR` to keep the
build tree around for inspection:

```
DESKTOP_KMOD_STAGE=sound ./build-desktop-kmods.sh /root/out '' sound
DESKTOP_KMOD_WORKDIR=/root/wd DESKTOP_KMOD_STAGE=gamepad ./build-desktop-kmods.sh /root/out3 '' gamepad
```

Both built clean. Confirmed the fix actually took effect (not just "no
build error") by checking the built `.ko` symbol tables:

```
$ nm xpad.ko | grep -i play_effect
xpad_play_effect
$ nm hid-sony.ko | grep -i play_effect
sony_play_effect
$ nm hid-playstation.ko | grep -i play_effect
dualsense_play_effect
dualshock4_play_effect
```

All four link against `input_ff_create_memless`, confirming rumble is
wired to the stock `ff-memless.ko`. Real-hardware retest of the HDMI
sink is still pending an actual rebuilt/installed kmod on this host
(kernel-locked NVR means a same-kernel rebuild needs `dnf reinstall`,
not just `dnf upgrade` - see "Getting the fix onto an existing install"
below).

## Getting the fix onto an existing install

`azurelinux-desktop-policy`'s Version/Release is locked 1:1 to the
target kernel's own EVR - there is no independent kmod build counter.
A content-only rebuild against the *same* kernel version produces an
identical NVR, so `dnf upgrade` alone won't see it as newer. After
`publish-desktop-kmods.yml` republishes (`republish: true` dispatch),
an already-installed system needs an explicit
`dnf reinstall azurelinux-desktop-sound-kmod azurelinux-desktop-gamepad-kmod`
(or wait for the next real kernel bump, which naturally repackages
everything). Deliberately not adding a separate kmod build-revision
counter for this - low user count for this project right now, not
worth the versioning complexity yet, but worth reconsidering if that
changes.

Status: both fixes applied and compile-verified in
`scripts/build-desktop-kmods.sh`. Real HDMI-audio retest on this host
still pending a republished/reinstalled kmod set.
