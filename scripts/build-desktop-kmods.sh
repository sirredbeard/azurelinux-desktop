#!/usr/bin/env bash
# build-desktop-kmods.sh
#
# Purpose: Build out-of-tree desktop kmod RPMs (USB, BT, sound, Wi-Fi, ...)
#   against a given Azure Linux kernel inside an Azure Linux container.
# Usage:   See header flags inside; usually run via publish-desktop-kmods.yml.
# Needs:   container runtime, kernel-devel matching target kernel, rpmbuild.
# CI:      Yes. publish-desktop-kmods.yml family matrix.
#
# Kconfig convention (all stages must follow this): every Kconfig
# bool/tristate a stage's driver source needs for its advertised feature
# set must be forced explicitly, and that forcing must be verified
# against upstream Kconfig `depends on`/`select` lines plus the real AZL
# kernel's own /boot/config-* (a dependency already stock =y/=m needs no
# extra build work; one that's genuinely absent needs its own stage).
# Two mechanisms exist for this, chosen by stage size, not preference:
#   - Small, self-contained drivers (1-4 files, own obj-m): force each
#     flag with `ccflags-y += -DCONFIG_X=1` (or _MODULE=1 for the
#     enclosing module symbol) in that stage's Makefile heredoc.
#   - Large multi-file subsystems (sound, and any future stage built via
#     a full `make CONFIG_X=y/n ...` fake-.config): a stage-local
#     force-*.h header (`-include`) supplies the matching #define for
#     every bool/tristate the make-line flips on, since a Kbuild command
#     line CONFIG_X=y only steers obj-y/obj-m file selection - it is not
#     visible to C preprocessor #ifdef checks inside those files without
#     the header. A make-line flag with no matching header #define is a
#     silent bug (see findings/ for the CONFIG_SND_HDA_I915 case).
# Flags left off on purpose (debug/test/legacy/hardware genuinely absent)
# should get a short comment saying so, the same way the on-purpose ones
# already do, so a future audit doesn't have to re-derive the reasoning.

set -euo pipefail

AZL_BASE_URL="${AZL_BASE_URL:-https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64}"
OUTPUT_DIR="${1:?usage: $0 OUTPUT_DIR [kernel-nevra] [stage]}"
REQUESTED_KERNEL="${2:-}"
STAGE="${3:-${DESKTOP_KMOD_STAGE:-all}}"

run_stage() {
    local want="$1"
    [[ "$STAGE" == "all" || "$STAGE" == "$want" ]]
}

mkdir -p "$OUTPUT_DIR"

if [[ -n "$REQUESTED_KERNEL" ]]; then
    KERNEL_QUERY=("$REQUESTED_KERNEL")
else
    KERNEL_QUERY=(--latest-limit=1 kernel)
fi

read -r _ KERNEL_VERSION KERNEL_RELEASE KERNEL_ARCH < <(
    dnf5 repoquery --setopt=reposdir=/dev/null \
        --repofrompath=azl-base,"$AZL_BASE_URL" --repo=azl-base \
        --available \
        --qf '%{name}-%{version}-%{release}.%{arch} %{version} %{release} %{arch}' \
        "${KERNEL_QUERY[@]}"
    printf '\n'
)
KERNEL_EVR="${KERNEL_VERSION}-${KERNEL_RELEASE}"
KERNEL_DEVEL_NEVRA="kernel-devel-${KERNEL_EVR}.${KERNEL_ARCH}"

rpm -q "$KERNEL_DEVEL_NEVRA" >/dev/null 2>&1 || dnf5 install -y \
    --setopt=reposdir=/dev/null --setopt=azl-base.gpgcheck=0 \
    --repofrompath=azl-base,"$AZL_BASE_URL" --repo=azl-base \
    "$KERNEL_DEVEL_NEVRA" \
    bc gcc make perl python3 openssl-devel elfutils-devel elfutils-libelf-devel \
    rpm-build kmod git curl gawk tar gzip findutils which

KVERREL="${KERNEL_EVR}.${KERNEL_ARCH}"
BUILD_DIR="/usr/src/kernels/$KVERREL"

test -f "$BUILD_DIR/.config"
test -f "$BUILD_DIR/Module.symvers"

# Azure's kernel component carries its source fourth-version component as
# the first RPM release component (for example, 6.18.31-1.6.azl4 uses the
# rolling-lts/azl4/6.18.31.1 source).
SOURCE_REF="${KERNEL_VERSION}.${KERNEL_RELEASE%%.*}"

if [[ -n "${DESKTOP_KMOD_WORKDIR:-}" ]]; then
    WORKDIR="$DESKTOP_KMOD_WORKDIR"
    mkdir -p "$WORKDIR"
else
    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT
fi

# Look up one filename in a kernel.comp.toml. Prints "URL HASH" and
# returns 0 on a match; returns 1 with no output otherwise (does not
# raise, so callers can fall back to a different toml revision).
resolve_from_toml() {
    local toml_path="$1" expected_filename="$2"
    python3 - "$toml_path" "$expected_filename" <<'PY'
import sys
import tomllib

component_path, expected_filename = sys.argv[1:]
with open(component_path, "rb") as component_file:
    component = tomllib.load(component_file)

for source in component["components"]["kernel"]["source-files"]:
    if source["filename"] == expected_filename:
        print(source["origin"]["uri"], source["hash"])
        sys.exit(0)
sys.exit(1)
PY
}

# microsoft/azurelinux's 4.0 branch HEAD only reflects whichever kernel
# source is current right now; it has no version history of its own.
# Walk kernel.comp.toml's real git history via the GitHub API (newest
# first) until a past revision lists our exact filename. Set
# GITHUB_TOKEN/GH_TOKEN to raise the unauthenticated rate limit in CI.
resolve_from_history() {
    local expected_filename="$1"
    local auth=()
    if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
        auth=(-H "Authorization: Bearer ${GITHUB_TOKEN:-$GH_TOKEN}")
    fi
    local page
    for page in 1 2 3 4 5; do
        local shas
        shas="$(curl --fail --silent --location --retry 3 "${auth[@]}" \
            "https://api.github.com/repos/microsoft/azurelinux/commits?path=base/comps/kernel/kernel.comp.toml&sha=4.0&per_page=100&page=${page}" \
            | python3 -c 'import json,sys; [print(c["sha"]) for c in json.load(sys.stdin)]' 2>/dev/null)" || break
        [[ -z "$shas" ]] && break
        local sha candidate out
        while IFS= read -r sha; do
            [[ -z "$sha" ]] && continue
            candidate="$(mktemp)"
            if curl --fail --silent --location --retry 2 \
                "https://raw.githubusercontent.com/microsoft/azurelinux/${sha}/base/comps/kernel/kernel.comp.toml" \
                -o "$candidate" 2>/dev/null; then
                if out="$(resolve_from_toml "$candidate" "$expected_filename" 2>/dev/null)"; then
                    rm -f "$candidate"
                    echo "Resolved ${expected_filename} via microsoft/azurelinux@${sha:0:8}" >&2
                    printf '%s\n' "$out"
                    return 0
                fi
            fi
            rm -f "$candidate"
        done <<<"$shas"
    done
    return 1
}

prepare_source() {
    if [[ -f "$WORKDIR/.prepared" ]]; then
        # shellcheck disable=SC1091
        source "$WORKDIR/env.sh"
        SOURCE_DIR="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d -name 'CBL-Mariner-Linux-Kernel-*' -print -quit)"
        if [[ -z "$SOURCE_DIR" && -f "$WORKDIR/kernel.tar.gz" ]]; then
            tar -xzf "$WORKDIR/kernel.tar.gz" -C "$WORKDIR"
            SOURCE_DIR="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d -name 'CBL-Mariner-Linux-Kernel-*' -print -quit)"
        fi
        test -n "$SOURCE_DIR"
        return 0
    fi

    EXPECTED_FILENAME="kernel-${SOURCE_REF}.tar.gz"
    COMPONENT_TOML="$WORKDIR/kernel.comp.toml"
    curl --fail --location --retry 3 \
        https://raw.githubusercontent.com/microsoft/azurelinux/4.0/base/comps/kernel/kernel.comp.toml \
        -o "$COMPONENT_TOML"

    RESOLVED=""
    if RESOLVED="$(resolve_from_toml "$COMPONENT_TOML" "$EXPECTED_FILENAME")"; then
        :
    else
        # microsoft/azurelinux's 4.0 branch HEAD only ever lists whatever
        # kernel source is current right now (rolling, not a versioned
        # history), so azl-base's published kernel-devel can momentarily
        # lag it. Walk the file's own git history on GitHub for the commit
        # where our exact NEVRA's source was still current.
        echo "kernel.comp.toml at 4.0 HEAD does not list ${EXPECTED_FILENAME}; walking microsoft/azurelinux history" >&2
        if ! RESOLVED="$(resolve_from_history "$EXPECTED_FILENAME")"; then
            echo "Azure Linux 4.0 does not define ${EXPECTED_FILENAME} at branch HEAD or in recent kernel.comp.toml history" >&2
            exit 1
        fi
    fi
    read -r SOURCE_URL SOURCE_SHA512 <<<"$RESOLVED"
    test -n "$SOURCE_URL"
    test -n "$SOURCE_SHA512"
    # Optional host/cache path for local rebuilds (CI leaves unset).
    if [[ -n "${KERNEL_SRC_TARBALL:-}" && -f "$KERNEL_SRC_TARBALL" ]]; then
        cp -f "$KERNEL_SRC_TARBALL" "$WORKDIR/kernel.tar.gz"
    else
        curl --fail --location --retry 3 "$SOURCE_URL" -o "$WORKDIR/kernel.tar.gz"
    fi
    printf '%s  %s\n' "$SOURCE_SHA512" "$WORKDIR/kernel.tar.gz" | sha512sum --check
    # Extract unless prepare-only (CI uploads the tarball; families extract).
    if [[ "${DESKTOP_KMOD_PREPARE_TARBALL_ONLY:-0}" != "1" ]]; then
        tar -xzf "$WORKDIR/kernel.tar.gz" -C "$WORKDIR"
        SOURCE_DIR="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d -name 'CBL-Mariner-Linux-Kernel-*' -print -quit)"
        test -n "$SOURCE_DIR"
    fi
    cat > "$WORKDIR/env.sh" <<ENV
KVERREL='$KVERREL'
KERNEL_VERSION='$KERNEL_VERSION'
KERNEL_RELEASE='$KERNEL_RELEASE'
KERNEL_ARCH='$KERNEL_ARCH'
KERNEL_EVR='$KERNEL_EVR'
BUILD_DIR='$BUILD_DIR'
ENV
    touch "$WORKDIR/.prepared"
}

if [[ "$STAGE" == "package" ]]; then
    test -f "$WORKDIR/.prepared"
    # shellcheck disable=SC1091
    source "$WORKDIR/env.sh"
    SOURCE_DIR="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d -name 'CBL-Mariner-Linux-Kernel-*' -print -quit)"
    test -n "$SOURCE_DIR"
else
    prepare_source
    if [[ "$STAGE" == "prepare" ]]; then
        echo "Prepared kernel source for $KVERREL in $WORKDIR"
        exit 0
    fi
fi

check_vermagic() {
    local m
    for m in "$@"; do
        test -f "$m"
        test "$(modinfo -F vermagic "$m" | awk '{print $1}')" = "$KVERREL"
    done
}

# --- usbhid ---
if run_stage usbhid; then
echo "=== stage usbhid ==="
HID_DIR="$WORKDIR/usbhid"
mkdir -p "$HID_DIR"
cp "$SOURCE_DIR/drivers/hid/usbhid/hid-core.c" "$HID_DIR/"
cp "$SOURCE_DIR/drivers/hid/usbhid/"*.h "$HID_DIR/"
cat > "$HID_DIR/Makefile" <<'EOF'
obj-m += usbhid.o
usbhid-y := hid-core.o
EOF
make -C "$BUILD_DIR" M="$HID_DIR" modules
HID_MODULE="$HID_DIR/usbhid.ko"
check_vermagic "$HID_MODULE"
echo "=== stage usbhid done ==="
fi

# --- psmouse + RMI4 SMBus (PS/2 mouse; CONFIG_INPUT_MOUSE unset on AZL) ---
# GNOME Boxes / generic libvirt default to PS/2 mouse for unknown Linux.
# i8042 + libps2 + atkbd are built-in; only the mouse protocol driver is
# missing. aarch64 AZL already has CONFIG_MOUSE_PS2=m.
#
# Bare-metal ThinkPads (e.g. T470s) need more than relative PS/2:
# psmouse SMBus handoff + RMI4 (rmi_core + rmi_smbus). AZL has no
# CONFIG_RMI4_*. Without those, two-finger scroll stays broken. See
# findings/thinkpad-two-finger-scroll-rmi-smbus.md and
# findings/hypervisor-mouse-ps2-boxes.md.
if run_stage psmouse; then
echo "=== stage psmouse ==="
PS2_DIR="$WORKDIR/psmouse"
mkdir -p "$PS2_DIR"
# psmouse-base.c #includes every protocol header unconditionally;
# optional .c objects stay behind IS_ENABLED(CONFIG_MOUSE_PS2_*).
# Ship all headers from drivers/input/mouse plus the always-built
# objects (psmouse-base, synaptics, focaltech) and trackpoint.
shopt -s nullglob
for f in "$SOURCE_DIR/drivers/input/mouse/"*.h; do
    cp "$f" "$PS2_DIR/"
done
shopt -u nullglob
for f in psmouse-base.c synaptics.c focaltech.c trackpoint.c; do
    if [[ -f "$SOURCE_DIR/drivers/input/mouse/$f" ]]; then
        cp "$SOURCE_DIR/drivers/input/mouse/$f" "$PS2_DIR/"
    fi
done
# Core always-build objects + ThinkPad-relevant protocols (TrackPoint,
# ALPS, SMBus host notify). Headers stub unused CONFIG_MOUSE_PS2_*.
for f in alps.c psmouse-smbus.c logips2pp.c elantech.c; do
    if [[ -f "$SOURCE_DIR/drivers/input/mouse/$f" ]]; then
        cp "$SOURCE_DIR/drivers/input/mouse/$f" "$PS2_DIR/"
    fi
done
# RMI4 sources decide whether psmouse may advertise InterTouch SMBus.
# Without rmi_core/rmi_smbus, CONFIG_RMI4_SMB would hand the pad off and
# leave it dead. Only enable that path when drivers/input/rmi4 is present.
RMI_SRC="$SOURCE_DIR/drivers/input/rmi4"
PSMOUSE_BUILD_RMI=0
if [[ -d "$RMI_SRC" ]]; then
    PSMOUSE_BUILD_RMI=1
fi
# T470s units can report LEN007f; upstream list already has LEN007a.
# Add LEN007f only when the RMI companion will ship beside psmouse.
if [[ "$PSMOUSE_BUILD_RMI" -eq 1 ]] && [[ -f "$PS2_DIR/synaptics.c" ]] && ! grep -q '"LEN007f"' "$PS2_DIR/synaptics.c"; then
    sed -i '/"LEN007a", \/\* T470s \*\//a\\t"LEN007f", /* T470s */' "$PS2_DIR/synaptics.c"
fi
cat > "$PS2_DIR/Makefile" <<EOF
# Out-of-tree against AZL x86_64 where CONFIG_INPUT_MOUSE is not set.
ccflags-y += -DCONFIG_INPUT_MOUSE=1
ccflags-y += -DCONFIG_MOUSE_PS2_MODULE=1
ccflags-y += -DCONFIG_MOUSE_PS2_TRACKPOINT=1
ccflags-y += -DCONFIG_MOUSE_PS2_ALPS=1
ccflags-y += -DCONFIG_MOUSE_PS2_SMBUS=1
ccflags-y += -DCONFIG_MOUSE_PS2_SYNAPTICS_SMBUS=1
ccflags-y += -DCONFIG_MOUSE_PS2_LOGIPS2PP=1
EOF
if [[ "$PSMOUSE_BUILD_RMI" -eq 1 ]]; then
    # CONFIG_RMI4_SMB tells synaptics.c the SMBus companion exists so
    # synaptics_intertouch defaults to NOT_SET (allowlist) instead of OFF.
    cat >> "$PS2_DIR/Makefile" <<'EOF'
ccflags-y += -DCONFIG_RMI4_SMB=1
EOF
fi
cat >> "$PS2_DIR/Makefile" <<'EOF'

obj-m += psmouse.o
psmouse-y := psmouse-base.o synaptics.o focaltech.o trackpoint.o alps.o psmouse-smbus.o logips2pp.o
EOF
if [[ ! -f "$PS2_DIR/trackpoint.c" ]]; then
    sed -i '/trackpoint/d; /TRACKPOINT/d' "$PS2_DIR/Makefile"
fi
if [[ ! -f "$PS2_DIR/alps.c" ]]; then
    sed -i '/alps/d; /ALPS/d' "$PS2_DIR/Makefile"
fi
if [[ ! -f "$PS2_DIR/psmouse-smbus.c" ]]; then
    sed -i '/psmouse-smbus/d; /SMBUS/d; /SYNAPTICS_SMBUS/d; /RMI4_SMB/d' "$PS2_DIR/Makefile"
fi
if [[ ! -f "$PS2_DIR/logips2pp.c" ]]; then
    sed -i '/logips2pp/d; /LOGIPS2PP/d' "$PS2_DIR/Makefile"
fi
# Fail early if a required always-include header is missing from the tree.
for need in psmouse.h synaptics.h focaltech.h logips2pp.h; do
    [[ -f "$PS2_DIR/$need" ]] || {
        echo "error: psmouse missing $need from kernel sources" >&2
        exit 1
    }
done
make -C "$BUILD_DIR" M="$PS2_DIR" modules
PS2_MODULE="$PS2_DIR/psmouse.ko"
check_vermagic "$PS2_MODULE"

# RMI4: AZL has no CONFIG_RMI4_*. psmouse SMBus creates rmi4_smbus@0x2c;
# rmi_smbus binds it and rmi_core drives F11/F12 2D + F03 TrackPoint.
# Build beside psmouse so one RPM ships the full ThinkPad stack.
RMI_DIR="$PS2_DIR/rmi4"
if [[ "$PSMOUSE_BUILD_RMI" -eq 1 ]]; then
    echo "=== stage psmouse/rmi4 ==="
    mkdir -p "$RMI_DIR"
    shopt -s nullglob
    for f in "$RMI_SRC"/*.{c,h}; do
        cp "$f" "$RMI_DIR/"
    done
    shopt -u nullglob
    cat > "$RMI_DIR/Makefile" <<'EOF'
# Out-of-tree RMI4 for AZL (CONFIG_RMI4_* unset in-tree).
ccflags-y += -DCONFIG_RMI4_CORE_MODULE=1
ccflags-y += -DCONFIG_RMI4_2D_SENSOR=1
ccflags-y += -DCONFIG_RMI4_F03=1
ccflags-y += -DCONFIG_RMI4_F03_SERIO=1
ccflags-y += -DCONFIG_RMI4_F11=1
ccflags-y += -DCONFIG_RMI4_F12=1
ccflags-y += -DCONFIG_RMI4_F30=1
ccflags-y += -DCONFIG_RMI4_SMB_MODULE=1

obj-m += rmi_core.o
rmi_core-y := rmi_bus.o rmi_driver.o rmi_f01.o
rmi_core-y += rmi_2d_sensor.o
rmi_core-y += rmi_f03.o
rmi_core-y += rmi_f11.o
rmi_core-y += rmi_f12.o
rmi_core-y += rmi_f30.o

obj-m += rmi_smbus.o
EOF
    for need in rmi_bus.c rmi_driver.c rmi_f01.c rmi_2d_sensor.c \
        rmi_f03.c rmi_f11.c rmi_f12.c rmi_f30.c rmi_smbus.c; do
        [[ -f "$RMI_DIR/$need" ]] || {
            echo "error: rmi4 missing $need from kernel sources" >&2
            exit 1
        }
    done
    make -C "$BUILD_DIR" M="$RMI_DIR" modules
    # Flatten next to psmouse.ko so packaging and family-out stay simple.
    cp -f "$RMI_DIR/rmi_core.ko" "$PS2_DIR/rmi_core.ko"
    cp -f "$RMI_DIR/rmi_smbus.ko" "$PS2_DIR/rmi_smbus.ko"
    check_vermagic "$PS2_DIR/rmi_core.ko"
    check_vermagic "$PS2_DIR/rmi_smbus.ko"
    echo "=== stage psmouse/rmi4 done ==="

    # rmi_smbus only binds if an SMBus/SMB host controller is already
    # registered. Stock AZL ships i2c-i801 (Intel) in-tree, which is why
    # this path already works on Intel ThinkPads. AMD (and legacy Intel
    # PIIX4) chipsets have no in-tree adapter for it: CONFIG_I2C_PIIX4 is
    # not set. Without i2c-piix4, an AMD laptop's Synaptics InterTouch pad
    # stays stuck in relative PS/2 mode even with rmi_core/rmi_smbus
    # present, the same failure this whole family exists to fix. i2c-piix4
    # also covers old ATI/Broadcom/Serverworks SMBus controllers.
    I2C_DIR="$PS2_DIR/i2c-piix4"
    I2C_SRC="$SOURCE_DIR/drivers/i2c"
    if [[ -f "$I2C_SRC/busses/i2c-piix4.c" && -f "$I2C_SRC/busses/i2c-piix4.h" && -f "$I2C_SRC/i2c-smbus.c" ]]; then
        echo "=== stage psmouse/i2c-piix4 ==="
        mkdir -p "$I2C_DIR"
        cp "$I2C_SRC/busses/i2c-piix4.c" "$I2C_SRC/busses/i2c-piix4.h" "$I2C_DIR/"
        cp "$I2C_SRC/i2c-smbus.c" "$I2C_DIR/"
        cat > "$I2C_DIR/Makefile" <<'EOF'
ccflags-y += -DCONFIG_I2C_SMBUS_MODULE=1
obj-m += i2c-smbus.o
obj-m += i2c-piix4.o
EOF
        make -C "$BUILD_DIR" M="$I2C_DIR" modules
        cp -f "$I2C_DIR/i2c-smbus.ko" "$PS2_DIR/i2c-smbus.ko"
        cp -f "$I2C_DIR/i2c-piix4.ko" "$PS2_DIR/i2c-piix4.ko"
        check_vermagic "$PS2_DIR/i2c-smbus.ko"
        check_vermagic "$PS2_DIR/i2c-piix4.ko"
        echo "=== stage psmouse/i2c-piix4 done ==="
    else
        echo "warning: drivers/i2c/busses/i2c-piix4.c missing; shipping psmouse/RMI4 without the AMD/legacy SMBus adapter" >&2
    fi
else
    echo "warning: drivers/input/rmi4 missing; shipping psmouse without RMI4" >&2
fi
echo "=== stage psmouse done ==="
fi

# --- storage: USB mass-storage + UAS (family renamed from usb-storage) ---
# CONFIG_USB_STORAGE / CONFIG_USB_UAS are not set on AZL 4.0 x86_64.
# NVMe/ext4/dm-mod are built-in (=y). xfs/btrfs/dm-crypt/dm-integrity
# already ship as stock modules — do not rebuild (would conflict).
# Force module variants so IS_ENABLED() paths in the upstream sources
# match a normal =m build. USB core and SCSI mid-layer are built-in.
if run_stage storage || run_stage usb-storage; then
echo "=== stage storage (usb-storage + uas) ==="
STOR_DIR="$WORKDIR/storage"
rm -rf "$STOR_DIR" "$WORKDIR/usb-storage"
mkdir -p "$STOR_DIR"
# Core mass-storage + UAS only (skip ums-* specialty unusual drivers).
for f in \
    scsiglue.c scsiglue.h \
    protocol.c protocol.h \
    transport.c transport.h \
    usb.c usb.h \
    initializers.c initializers.h \
    sierra_ms.c sierra_ms.h \
    option_ms.c option_ms.h \
    usual-tables.c \
    debug.c debug.h \
    uas.c uas-detect.h \
    unusual_devs.h unusual_uas.h
do
    cp "$SOURCE_DIR/drivers/usb/storage/$f" "$STOR_DIR/"
done
# Headers referenced transitively by unusual_devs.h / usual-tables.
for f in "$SOURCE_DIR/drivers/usb/storage/"unusual_*.h; do
    bn="$(basename "$f")"
    [[ -f "$STOR_DIR/$bn" ]] || cp "$f" "$STOR_DIR/"
done
# transport.c includes "../../scsi/sd.h" relative to drivers/usb/storage.
# Copy sd.h locally and rewrite the include for out-of-tree builds.
cp "$SOURCE_DIR/drivers/scsi/sd.h" "$STOR_DIR/sd.h"
sed -i 's|#include "../../scsi/sd.h"|#include "sd.h"|' "$STOR_DIR/transport.c"
cat > "$STOR_DIR/Makefile" <<'EOF'
# Build against AZL kernel-devel where CONFIG_USB_STORAGE is off.
ccflags-y += -I$(src)
ccflags-y += -I$(srctree)/drivers/scsi
ccflags-y += -DDEFAULT_SYMBOL_NAMESPACE='"USB_STORAGE"'
ccflags-y += -DCONFIG_USB_STORAGE_MODULE=1
ccflags-y += -DCONFIG_USB_UAS_MODULE=1

obj-m += usb-storage.o uas.o

usb-storage-y := scsiglue.o protocol.o transport.o usb.o
usb-storage-y += initializers.o sierra_ms.o option_ms.o
usb-storage-y += usual-tables.o
EOF
make -C "$BUILD_DIR" M="$STOR_DIR" modules
STOR_MODULE="$STOR_DIR/usb-storage.ko"
UAS_MODULE="$STOR_DIR/uas.ko"
check_vermagic "$STOR_MODULE" "$UAS_MODULE"
# Compat path for older CI artifact merges
mkdir -p "$WORKDIR/usb-storage"
cp -f "$STOR_MODULE" "$WORKDIR/usb-storage/usb-storage.ko"
cp -f "$UAS_MODULE" "$WORKDIR/usb-storage/uas.ko"
echo "=== stage storage done ==="
fi

# --- intel family (was iwlwifi): Intel Wi-Fi + notes on GPU/HDA/BT/SOF ---
# Stock AZL 4.0 x86_64 ships DRM i915/xe, e1000e, MEI, etc. in
# kernel-modules{,-extra}, but leaves CONFIG_WLAN off so iwlwifi opmodes
# are missing. BT_INTEL and SND_HDA_INTEL ship in the bluetooth/sound
# sibling kmods (shared with non-Intel controllers). SOF Intel ASoC is
# not rebuilt here yet (large ASoC graph); HDA path covers Skylake-class
# and many Surfaces that still use snd-hda-intel.
#
# Family name: intel (package azurelinux-desktop-intel-kmod). Stage alias
# iwlwifi still accepted for older workflow inputs.
if run_stage intel || run_stage iwlwifi; then
echo "=== stage intel (iwlwifi) ==="
IWL_DIR="$WORKDIR/intel/iwlwifi"
rm -rf "$WORKDIR/intel"
mkdir -p "$WORKDIR/intel"
cp -a "$SOURCE_DIR/drivers/net/wireless/intel/iwlwifi" "$IWL_DIR"
{
    cat <<'EOF'
# Out-of-tree build against AZL x86_64 where CONFIG_WLAN / CONFIG_IWL* are off.
subdir-ccflags-y += -DCONFIG_IWLWIFI_MODULE=1
subdir-ccflags-y += -DCONFIG_IWLMVM_MODULE=1
subdir-ccflags-y += -DCONFIG_IWLDVM_MODULE=1
subdir-ccflags-y += -DCONFIG_IWLMLD_MODULE=1
subdir-ccflags-y += -DCONFIG_IWLWIFI_OPMODE_MODULAR=1
subdir-ccflags-y += -DCONFIG_IWLWIFI_LEDS=1
EOF
    cat "$IWL_DIR/Makefile"
} > "$IWL_DIR/Makefile.oot"
mv "$IWL_DIR/Makefile.oot" "$IWL_DIR/Makefile"
make -C "$BUILD_DIR" M="$IWL_DIR" \
    CONFIG_IWLWIFI=m \
    CONFIG_IWLMVM=m \
    CONFIG_IWLDVM=m \
    CONFIG_IWLMLD=m \
    CONFIG_IWLWIFI_OPMODE_MODULAR=y \
    CONFIG_IWLWIFI_LEDS=y \
    CONFIG_IWLWIFI_DEBUGFS=n \
    CONFIG_IWLWIFI_DEVICE_TRACING=n \
    CONFIG_IWLWIFI_KUNIT_TESTS=n \
    CONFIG_IWLMEI=n \
    modules
IWL_MODULE="$IWL_DIR/iwlwifi.ko"
IWL_MVM="$IWL_DIR/mvm/iwlmvm.ko"
IWL_DVM="$IWL_DIR/dvm/iwldvm.ko"
IWL_MLD="$IWL_DIR/mld/iwlmld.ko"
check_vermagic "$IWL_MODULE" "$IWL_MVM" "$IWL_DVM" "$IWL_MLD"
# Flatten copies for package stage path stability.
cp -f "$IWL_MODULE" "$WORKDIR/intel/iwlwifi.ko"
cp -f "$IWL_MVM" "$WORKDIR/intel/iwlmvm.ko"
cp -f "$IWL_DVM" "$WORKDIR/intel/iwldvm.ko"
cp -f "$IWL_MLD" "$WORKDIR/intel/iwlmld.ko"
# Compatibility path used by older package assembly / CI copy steps.
mkdir -p "$WORKDIR/iwlwifi/mvm" "$WORKDIR/iwlwifi/dvm" "$WORKDIR/iwlwifi/mld"
cp -f "$WORKDIR/intel/iwlwifi.ko" "$WORKDIR/iwlwifi/iwlwifi.ko"
cp -f "$WORKDIR/intel/iwlmvm.ko" "$WORKDIR/iwlwifi/mvm/iwlmvm.ko"
cp -f "$WORKDIR/intel/iwldvm.ko" "$WORKDIR/iwlwifi/dvm/iwldvm.ko"
cp -f "$WORKDIR/intel/iwlmld.ko" "$WORKDIR/iwlwifi/mld/iwlmld.ko"
echo "=== stage intel done ==="
fi

# --- sound: ALSA core + Intel HDA + common codecs + USB audio ---
if run_stage sound; then
echo "=== stage sound ==="
SND_DIR="$WORKDIR/sound"
rm -rf "$SND_DIR"
cp -a "$SOURCE_DIR/sound" "$SND_DIR"
cat > "$WORKDIR/force-snd.h" <<'EOF'
#define CONFIG_SOUND_MODULE 1
#define CONFIG_SND_MODULE 1
#define CONFIG_SND_TIMER_MODULE 1
#define CONFIG_SND_PCM_MODULE 1
#define CONFIG_SND_HWDEP_MODULE 1
#define CONFIG_SND_RAWMIDI_MODULE 1
#define CONFIG_SND_VMASTER 1
#define CONFIG_SND_JACK 1
#define CONFIG_SND_JACK_INPUT_DEV 1
#define CONFIG_SND_PCM_TIMER 1
#define CONFIG_SND_PCM_ELD 1
#define CONFIG_SND_DMA_SGBUF 1
#define CONFIG_SND_DYNAMIC_MINORS 1
/* Integer Kconfig values (not booleans). core.h uses MAX_CARDS when
 * DYNAMIC_MINORS is on; without it the static_assert fails. */
#define CONFIG_SND_MAX_CARDS 32
#define CONFIG_SND_MAJOR 116
#define CONFIG_SND_SUPPORT_OLD_API 1
#define CONFIG_SND_PROC_FS 1
#define CONFIG_SND_VERBOSE_PROCFS 1
#define CONFIG_SND_CTL_FAST_LOOKUP 1
#define CONFIG_SND_PCI 1
#define CONFIG_SND_USB 1
#define CONFIG_SND_HDA_MODULE 1
#define CONFIG_SND_HDA_CORE_MODULE 1
#define CONFIG_SND_HDA_GENERIC_MODULE 1
#define CONFIG_SND_HDA_GENERIC_LEDS 1
#define CONFIG_SND_HDA_INTEL_MODULE 1
#define CONFIG_SND_HDA_COMPONENT 1
#define CONFIG_SND_HDA_I915 1
#define CONFIG_SND_HDA_SCODEC_COMPONENT_MODULE 1
#define CONFIG_SND_HDA_HWDEP 1
#define CONFIG_SND_HDA_PREALLOC_SIZE 2048
#define CONFIG_SND_HDA_POWER_SAVE_DEFAULT 0
#define CONFIG_SND_INTEL_DSP_CONFIG_MODULE 1
#define CONFIG_SND_INTEL_NHLT 1
#define CONFIG_SND_INTEL_SOUNDWIRE_ACPI_MODULE 1
#define CONFIG_SND_HDA_CODEC_REALTEK_LIB_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC269_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC662_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC880_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC882_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC260_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC262_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC268_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC861_MODULE 1
#define CONFIG_SND_HDA_CODEC_ALC861VD_MODULE 1
#define CONFIG_SND_HDA_CODEC_HDMI_GENERIC_MODULE 1
#define CONFIG_SND_HDA_CODEC_HDMI_INTEL_MODULE 1
#define CONFIG_SND_HDA_CODEC_CONEXANT_MODULE 1
#define CONFIG_SND_HDA_CODEC_SIGMATEL_MODULE 1
#define CONFIG_SND_HDA_CODEC_VIA_MODULE 1
#define CONFIG_SND_HDA_CODEC_CMEDIA_MODULE 1
#define CONFIG_SND_USB_AUDIO_MODULE 1
#define CONFIG_SND_USB_AUDIO_USE_MEDIA_CONTROLLER 1
EOF
{
    echo "subdir-ccflags-y += -include $WORKDIR/force-snd.h"
    echo "ccflags-y += -include $WORKDIR/force-snd.h"
    cat <<'EOF'
obj-$(CONFIG_SOUND) += soundcore.o
obj-$(CONFIG_SND) += core/ hda/ usb/
soundcore-y := sound_core.o
EOF
} > "$SND_DIR/Makefile"
cat > "$SND_DIR/usb/Makefile" <<'EOF'
snd-usb-audio-y := card.o clock.o endpoint.o fcp.o format.o helper.o \
	implicit.o mixer.o mixer_quirks.o mixer_scarlett.o mixer_scarlett2.o \
	mixer_us16x08.o mixer_s1810c.o pcm.o power.o proc.o quirks.o \
	stream.o validate.o
snd-usb-audio-$(CONFIG_SND_USB_AUDIO_USE_MEDIA_CONTROLLER) += media.o
snd-usbmidi-lib-y := midi.o
obj-$(CONFIG_SND_USB_AUDIO) += snd-usb-audio.o snd-usbmidi-lib.o
EOF
# Keep upstream codecs Makefile (hdmi/realtek/side-codecs). Only drop
# cirrus amp side-codecs tree noise by leaving those CONFIG_* off.
# Realtek selects SND_HDA_SCODEC_COMPONENT for CS35 amp hooks on some
# laptops; ELD helpers live in core/pcm_drm_eld.o via CONFIG_SND_PCM_ELD.
make -C "$BUILD_DIR" M="$SND_DIR" \
    CONFIG_SOUND=m CONFIG_SND=m CONFIG_SND_TIMER=m CONFIG_SND_PCM=m \
    CONFIG_SND_HWDEP=m CONFIG_SND_RAWMIDI=m CONFIG_SND_SEQUENCER=n \
    CONFIG_SND_OSSEMUL=n CONFIG_SND_HRTIMER=n CONFIG_SND_DYNAMIC_MINORS=y \
    CONFIG_SND_MAX_CARDS=32 CONFIG_SND_MAJOR=116 \
    CONFIG_SND_SUPPORT_OLD_API=y CONFIG_SND_PROC_FS=y CONFIG_SND_VERBOSE_PROCFS=y \
    CONFIG_SND_CTL_FAST_LOOKUP=y CONFIG_SND_DEBUG=n CONFIG_SND_JACK=y \
    CONFIG_SND_JACK_INPUT_DEV=y CONFIG_SND_PCM_TIMER=y CONFIG_SND_PCM_ELD=y \
    CONFIG_SND_VMASTER=y CONFIG_SND_DMA_SGBUF=y CONFIG_SND_PCI=y CONFIG_SND_USB=y \
    CONFIG_SND_HDA=m CONFIG_SND_HDA_CORE=m CONFIG_SND_HDA_GENERIC=m \
    CONFIG_SND_HDA_INTEL=m CONFIG_SND_HDA_TEGRA=n CONFIG_SND_HDA_ACPI=n \
    CONFIG_SND_HDA_COMPONENT=y CONFIG_SND_HDA_I915=y CONFIG_SND_HDA_HWDEP=y \
    CONFIG_SND_HDA_INPUT_BEEP=n CONFIG_SND_HDA_PATCH_LOADER=n \
    CONFIG_SND_HDA_RECONFIG=n CONFIG_SND_HDA_GENERIC_LEDS=y \
    CONFIG_SND_HDA_SCODEC_COMPONENT=m \
    CONFIG_SND_HDA_CIRRUS_SCODEC=n CONFIG_SND_HDA_SCODEC_CS35L41=n \
    CONFIG_SND_HDA_SCODEC_CS35L41_I2C=n CONFIG_SND_HDA_SCODEC_CS35L41_SPI=n \
    CONFIG_SND_HDA_SCODEC_CS35L56=n CONFIG_SND_HDA_SCODEC_CS35L56_I2C=n \
    CONFIG_SND_HDA_SCODEC_CS35L56_SPI=n CONFIG_SND_HDA_SCODEC_TAS2781=n \
    CONFIG_SND_HDA_SCODEC_TAS2781_I2C=n CONFIG_SND_HDA_SCODEC_TAS2781_SPI=n \
    CONFIG_SND_HDA_EXT_CORE=n CONFIG_SND_INTEL_DSP_CONFIG=m \
    CONFIG_SND_INTEL_NHLT=y CONFIG_SND_INTEL_SOUNDWIRE_ACPI=m \
    CONFIG_SND_HDA_CODEC_REALTEK_LIB=m CONFIG_SND_HDA_CODEC_ALC260=m \
    CONFIG_SND_HDA_CODEC_ALC262=m CONFIG_SND_HDA_CODEC_ALC268=m \
    CONFIG_SND_HDA_CODEC_ALC269=m CONFIG_SND_HDA_CODEC_ALC662=m \
    CONFIG_SND_HDA_CODEC_ALC680=n CONFIG_SND_HDA_CODEC_ALC861=m \
    CONFIG_SND_HDA_CODEC_ALC861VD=m CONFIG_SND_HDA_CODEC_ALC880=m \
    CONFIG_SND_HDA_CODEC_ALC882=m CONFIG_SND_HDA_CODEC_HDMI_GENERIC=m \
    CONFIG_SND_HDA_CODEC_HDMI_SIMPLE=n CONFIG_SND_HDA_CODEC_HDMI_INTEL=m \
    CONFIG_SND_HDA_CODEC_HDMI_ATI=n CONFIG_SND_HDA_CODEC_HDMI_NVIDIA=n \
    CONFIG_SND_HDA_CODEC_HDMI_NVIDIA_MCP=n CONFIG_SND_HDA_CODEC_HDMI_TEGRA=n \
    CONFIG_SND_HDA_CODEC_CONEXANT=m CONFIG_SND_HDA_CODEC_SIGMATEL=m \
    CONFIG_SND_HDA_CODEC_VIA=m CONFIG_SND_HDA_CODEC_CMEDIA=m \
    CONFIG_SND_HDA_CODEC_CM9825=n CONFIG_SND_HDA_CODEC_ANALOG=n \
    CONFIG_SND_HDA_CODEC_CA0110=n CONFIG_SND_HDA_CODEC_CA0132=n \
    CONFIG_SND_HDA_CODEC_SENARYTECH=n CONFIG_SND_HDA_CODEC_SI3054=n \
    CONFIG_SND_USB_AUDIO=m CONFIG_SND_USB_AUDIO_MIDI_V2=n \
    CONFIG_SND_USB_AUDIO_USE_MEDIA_CONTROLLER=y CONFIG_SND_USB_UA101=n \
    CONFIG_SND_USB_USX2Y=n CONFIG_SND_USB_CAIAQ=n CONFIG_SND_USB_6FIRE=n \
    CONFIG_SND_USB_HIFACE=n CONFIG_SND_BCD2000=n CONFIG_SND_USB_LINE6=n \
    CONFIG_SND_SOC=n \
    modules
mapfile -t SOUND_MODULES < <(find "$SND_DIR" -name '*.ko' | sort)
test "${#SOUND_MODULES[@]}" -ge 12
check_vermagic "${SOUND_MODULES[@]}"
echo "=== stage sound done ==="
fi

# --- bluetooth ---
if run_stage bluetooth; then
echo "=== stage bluetooth ==="
BTNET_DIR="$WORKDIR/btnet"
rm -rf "$BTNET_DIR"
cp -a "$SOURCE_DIR/net/bluetooth" "$BTNET_DIR"
{
    cat <<'EOF'
# subdir-ccflags-y: rfcomm/, bnep/, hidp/ are subdirs; plain
# ccflags-y does not reach tty.c and rfcomm.h sees no RFCOMM_TTY.
subdir-ccflags-y += -DCONFIG_BT_MODULE=1
subdir-ccflags-y += -DCONFIG_BT_BREDR=1
subdir-ccflags-y += -DCONFIG_BT_LE=1
subdir-ccflags-y += -DCONFIG_BT_HS=1
subdir-ccflags-y += -DCONFIG_BT_LEDS=1
subdir-ccflags-y += -DCONFIG_BT_RFCOMM_MODULE=1
# Must match make CONFIG_BT_RFCOMM_TTY=y. Without this, rfcomm.h
# emits static inline stubs and tty.c redefines rfcomm_*_ttys.
subdir-ccflags-y += -DCONFIG_BT_RFCOMM_TTY=1
subdir-ccflags-y += -DCONFIG_BT_BNEP_MODULE=1
subdir-ccflags-y += -DCONFIG_BT_BNEP_MC_FILTER=1
subdir-ccflags-y += -DCONFIG_BT_BNEP_PROTO_FILTER=1
subdir-ccflags-y += -DCONFIG_BT_HIDP_MODULE=1
subdir-ccflags-y += -DCONFIG_BT_LE_L2CAP_ECRED=1
EOF
    cat "$SOURCE_DIR/net/bluetooth/Makefile"
} > "$BTNET_DIR/Makefile"
make -C "$BUILD_DIR" M="$BTNET_DIR" \
    CONFIG_BT=m CONFIG_BT_BREDR=y CONFIG_BT_LE=y CONFIG_BT_HS=y CONFIG_BT_LEDS=y \
    CONFIG_BT_RFCOMM=m CONFIG_BT_RFCOMM_TTY=y CONFIG_BT_BNEP=m \
    CONFIG_BT_BNEP_MC_FILTER=y CONFIG_BT_BNEP_PROTO_FILTER=y CONFIG_BT_HIDP=m \
    CONFIG_BT_CMTP=n CONFIG_BT_LE_L2CAP_ECRED=y CONFIG_BT_DEBUGFS=n \
    CONFIG_BT_FEATURE_DEBUG=n CONFIG_BT_SELFTEST=n \
    modules
BTDRV_DIR="$WORKDIR/btdrv"
rm -rf "$BTDRV_DIR"
cp -a "$SOURCE_DIR/drivers/bluetooth" "$BTDRV_DIR"
# CRITICAL: drivers/bluetooth and net/bluetooth MUST see the same
# CONFIG_BT_* values for include/net/bluetooth/hci_core.h.
# CONFIG_BT_LEDS inserts hdev->power_led before open/close/setup/
# shutdown/send. If LEDs is on in bluetooth.ko but off in btintel.ko,
# btintel_configure_setup writes setup/shutdown into the wrong offsets
# and hci_power_on crashes in sk_skb_reason_drop (bare-metal 2026-08-03).
cat > "$BTDRV_DIR/Makefile" <<'EOF'
ccflags-y += -DCONFIG_BT_MODULE=1
ccflags-y += -DCONFIG_BT_BREDR=1
ccflags-y += -DCONFIG_BT_LE=1
ccflags-y += -DCONFIG_BT_HS=1
ccflags-y += -DCONFIG_BT_LEDS=1
ccflags-y += -DCONFIG_BT_LE_L2CAP_ECRED=1
ccflags-y += -DCONFIG_BT_HCIBTUSB_MODULE=1
# Helper libs: IS_ENABLED(CONFIG_BT_*) needs *_MODULE or builtin define
# or headers emit static inline stubs and *.c redefines the symbols.
ccflags-y += -DCONFIG_BT_BCM_MODULE=1
ccflags-y += -DCONFIG_BT_INTEL_MODULE=1
ccflags-y += -DCONFIG_BT_RTL_MODULE=1
ccflags-y += -DCONFIG_BT_MTK_MODULE=1
ccflags-y += -DCONFIG_BT_HCIBTUSB_BCM=1
ccflags-y += -DCONFIG_BT_HCIBTUSB_MTK=1
ccflags-y += -DCONFIG_BT_HCIBTUSB_RTL=1
ccflags-y += -DCONFIG_BT_HCIBTUSB_POLL_SYNC=1
ccflags-y += -I$(src)
obj-m += btusb.o btintel.o btrtl.o btbcm.o btmtk.o
EOF
make -C "$BUILD_DIR" M="$BTDRV_DIR" \
    KBUILD_EXTRA_SYMBOLS="$BTNET_DIR/Module.symvers" \
    CONFIG_BT=m CONFIG_BT_BREDR=y CONFIG_BT_LE=y CONFIG_BT_HS=y CONFIG_BT_LEDS=y \
    CONFIG_BT_LE_L2CAP_ECRED=y \
    CONFIG_BT_HCIBTUSB=m CONFIG_BT_INTEL=m CONFIG_BT_RTL=m CONFIG_BT_BCM=m CONFIG_BT_MTK=m \
    CONFIG_BT_HCIBTUSB_BCM=y CONFIG_BT_HCIBTUSB_MTK=y CONFIG_BT_HCIBTUSB_RTL=y \
    CONFIG_BT_HCIBTUSB_POLL_SYNC=y \
    modules
mapfile -t BT_MODULES < <(find "$BTNET_DIR" "$BTDRV_DIR" -name '*.ko' | sort)
test "${#BT_MODULES[@]}" -ge 6
check_vermagic "${BT_MODULES[@]}"
echo "=== stage bluetooth done ==="
fi

# --- uvcvideo (+ UVC_COMMON helper) ---
if run_stage uvc; then
echo "=== stage uvc ==="
UVC_DIR="$WORKDIR/uvc"
rm -rf "$UVC_DIR"
mkdir -p "$UVC_DIR"
cp -a "$SOURCE_DIR/drivers/media/usb/uvc/." "$UVC_DIR/"
# USB_VIDEO_CLASS selects UVC_COMMON (drivers/media/common/uvc.c).
cp "$SOURCE_DIR/drivers/media/common/uvc.c" "$UVC_DIR/uvc-common.c"
cat > "$UVC_DIR/Makefile" <<'EOF'
ccflags-y += -DCONFIG_USB_VIDEO_CLASS_MODULE=1
ccflags-y += -DCONFIG_UVC_COMMON_MODULE=1
obj-m += uvc.o
uvc-y := uvc-common.o
obj-m += uvcvideo.o
uvcvideo-y := uvc_driver.o uvc_queue.o uvc_v4l2.o uvc_video.o uvc_ctrl.o \
	uvc_status.o uvc_isight.o uvc_debugfs.o uvc_metadata.o uvc_entity.o
EOF
make -C "$BUILD_DIR" M="$UVC_DIR" \
    CONFIG_USB_VIDEO_CLASS=m CONFIG_UVC_COMMON=m CONFIG_MEDIA_CONTROLLER=y \
    modules
UVC_COMMON_MODULE="$UVC_DIR/uvc.ko"
UVC_MODULE="$UVC_DIR/uvcvideo.ko"
check_vermagic "$UVC_COMMON_MODULE" "$UVC_MODULE"
echo "=== stage uvc done ==="
fi

# --- acpibattery: shared ACPI_BATTERY hook core (drivers/acpi/battery.c) ---
# Stock AZL cloud kernel leaves CONFIG_ACPI_BATTERY off. thinkpad_acpi,
# ideapad-laptop, lenovo-ymc, dell-laptop, and asus-wmi all hard-depend on
# battery_hook_register()/devm_battery_hook_register() at link time, so
# this ships as its own small foundational package. Every family below
# that needs it still compiles its own private, unshipped copy of
# battery.o against its own isolated CI container purely to satisfy
# modpost (families build in independent matrix jobs, no shared
# Module.symvers between them) and Requires: this package at runtime.
if run_stage acpibattery; then
echo "=== stage acpibattery ==="
AB_DIR="$WORKDIR/acpibattery"
rm -rf "$AB_DIR"
mkdir -p "$AB_DIR"
cp "$SOURCE_DIR/drivers/acpi/battery.c" "$AB_DIR/"
cat > "$AB_DIR/Makefile" <<'EOF'
obj-m += battery.o
EOF
make -C "$BUILD_DIR" M="$AB_DIR" modules
check_vermagic "$AB_DIR/battery.ko"
echo "=== stage acpibattery done ==="
fi

# --- thinkpad_acpi (+ ACPI battery + privacy-screen class + Lenovo consumer) ---
if run_stage thinkpad; then
echo "=== stage thinkpad ==="
TP_DIR="$WORKDIR/thinkpad"
rm -rf "$TP_DIR"
mkdir -p "$TP_DIR/battery-build" "$TP_DIR/privacy-build" "$TP_DIR/tp-build"

# Private, unshipped copy of battery.o for link-time symbols only.
# azurelinux-desktop-acpi-battery-kmod ships the real battery.ko.
cp "$SOURCE_DIR/drivers/acpi/battery.c" "$TP_DIR/battery-build/"
cat > "$TP_DIR/battery-build/Makefile" <<'EOF'
obj-m += battery.o
EOF
make -C "$BUILD_DIR" M="$TP_DIR/battery-build" modules

cp "$SOURCE_DIR/drivers/gpu/drm/drm_privacy_screen.c" \
    "$TP_DIR/privacy-build/drm_privacy_screen.c"
# drm_class is not exported; use a module-local class instead.
python3 - "$TP_DIR/privacy-build/drm_privacy_screen.c" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('#include "drm_internal.h"\n', '')
marker = '#include <drm/drm_privacy_screen_driver.h>\n'
inject = marker + '\nstatic struct class *drm_privacy_screen_class;\n'
if marker not in text:
    raise SystemExit('include marker missing')
if 'static struct class *drm_privacy_screen_class' not in text:
    text = text.replace(marker, inject, 1)
old = "\tpriv->dev.class = drm_class;\n"
new = "\tpriv->dev.class = drm_privacy_screen_class;\n"
if old not in text:
    raise SystemExit("drm_class assignment not found")
text = text.replace(old, new, 1)
if 'drm_privacy_screen_init' not in text:
    text += """
static int __init drm_privacy_screen_init(void)
{
	drm_privacy_screen_class = class_create("drm_privacy_screen");
	return PTR_ERR_OR_ZERO(drm_privacy_screen_class);
}

static void __exit drm_privacy_screen_exit(void)
{
	if (!IS_ERR_OR_NULL(drm_privacy_screen_class))
		class_destroy(drm_privacy_screen_class);
}

module_init(drm_privacy_screen_init);
module_exit(drm_privacy_screen_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("DRM privacy-screen class (OOT helper)");
"""
path.write_text(text)
PY
cat > "$TP_DIR/privacy-build/Makefile" <<'EOF'
ccflags-y += -DCONFIG_DRM_PRIVACY_SCREEN_MODULE=1
obj-m += drm_privacy_screen.o
EOF
make -C "$BUILD_DIR" M="$TP_DIR/privacy-build" modules

cp "$SOURCE_DIR/drivers/platform/x86/lenovo/thinkpad_acpi.c" "$TP_DIR/tp-build/"
cp "$SOURCE_DIR/drivers/platform/x86/dual_accel_detect.h" "$TP_DIR/tp-build/"
sed -i 's|#include "../dual_accel_detect.h"|#include "dual_accel_detect.h"|' \
    "$TP_DIR/tp-build/thinkpad_acpi.c"
# No ALSA console mixer: stock AZL has no CONFIG_SND; sound is a sibling
# OOT package and may build in parallel without shared Module.symvers.
cat > "$TP_DIR/tp-build/Makefile" <<'EOF'
ccflags-y += -DCONFIG_THINKPAD_ACPI_MODULE=1
ccflags-y += -DCONFIG_THINKPAD_ACPI_VIDEO=1
ccflags-y += -DCONFIG_THINKPAD_ACPI_HOTKEY_POLL=1
ccflags-y += -DCONFIG_DRM_PRIVACY_SCREEN_MODULE=1
ccflags-y += -DCONFIG_ACPI_BATTERY_MODULE=1
obj-m += thinkpad_acpi.o
EOF
EXTRA_SYM=()
for sv in \
    "$TP_DIR/battery-build/Module.symvers" \
    "$TP_DIR/privacy-build/Module.symvers"
do
    [[ -f "$sv" ]] || continue
    EXTRA_SYM+=("$sv")
done
MAKE_EXTRA=()
if ((${#EXTRA_SYM[@]})); then
    MAKE_EXTRA=(KBUILD_EXTRA_SYMBOLS="${EXTRA_SYM[*]}")
fi
make -C "$BUILD_DIR" M="$TP_DIR/tp-build" \
    "${MAKE_EXTRA[@]}" \
    CONFIG_THINKPAD_ACPI=m \
    modules

cp -f "$TP_DIR/privacy-build/drm_privacy_screen.ko" "$TP_DIR/drm_privacy_screen.ko"
cp -f "$TP_DIR/tp-build/thinkpad_acpi.ko" "$TP_DIR/thinkpad_acpi.ko"
check_vermagic \
    "$TP_DIR/drm_privacy_screen.ko" \
    "$TP_DIR/thinkpad_acpi.ko"

# thinkpad_acpi: HOTKEY_POLL + VIDEO forced via ccflags above.
# ALSA_SUPPORT stays off — sound is a sibling OOT package without shared
# Module.symvers during parallel family CI builds.

# HID Lenovo (TrackPoint keyboards, compact keyboards) — stock off.
# hid-ids.h lives only in drivers/hid/ (not exported by kernel-devel).
if [[ -f "$SOURCE_DIR/drivers/hid/hid-lenovo.c" ]]; then
    mkdir -p "$TP_DIR/hid"
    cp "$SOURCE_DIR/drivers/hid/hid-lenovo.c" "$TP_DIR/hid/"
    cp "$SOURCE_DIR/drivers/hid/hid-ids.h" "$TP_DIR/hid/"
    cat > "$TP_DIR/hid/Makefile" <<'EOF'
ccflags-y += -I$(src)
ccflags-y += -DCONFIG_HID_LENOVO_MODULE=1
obj-m += hid-lenovo.o
EOF
    make -C "$BUILD_DIR" M="$TP_DIR/hid" CONFIG_HID_LENOVO=m modules
    cp -f "$TP_DIR/hid/hid-lenovo.ko" "$TP_DIR/hid-lenovo.ko"
    check_vermagic "$TP_DIR/hid-lenovo.ko"
fi

# ideapad-laptop (+ lenovo-ymc) — Lenovo consumer laptop extras (rfkill,
# hotkeys, backlight, fan/thermal profile) and Yoga tablet-mode switch.
# Stock AZL has both off; both are in-tree, no firmware blobs. Same
# ACPI battery hook as thinkpad_acpi, so reuse battery-build's symvers.
# Shares this package rather than getting its own: same Lenovo vendor,
# same "consumer sibling of the enterprise ThinkPad line" scope.
if [[ -f "$SOURCE_DIR/drivers/platform/x86/lenovo/ideapad-laptop.c" ]]; then
    mkdir -p "$TP_DIR/ideapad"
    cp "$SOURCE_DIR/drivers/platform/x86/lenovo/ideapad-laptop.c" "$TP_DIR/ideapad/"
    cp "$SOURCE_DIR/drivers/platform/x86/lenovo/ideapad-laptop.h" "$TP_DIR/ideapad/"
    cat > "$TP_DIR/ideapad/Makefile" <<'EOF'
obj-m += ideapad-laptop.o
EOF
    make -C "$BUILD_DIR" M="$TP_DIR/ideapad" \
        KBUILD_EXTRA_SYMBOLS="$TP_DIR/battery-build/Module.symvers" \
        modules
    cp -f "$TP_DIR/ideapad/ideapad-laptop.ko" "$TP_DIR/ideapad-laptop.ko"
    check_vermagic "$TP_DIR/ideapad-laptop.ko"

    if [[ -f "$SOURCE_DIR/drivers/platform/x86/lenovo/ymc.c" ]]; then
        mkdir -p "$TP_DIR/ymc"
        cp "$SOURCE_DIR/drivers/platform/x86/lenovo/ymc.c" "$TP_DIR/ymc/"
        cp "$SOURCE_DIR/drivers/platform/x86/lenovo/ideapad-laptop.h" "$TP_DIR/ymc/"
        cat > "$TP_DIR/ymc/Makefile" <<'EOF'
obj-m += ymc.o
EOF
        make -C "$BUILD_DIR" M="$TP_DIR/ymc" \
            KBUILD_EXTRA_SYMBOLS="$TP_DIR/battery-build/Module.symvers $TP_DIR/ideapad/Module.symvers" \
            modules
        cp -f "$TP_DIR/ymc/ymc.ko" "$TP_DIR/ymc.ko"
        check_vermagic "$TP_DIR/ymc.ko"
    fi
fi

# USB WWAN / tethering stack — CONFIG_USB_NET_DRIVERS off on AZL x86_64.
# Provides cdc_mbim / qmi_wwan for LTE WWAN cards and phone tether.
WWAN_DIR="$TP_DIR/wwan"
mkdir -p "$WWAN_DIR"
for f in usbnet.c cdc_ether.c cdc_ncm.c cdc_mbim.c qmi_wwan.c; do
    if [[ -f "$SOURCE_DIR/drivers/net/usb/$f" ]]; then
        cp "$SOURCE_DIR/drivers/net/usb/$f" "$WWAN_DIR/"
    fi
done
# cdc-wdm (USB_WDM) for QMI control path
if [[ -f "$SOURCE_DIR/drivers/usb/class/cdc-wdm.c" ]]; then
    cp "$SOURCE_DIR/drivers/usb/class/cdc-wdm.c" "$WWAN_DIR/"
fi
# Headers commonly included by usbnet clients
for h in usbnet.h; do
    if [[ -f "$SOURCE_DIR/drivers/net/usb/$h" ]]; then
        cp "$SOURCE_DIR/drivers/net/usb/$h" "$WWAN_DIR/"
    fi
done
cat > "$WWAN_DIR/Makefile" <<'EOF'
ccflags-y += -DCONFIG_USB_USBNET_MODULE=1
ccflags-y += -DCONFIG_USB_NET_CDCETHER_MODULE=1
ccflags-y += -DCONFIG_USB_NET_CDC_NCM_MODULE=1
ccflags-y += -DCONFIG_USB_NET_CDC_MBIM_MODULE=1
ccflags-y += -DCONFIG_USB_NET_QMI_WWAN_MODULE=1
ccflags-y += -DCONFIG_USB_WDM_MODULE=1
ccflags-y += -I$(src)
obj-m += usbnet.o
obj-m += cdc_ether.o
obj-m += cdc_ncm.o
obj-m += cdc_mbim.o
obj-m += qmi_wwan.o
obj-m += cdc-wdm.o
EOF
if [[ ! -f "$WWAN_DIR/cdc-wdm.c" ]]; then
    sed -i '/cdc-wdm/d; /USB_WDM/d' "$WWAN_DIR/Makefile"
fi
if [[ ! -f "$WWAN_DIR/qmi_wwan.c" ]]; then
    sed -i '/qmi_wwan/d; /QMI_WWAN/d' "$WWAN_DIR/Makefile"
fi
if [[ ! -f "$WWAN_DIR/cdc_mbim.c" ]]; then
    sed -i '/cdc_mbim/d; /CDC_MBIM/d' "$WWAN_DIR/Makefile"
fi
make -C "$BUILD_DIR" M="$WWAN_DIR" \
    CONFIG_USB_USBNET=m CONFIG_USB_NET_CDCETHER=m CONFIG_USB_NET_CDC_NCM=m \
    CONFIG_USB_NET_CDC_MBIM=m CONFIG_USB_NET_QMI_WWAN=m CONFIG_USB_WDM=m \
    modules
find "$WWAN_DIR" -name '*.ko' -exec cp -t "$TP_DIR/" {} +
test -f "$TP_DIR/usbnet.ko"
check_vermagic "$TP_DIR/usbnet.ko"
echo "=== stage thinkpad done ==="
fi

# --- hid-multitouch (generic HID-over-I2C Precision Touchpad/digitizer) ---
# Stock AZL has CONFIG_I2C_HID=m but CONFIG_HID_MULTITOUCH off. Several
# modern laptops (not just Surface/ThinkPad) report their trackpad or
# touchscreen through the generic Windows Precision Touchpad protocol
# over i2c-hid rather than a vendor-specific PS/2 or SMBus path, so this
# ships as its own small, hardware-neutral package instead of being
# locked inside surface-kmod. thinkpad-kmod recommends it.
if run_stage hidmt; then
echo "=== stage hidmt ==="
HIDMT_DIR="$WORKDIR/hidmt"
rm -rf "$HIDMT_DIR"
mkdir -p "$HIDMT_DIR"
cp "$SOURCE_DIR/drivers/hid/hid-multitouch.c" "$HIDMT_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-ids.h" "$HIDMT_DIR/"
if [[ -f "$SOURCE_DIR/drivers/hid/hid-haptic.h" ]]; then
    cp "$SOURCE_DIR/drivers/hid/hid-haptic.h" "$HIDMT_DIR/"
fi
cat > "$HIDMT_DIR/Makefile" <<'EOF'
ccflags-y += -I$(src)
ccflags-y += -DCONFIG_HID_MULTITOUCH_MODULE=1
obj-m += hid-multitouch.o
EOF
make -C "$BUILD_DIR" M="$HIDMT_DIR" CONFIG_HID_MULTITOUCH=m modules
test -f "$HIDMT_DIR/hid-multitouch.ko"
check_vermagic "$HIDMT_DIR/hid-multitouch.ko"
echo "=== stage hidmt done ==="
fi

# --- touchpad: I2C-native precision touchpads (ELAN + Synaptics RMI4 I2C) ---
# Stock AZL has CONFIG_I2C=y but CONFIG_MOUSE_ELAN_I2C and CONFIG_RMI4_I2C
# are both off. psmouse-kmod already covers PS/2 and RMI4-over-SMBus
# (used by many ThinkPads); a lot of other consumer and enterprise
# laptops (Dell, HP, ASUS, Acer, and some newer ThinkPads) instead wire
# their trackpad straight to an I2C bus, either as a native ELAN
# controller or a Synaptics RMI4 device over plain I2C rather than
# SMBus. Ships as its own family, self-contained (its own rmi_core
# build) so it does not depend on the psmouse stage's artifacts.
if run_stage touchpad; then
echo "=== stage touchpad ==="
TOUCHPAD_DIR="$WORKDIR/touchpad"
rm -rf "$TOUCHPAD_DIR"
mkdir -p "$TOUCHPAD_DIR/rmi4" "$TOUCHPAD_DIR/elan"

if [[ -d "$SOURCE_DIR/drivers/input/rmi4" ]]; then
    for f in rmi_bus.c rmi_bus.h rmi_driver.c rmi_driver.h rmi_f01.c \
        rmi_2d_sensor.c rmi_2d_sensor.h rmi_f03.c rmi_f11.c rmi_f12.c \
        rmi_f30.c rmi_i2c.c; do
        cp "$SOURCE_DIR/drivers/input/rmi4/$f" "$TOUCHPAD_DIR/rmi4/"
    done
    cat > "$TOUCHPAD_DIR/rmi4/Makefile" <<'EOF'
ccflags-y += -DCONFIG_RMI4_CORE_MODULE=1
ccflags-y += -DCONFIG_RMI4_2D_SENSOR=1
ccflags-y += -DCONFIG_RMI4_F03=1
ccflags-y += -DCONFIG_RMI4_F03_SERIO=1
ccflags-y += -DCONFIG_RMI4_F11=1
ccflags-y += -DCONFIG_RMI4_F12=1
ccflags-y += -DCONFIG_RMI4_F30=1
ccflags-y += -DCONFIG_RMI4_I2C_MODULE=1

obj-m += rmi_core.o
rmi_core-y := rmi_bus.o rmi_driver.o rmi_f01.o
rmi_core-y += rmi_2d_sensor.o
rmi_core-y += rmi_f03.o
rmi_core-y += rmi_f11.o
rmi_core-y += rmi_f12.o
rmi_core-y += rmi_f30.o

obj-m += rmi_i2c.o
EOF
    make -C "$BUILD_DIR" M="$TOUCHPAD_DIR/rmi4" modules
    cp -f "$TOUCHPAD_DIR/rmi4/rmi_core.ko" "$TOUCHPAD_DIR/rmi_core.ko"
    cp -f "$TOUCHPAD_DIR/rmi4/rmi_i2c.ko" "$TOUCHPAD_DIR/rmi_i2c.ko"
    check_vermagic "$TOUCHPAD_DIR/rmi_core.ko" "$TOUCHPAD_DIR/rmi_i2c.ko"
else
    echo "warning: drivers/input/rmi4 missing; skipping rmi_i2c" >&2
fi

if [[ -f "$SOURCE_DIR/drivers/input/mouse/elan_i2c_core.c" ]]; then
    cp "$SOURCE_DIR/drivers/input/mouse/elan_i2c.h" "$TOUCHPAD_DIR/elan/"
    cp "$SOURCE_DIR/drivers/input/mouse/elan_i2c_core.c" "$TOUCHPAD_DIR/elan/"
    cp "$SOURCE_DIR/drivers/input/mouse/elan_i2c_i2c.c" "$TOUCHPAD_DIR/elan/"
    cp "$SOURCE_DIR/drivers/input/mouse/elan_i2c_smbus.c" "$TOUCHPAD_DIR/elan/"
    cat > "$TOUCHPAD_DIR/elan/Makefile" <<'EOF'
ccflags-y += -I$(src)
ccflags-y += -DCONFIG_MOUSE_ELAN_I2C_MODULE=1
ccflags-y += -DCONFIG_MOUSE_ELAN_I2C_I2C=1
ccflags-y += -DCONFIG_MOUSE_ELAN_I2C_SMBUS=1

obj-m += elan_i2c.o
elan_i2c-y := elan_i2c_core.o elan_i2c_i2c.o elan_i2c_smbus.o
EOF
    make -C "$BUILD_DIR" M="$TOUCHPAD_DIR/elan" modules
    cp -f "$TOUCHPAD_DIR/elan/elan_i2c.ko" "$TOUCHPAD_DIR/elan_i2c.ko"
    check_vermagic "$TOUCHPAD_DIR/elan_i2c.ko"
else
    echo "warning: elan_i2c_core.c missing; skipping elan_i2c" >&2
fi
echo "=== stage touchpad done ==="
fi

# --- logitech: HID++ / Unifying receiver for wireless mice + keyboards ---
# Stock AZL has CONFIG_HID=y but CONFIG_HID_LOGITECH_DJ and
# CONFIG_HID_LOGITECH_HIDPP are both off, so hid-generic cannot decode
# the Logitech Unifying receiver's multiplexed HID++ reports. Very
# common on both consumer and enterprise desks (Unifying receivers, MX
# Series, Bluetooth HID++ mice/keyboards).
if run_stage logitech; then
echo "=== stage logitech ==="
LOGI_DIR="$WORKDIR/logitech"
rm -rf "$LOGI_DIR"
mkdir -p "$LOGI_DIR/usbhid"
cp "$SOURCE_DIR/drivers/hid/hid-logitech-dj.c" "$LOGI_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-logitech-hidpp.c" "$LOGI_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-ids.h" "$LOGI_DIR/"
# hid-logitech-hidpp.c #includes "usbhid/usbhid.h" relative to drivers/hid.
cp "$SOURCE_DIR/drivers/hid/usbhid/usbhid.h" "$LOGI_DIR/usbhid/"
cat > "$LOGI_DIR/Makefile" <<'EOF'
ccflags-y += -I$(src)
ccflags-y += -DCONFIG_HID_LOGITECH_DJ_MODULE=1
ccflags-y += -DCONFIG_HID_LOGITECH_HIDPP_MODULE=1

obj-m += hid-logitech-dj.o
obj-m += hid-logitech-hidpp.o
EOF
make -C "$BUILD_DIR" M="$LOGI_DIR" modules
check_vermagic "$LOGI_DIR/hid-logitech-dj.ko" "$LOGI_DIR/hid-logitech-hidpp.ko"
echo "=== stage logitech done ==="
fi

# --- hidquirks: ASUS laptop keys/backlight + ELAN HID-mode touchpad quirks ---
# Two small standalone vendor quirk drivers with no framework
# dependency beyond core HID. hid-asus covers extra keys, keyboard
# backlight, and the ASUS multi-touch touchpad quirk on consumer and
# ProArt/commercial ASUS laptops. hid-elan covers ELAN touchpads that
# present over plain USB/HID rather than native I2C (elan_i2c, in
# touchpad-kmod, is the separate native-I2C transport).
if run_stage hidquirks; then
echo "=== stage hidquirks ==="
HIDQ_DIR="$WORKDIR/hidquirks"
rm -rf "$HIDQ_DIR"
mkdir -p "$HIDQ_DIR"
cp "$SOURCE_DIR/drivers/hid/hid-asus.c" "$HIDQ_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-elan.c" "$HIDQ_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-ids.h" "$HIDQ_DIR/"
cat > "$HIDQ_DIR/Makefile" <<'EOF'
ccflags-y += -I$(src)
ccflags-y += -DCONFIG_HID_ASUS_MODULE=1
ccflags-y += -DCONFIG_HID_ELAN_MODULE=1

obj-m += hid-asus.o
obj-m += hid-elan.o
EOF
make -C "$BUILD_DIR" M="$HIDQ_DIR" modules
check_vermagic "$HIDQ_DIR/hid-asus.ko" "$HIDQ_DIR/hid-elan.ko"
echo "=== stage hidquirks done ==="
fi

# --- tablet: drawing tablet / pen digitizer HID drivers ---
# Common consumer graphics-tablet HID drivers, all off in stock AZL:
# Wacom Intuos/Bamboo/Cintiq (USB and Bluetooth), Huion/UC-Logic, and
# Waltop tablets. Only depend on USB_HID (usbhid-kmod already ships
# that) plus POWER_SUPPLY/LEDS_CLASS/LEDS_TRIGGERS, all stock in-tree.
# No firmware blobs. hid-uclogic-core.c needs the same private
# usbhid/usbhid.h + hid-ids.h headers the surface/hidquirks stages
# already stage from source; not shipped in kernel-devel.
if run_stage tablet; then
echo "=== stage tablet ==="
TABLET_DIR="$WORKDIR/tablet"
rm -rf "$TABLET_DIR"
mkdir -p "$TABLET_DIR/usbhid"
cp "$SOURCE_DIR/drivers/hid/wacom.h" "$TABLET_DIR/"
cp "$SOURCE_DIR/drivers/hid/wacom_sys.c" "$TABLET_DIR/"
cp "$SOURCE_DIR/drivers/hid/wacom_wac.c" "$TABLET_DIR/"
cp "$SOURCE_DIR/drivers/hid/wacom_wac.h" "$TABLET_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-uclogic-core.c" "$TABLET_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-uclogic-params.c" "$TABLET_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-uclogic-params.h" "$TABLET_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-uclogic-rdesc.c" "$TABLET_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-uclogic-rdesc.h" "$TABLET_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-waltop.c" "$TABLET_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-ids.h" "$TABLET_DIR/"
cp "$SOURCE_DIR/drivers/hid/usbhid/usbhid.h" "$TABLET_DIR/usbhid/"
cat > "$TABLET_DIR/Makefile" <<'EOF'
ccflags-y += -I$(src)
ccflags-y += -DCONFIG_HID_WACOM_MODULE=1
ccflags-y += -DCONFIG_HID_UCLOGIC_MODULE=1
ccflags-y += -DCONFIG_HID_WALTOP_MODULE=1

obj-m += wacom.o
wacom-y := wacom_wac.o wacom_sys.o

obj-m += hid-uclogic.o
hid-uclogic-y := hid-uclogic-core.o hid-uclogic-rdesc.o hid-uclogic-params.o

obj-m += hid-waltop.o
EOF
make -C "$BUILD_DIR" M="$TABLET_DIR" modules
check_vermagic "$TABLET_DIR/wacom.ko" "$TABLET_DIR/hid-uclogic.ko" "$TABLET_DIR/hid-waltop.ko"
echo "=== stage tablet done ==="
fi

# --- usbeth: USB Ethernet adapters common in docks/dongles ---
# CONFIG_USB_NET_CDCETHER and generic USBNET/RNDIS are already stock,
# but the three most common standalone USB Ethernet chipsets are all
# off: Realtek RTL8152/8153 (nearly every USB-C dock/hub), older ASIX
# AX8817X, and the newer, more common AX88179/178A USB3 gigabit chips.
# Wired ethernet through one of these is often the easiest fallback
# when a laptop's built-in Wi-Fi chipset isn't covered (see the Wi-Fi
# vendor gap noted above).
if run_stage usbeth; then
echo "=== stage usbeth ==="
USBETH_DIR="$WORKDIR/usbeth"
rm -rf "$USBETH_DIR"
mkdir -p "$USBETH_DIR"
cp "$SOURCE_DIR/drivers/net/usb/r8152.c" "$USBETH_DIR/"
cp "$SOURCE_DIR/drivers/net/usb/asix.h" "$USBETH_DIR/"
cp "$SOURCE_DIR/drivers/net/usb/asix_common.c" "$USBETH_DIR/"
cp "$SOURCE_DIR/drivers/net/usb/asix_devices.c" "$USBETH_DIR/"
cp "$SOURCE_DIR/drivers/net/usb/ax88172a.c" "$USBETH_DIR/"
cp "$SOURCE_DIR/drivers/net/usb/ax88179_178a.c" "$USBETH_DIR/"
cat > "$USBETH_DIR/Makefile" <<'EOF'
ccflags-y += -I$(src)
ccflags-y += -DCONFIG_USB_RTL8152_MODULE=1
ccflags-y += -DCONFIG_USB_NET_AX8817X_MODULE=1
ccflags-y += -DCONFIG_USB_NET_AX88179_178A_MODULE=1

obj-m += r8152.o
obj-m += asix.o
asix-y := asix_devices.o asix_common.o ax88172a.o
obj-m += ax88179_178a.o
EOF
make -C "$BUILD_DIR" M="$USBETH_DIR" modules
check_vermagic "$USBETH_DIR/r8152.ko" "$USBETH_DIR/asix.ko" "$USBETH_DIR/ax88179_178a.ko"
echo "=== stage usbeth done ==="
fi

# --- gamepad: common USB/Bluetooth game controllers ---
# CONFIG_HID_STEAM is stock, but the three most common consumer
# controller families are all off: wired Xbox controllers (xpad),
# PS3/PS4 DualShock (hid-sony), and PS5 DualSense (hid-playstation,
# needs the small standalone multicolor LED class for its lightbar/
# mic-mute LED - not the missing-subsystem class of problem the card
# reader and HID sensor hub gaps turned out to be). Force feedback
# (JOYSTICK_XPAD_FF, SONY_FF, PLAYSTATION_FF) and the Xbox LED ring
# (JOYSTICK_XPAD_LEDS) are plain bool options depending only on
# INPUT_FF_MEMLESS/LEDS_CLASS, both already stock =m; without the
# ccflags -D below, rumble and the LED ring silently no-op even though
# the modules build and load fine.
if run_stage gamepad; then
echo "=== stage gamepad ==="
GAMEPAD_DIR="$WORKDIR/gamepad"
rm -rf "$GAMEPAD_DIR"
mkdir -p "$GAMEPAD_DIR"
cp "$SOURCE_DIR/drivers/input/joystick/xpad.c" "$GAMEPAD_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-sony.c" "$GAMEPAD_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-playstation.c" "$GAMEPAD_DIR/"
cp "$SOURCE_DIR/drivers/hid/hid-ids.h" "$GAMEPAD_DIR/"
cp "$SOURCE_DIR/drivers/leds/led-class-multicolor.c" "$GAMEPAD_DIR/"
cat > "$GAMEPAD_DIR/Makefile" <<'EOF'
ccflags-y += -I$(src)
ccflags-y += -DCONFIG_JOYSTICK_XPAD_MODULE=1
ccflags-y += -DCONFIG_JOYSTICK_XPAD_FF=1
ccflags-y += -DCONFIG_JOYSTICK_XPAD_LEDS=1
ccflags-y += -DCONFIG_HID_SONY_MODULE=1
ccflags-y += -DCONFIG_SONY_FF=1
ccflags-y += -DCONFIG_LEDS_CLASS_MULTICOLOR_MODULE=1
ccflags-y += -DCONFIG_HID_PLAYSTATION_MODULE=1
ccflags-y += -DCONFIG_PLAYSTATION_FF=1

obj-m += xpad.o
obj-m += hid-sony.o
obj-m += led-class-multicolor.o
obj-m += hid-playstation.o
EOF
make -C "$BUILD_DIR" M="$GAMEPAD_DIR" modules
check_vermagic "$GAMEPAD_DIR/xpad.ko" "$GAMEPAD_DIR/hid-sony.ko" \
    "$GAMEPAD_DIR/led-class-multicolor.ko" "$GAMEPAD_DIR/hid-playstation.ko"
echo "=== stage gamepad done ==="
fi

# --- dell: Dell Latitude/XPS/Precision rfkill+backlight extras ---
# Stock AZL has DELL_WMI/DELL_SMBIOS on but DELL_LAPTOP off. In-tree, no
# firmware blobs; needs the same ACPI battery hook thinkpad_acpi does.
# Private, unshipped battery.o for link-time symbols only —
# azurelinux-desktop-acpi-battery-kmod ships the real one at runtime.
if run_stage dell; then
echo "=== stage dell ==="
DELL_DIR="$WORKDIR/dell"
rm -rf "$DELL_DIR"
mkdir -p "$DELL_DIR/battery-build" "$DELL_DIR/build"
cp "$SOURCE_DIR/drivers/acpi/battery.c" "$DELL_DIR/battery-build/"
cat > "$DELL_DIR/battery-build/Makefile" <<'EOF'
obj-m += battery.o
EOF
make -C "$BUILD_DIR" M="$DELL_DIR/battery-build" modules

cp "$SOURCE_DIR/drivers/platform/x86/dell/dell-laptop.c" "$DELL_DIR/build/"
cp "$SOURCE_DIR/drivers/platform/x86/dell/dell-rbtn.h" "$DELL_DIR/build/"
cp "$SOURCE_DIR/drivers/platform/x86/dell/dell-smbios.h" "$DELL_DIR/build/"
cp "$SOURCE_DIR/drivers/platform/x86/dell/dell-wmi-privacy.h" "$DELL_DIR/build/"
cat > "$DELL_DIR/build/Makefile" <<'EOF'
ccflags-y += -I$(src)
obj-m += dell-laptop.o
EOF
make -C "$BUILD_DIR" M="$DELL_DIR/build" \
    KBUILD_EXTRA_SYMBOLS="$DELL_DIR/battery-build/Module.symvers" \
    modules
cp -f "$DELL_DIR/build/dell-laptop.ko" "$DELL_DIR/dell-laptop.ko"
check_vermagic "$DELL_DIR/dell-laptop.ko"
echo "=== stage dell done ==="
fi

# --- asus: ASUS WMI platform driver (backlight, rfkill, hotkeys, fan) ---
# Stock AZL has the legacy ASUS_LAPTOP on but ASUS_WMI/ASUS_NB_WMI (the
# modern replacement most current ASUS laptops need) off. In-tree, no
# firmware blobs; also needs the ACPI battery hook. hid-asus in
# azurelinux-desktop-hid-quirks-kmod covers HID-level quirks separately;
# this is the platform/WMI driver, a different kernel subsystem.
if run_stage asus; then
echo "=== stage asus ==="
ASUS_DIR="$WORKDIR/asus"
rm -rf "$ASUS_DIR"
mkdir -p "$ASUS_DIR/battery-build" "$ASUS_DIR/build"
cp "$SOURCE_DIR/drivers/acpi/battery.c" "$ASUS_DIR/battery-build/"
cat > "$ASUS_DIR/battery-build/Makefile" <<'EOF'
obj-m += battery.o
EOF
make -C "$BUILD_DIR" M="$ASUS_DIR/battery-build" modules

cp "$SOURCE_DIR/drivers/platform/x86/asus-wmi.c" "$ASUS_DIR/build/"
cp "$SOURCE_DIR/drivers/platform/x86/asus-wmi.h" "$ASUS_DIR/build/"
cp "$SOURCE_DIR/drivers/platform/x86/asus-nb-wmi.c" "$ASUS_DIR/build/"
cat > "$ASUS_DIR/build/Makefile" <<'EOF'
ccflags-y += -I$(src)
ccflags-y += -DCONFIG_ASUS_WMI_MODULE=1
obj-m += asus-wmi.o
obj-m += asus-nb-wmi.o
EOF
make -C "$BUILD_DIR" M="$ASUS_DIR/build" \
    KBUILD_EXTRA_SYMBOLS="$ASUS_DIR/battery-build/Module.symvers" \
    modules
cp -f "$ASUS_DIR/build/asus-wmi.ko" "$ASUS_DIR/asus-wmi.ko"
cp -f "$ASUS_DIR/build/asus-nb-wmi.ko" "$ASUS_DIR/asus-nb-wmi.ko"
check_vermagic "$ASUS_DIR/asus-wmi.ko" "$ASUS_DIR/asus-nb-wmi.ko"
echo "=== stage asus done ==="
fi

# --- huawei: Huawei MateBook WMI hotkeys, fn-lock, mic-mute LED ---
# Stock AZL has no HUAWEI_WMI. In-tree, no firmware blobs; same ACPI
# battery hook as thinkpad/dell/asus.
if run_stage huawei; then
echo "=== stage huawei ==="
HUAWEI_DIR="$WORKDIR/huawei"
rm -rf "$HUAWEI_DIR"
mkdir -p "$HUAWEI_DIR/battery-build" "$HUAWEI_DIR/build"
cp "$SOURCE_DIR/drivers/acpi/battery.c" "$HUAWEI_DIR/battery-build/"
cat > "$HUAWEI_DIR/battery-build/Makefile" <<'EOF'
obj-m += battery.o
EOF
make -C "$BUILD_DIR" M="$HUAWEI_DIR/battery-build" modules

cp "$SOURCE_DIR/drivers/platform/x86/huawei-wmi.c" "$HUAWEI_DIR/build/"
cat > "$HUAWEI_DIR/build/Makefile" <<'EOF'
ccflags-y += -DCONFIG_HUAWEI_WMI_MODULE=1
obj-m += huawei-wmi.o
EOF
make -C "$BUILD_DIR" M="$HUAWEI_DIR/build" \
    KBUILD_EXTRA_SYMBOLS="$HUAWEI_DIR/battery-build/Module.symvers" \
    modules
cp -f "$HUAWEI_DIR/build/huawei-wmi.ko" "$HUAWEI_DIR/huawei-wmi.ko"
check_vermagic "$HUAWEI_DIR/huawei-wmi.ko"
echo "=== stage huawei done ==="
fi

# --- system76: System76 laptop Fn keys, keyboard backlight, airplane LED ---
# Stock AZL has no SYSTEM76_ACPI. In-tree, no firmware blobs; same ACPI
# battery hook as thinkpad/dell/asus/huawei.
if run_stage system76; then
echo "=== stage system76 ==="
S76_DIR="$WORKDIR/system76"
rm -rf "$S76_DIR"
mkdir -p "$S76_DIR/battery-build" "$S76_DIR/build"
cp "$SOURCE_DIR/drivers/acpi/battery.c" "$S76_DIR/battery-build/"
cat > "$S76_DIR/battery-build/Makefile" <<'EOF'
obj-m += battery.o
EOF
make -C "$BUILD_DIR" M="$S76_DIR/battery-build" modules

cp "$SOURCE_DIR/drivers/platform/x86/system76_acpi.c" "$S76_DIR/build/"
cat > "$S76_DIR/build/Makefile" <<'EOF'
ccflags-y += -DCONFIG_SYSTEM76_ACPI_MODULE=1
obj-m += system76_acpi.o
EOF
make -C "$BUILD_DIR" M="$S76_DIR/build" \
    KBUILD_EXTRA_SYMBOLS="$S76_DIR/battery-build/Module.symvers" \
    modules
cp -f "$S76_DIR/build/system76_acpi.ko" "$S76_DIR/system76_acpi.ko"
check_vermagic "$S76_DIR/system76_acpi.ko"
echo "=== stage system76 done ==="
fi

# --- samsung: Samsung laptop function keys, wireless LED, backlight ---
# Stock AZL has no SAMSUNG_LAPTOP. In-tree, no firmware blobs; same ACPI
# battery hook as the other vendor platform families above.
if run_stage samsung; then
echo "=== stage samsung ==="
SAMSUNG_DIR="$WORKDIR/samsung"
rm -rf "$SAMSUNG_DIR"
mkdir -p "$SAMSUNG_DIR/battery-build" "$SAMSUNG_DIR/build"
cp "$SOURCE_DIR/drivers/acpi/battery.c" "$SAMSUNG_DIR/battery-build/"
cat > "$SAMSUNG_DIR/battery-build/Makefile" <<'EOF'
obj-m += battery.o
EOF
make -C "$BUILD_DIR" M="$SAMSUNG_DIR/battery-build" modules

cp "$SOURCE_DIR/drivers/platform/x86/samsung-laptop.c" "$SAMSUNG_DIR/build/"
cat > "$SAMSUNG_DIR/build/Makefile" <<'EOF'
ccflags-y += -DCONFIG_SAMSUNG_LAPTOP_MODULE=1
obj-m += samsung-laptop.o
EOF
make -C "$BUILD_DIR" M="$SAMSUNG_DIR/build" \
    KBUILD_EXTRA_SYMBOLS="$SAMSUNG_DIR/battery-build/Module.symvers" \
    modules
cp -f "$SAMSUNG_DIR/build/samsung-laptop.ko" "$SAMSUNG_DIR/samsung-laptop.ko"
check_vermagic "$SAMSUNG_DIR/samsung-laptop.ko"
echo "=== stage samsung done ==="
fi

# --- fujitsu: Fujitsu Lifebook extras (hotkeys, backlight) ---
# Stock AZL has no FUJITSU_LAPTOP. In-tree, no firmware blobs; same ACPI
# battery hook as the other vendor platform families above.
if run_stage fujitsu; then
echo "=== stage fujitsu ==="
FUJITSU_DIR="$WORKDIR/fujitsu"
rm -rf "$FUJITSU_DIR"
mkdir -p "$FUJITSU_DIR/battery-build" "$FUJITSU_DIR/build"
cp "$SOURCE_DIR/drivers/acpi/battery.c" "$FUJITSU_DIR/battery-build/"
cat > "$FUJITSU_DIR/battery-build/Makefile" <<'EOF'
obj-m += battery.o
EOF
make -C "$BUILD_DIR" M="$FUJITSU_DIR/battery-build" modules

cp "$SOURCE_DIR/drivers/platform/x86/fujitsu-laptop.c" "$FUJITSU_DIR/build/"
cat > "$FUJITSU_DIR/build/Makefile" <<'EOF'
ccflags-y += -DCONFIG_FUJITSU_LAPTOP_MODULE=1
obj-m += fujitsu-laptop.o
EOF
make -C "$BUILD_DIR" M="$FUJITSU_DIR/build" \
    KBUILD_EXTRA_SYMBOLS="$FUJITSU_DIR/battery-build/Module.symvers" \
    modules
cp -f "$FUJITSU_DIR/build/fujitsu-laptop.ko" "$FUJITSU_DIR/fujitsu-laptop.ko"
check_vermagic "$FUJITSU_DIR/fujitsu-laptop.ko"
echo "=== stage fujitsu done ==="
fi

# --- usbserial: common USB-to-serial converter chips ---
# Stock AZL has no USB_SERIAL at all. Covers FTDI, Silicon Labs CP210x,
# Prolific PL2303, and WCH CH340/CH341 - the four chips behind most
# consumer USB-serial cables/adapters (Arduino, GPS mice, some docks
# and KVM switch firmware/config ports). No firmware blobs.
if run_stage usbserial; then
echo "=== stage usbserial ==="
USBSERIAL_DIR="$WORKDIR/usbserial"
rm -rf "$USBSERIAL_DIR"
mkdir -p "$USBSERIAL_DIR"
for f in usb-serial.c bus.c generic.c ftdi_sio.c ftdi_sio.h ftdi_sio_ids.h \
    cp210x.c pl2303.c pl2303.h ch341.c
do
    cp "$SOURCE_DIR/drivers/usb/serial/$f" "$USBSERIAL_DIR/"
done
cat > "$USBSERIAL_DIR/Makefile" <<'EOF'
obj-m += usbserial.o
usbserial-y := usb-serial.o bus.o generic.o
obj-m += ftdi_sio.o
obj-m += cp210x.o
obj-m += pl2303.o
obj-m += ch341.o
EOF
make -C "$BUILD_DIR" M="$USBSERIAL_DIR" modules
USBSERIAL_MODULE="$USBSERIAL_DIR/usbserial.ko"
FTDI_SIO_MODULE="$USBSERIAL_DIR/ftdi_sio.ko"
CP210X_MODULE="$USBSERIAL_DIR/cp210x.ko"
PL2303_MODULE="$USBSERIAL_DIR/pl2303.ko"
CH341_MODULE="$USBSERIAL_DIR/ch341.ko"
check_vermagic "$USBSERIAL_MODULE" "$FTDI_SIO_MODULE" "$CP210X_MODULE" \
    "$PL2303_MODULE" "$CH341_MODULE"
echo "=== stage usbserial done ==="
fi

# --- udl: DisplayLink USB video adapters ---
# Stock AZL has no DRM_UDL. Covers USB-attached external displays, common
# on docking stations and multi-monitor USB/KVM-style hubs that lack
# native DisplayPort/HDMI passthrough. Depends only on stock DRM helpers
# (DRM_GEM_SHMEM_HELPER, DRM_KMS_HELPER, both already =y). No firmware.
if run_stage udl; then
echo "=== stage udl ==="
UDL_DIR="$WORKDIR/udl"
rm -rf "$UDL_DIR"
mkdir -p "$UDL_DIR"
cp -a "$SOURCE_DIR/drivers/gpu/drm/udl/." "$UDL_DIR/"
cat > "$UDL_DIR/Makefile" <<'EOF'
obj-m += udl.o
udl-y := udl_drv.o udl_edid.o udl_main.o udl_modeset.o udl_transfer.o
EOF
make -C "$BUILD_DIR" M="$UDL_DIR" modules
UDL_MODULE="$UDL_DIR/udl.ko"
check_vermagic "$UDL_MODULE"
echo "=== stage udl done ==="
fi

# --- typec + ucsi ---
# Thunderbolt/USB4 core is stock CONFIG_USB4=m (thunderbolt.ko). USB role
# switch is stock. Only TYPEC class + UCSI ACPI are missing on AZL x86_64.
if run_stage typec; then
echo "=== stage typec ==="
TYPEC_DIR="$WORKDIR/typec"
rm -rf "$TYPEC_DIR"
cp -a "$SOURCE_DIR/drivers/usb/typec" "$TYPEC_DIR"
# Include UCSI debugfs + trace objects when the running kernel has those
# features (AZL does). Upstream gates them on CONFIG_DEBUG_FS/TRACING.
cat > "$TYPEC_DIR/Makefile" <<'EOF'
ccflags-y += -DCONFIG_TYPEC_MODULE=1
ccflags-y += -DCONFIG_TYPEC_UCSI_MODULE=1
ccflags-y += -DCONFIG_UCSI_ACPI_MODULE=1
ccflags-y += -DCONFIG_TYPEC_DP_ALTMODE_MODULE=1
ccflags-y += -DCONFIG_DEBUG_FS=1
ccflags-y += -DCONFIG_TRACING=1
ccflags-y += -I$(src)
ccflags-y += -I$(src)/ucsi
CFLAGS_ucsi/trace.o := -I$(src)/ucsi
obj-m += typec.o
typec-y := class.o mux.o retimer.o bus.o port-mapper.o pd.o
obj-m += typec_ucsi.o
typec_ucsi-y := ucsi/ucsi.o ucsi/psy.o ucsi/displayport.o ucsi/debugfs.o ucsi/trace.o
obj-m += ucsi_acpi.o
ucsi_acpi-y := ucsi/ucsi_acpi.o
EOF
make -C "$BUILD_DIR" M="$TYPEC_DIR" \
    CONFIG_TYPEC=m CONFIG_TYPEC_UCSI=m CONFIG_UCSI_ACPI=m \
    CONFIG_TYPEC_DP_ALTMODE=m CONFIG_DEBUG_FS=y CONFIG_TRACING=y \
    modules
TYPEC_MODULE="$TYPEC_DIR/typec.ko"
TYPEC_UCSI_MODULE="$TYPEC_DIR/typec_ucsi.ko"
UCSI_ACPI_MODULE="$TYPEC_DIR/ucsi_acpi.ko"
check_vermagic "$TYPEC_MODULE" "$TYPEC_UCSI_MODULE" "$UCSI_ACPI_MODULE"
# Document stock companions for depmod consumers (no OOT rebuild).
cat > "$TYPEC_DIR/README.stock" <<'EOF'
Stock AZL modules used with this package (not rebuilt here):
  thunderbolt.ko  (CONFIG_USB4)
  roles.ko        (CONFIG_USB_ROLE_SWITCH)
  intel_xhci_usb_role_switch.ko (CONFIG_USB_ROLES_INTEL_XHCI)
EOF
echo "=== stage typec done ==="
fi

# --- sensors: activate stock hwmon/i2c (no OOT .ko — already =m/=y) ---
if run_stage sensors; then
echo "=== stage sensors ==="
SENS_DIR="$WORKDIR/sensors"
rm -rf "$SENS_DIR"
mkdir -p "$SENS_DIR"
# Stock AZL already provides i2c-i801, i2c-smbus, coretemp, lm75,
# x86_pkg_temp_thermal, intel_powerclamp, int340x_thermal. Ship load
# policy only so desktops get sensors without rebuilding duplicates.
cat > "$SENS_DIR/azurelinux-desktop-sensors.conf" <<'EOF'
# Load common laptop sensor stacks when present in stock kernel-modules.
# Missing modules are ignored by systemd-modules-load.
coretemp
i2c-i801
i2c-smbus
x86_pkg_temp_thermal
EOF
cat > "$SENS_DIR/README" <<'EOF'
azurelinux-desktop-sensors-kmod ships modules-load policy only.
Stock AZL already builds HWMON/I2C/THERMAL (coretemp, i2c-i801, lm75, …).
EOF
touch "$SENS_DIR/.conf-only"
echo "=== stage sensors done ==="
fi

# --- performance: stock modules + desktop sysctl (no OOT .ko) ---
# Conf-only. AZL stock is cloud-leaning (HZ=100, PREEMPT_VOLUNTARY,
# NO_HZ_FULL=y). Desktop responsiveness still needs userspace policy.
# Stock modules we lean on when present:
#   ZRAM=m, TCP_CONG_BBR=m, NET_SCH_FQ=m, IOSCHED_BFQ=m,
#   LRU_GEN=y + LRU_GEN_ENABLED=y, PSI=y, SCHED_CORE=y, THP=madvise.
# Cannot change PREEMPT/HZ/NO_HZ_FULL/THP without a kernel rebuild.
# Sysctl + modules-load here; Fedora packages on the image do the rest
# (zram-generator, tuned + tuned-ppd desktop profile, irqbalance).
# Do not ship removed CFS knobs (kernel.sched_*_ns) or dirty_ratio myths.
# Do not force BFQ as the default elevator on NVMe (none/mq-deadline is fine).
if run_stage performance; then
echo "=== stage performance ==="
PERF_DIR="$WORKDIR/performance"
rm -rf "$PERF_DIR"
mkdir -p "$PERF_DIR"
cat > "$PERF_DIR/azurelinux-desktop-performance.conf" <<'EOF'
# Stock modules when present. Missing names are ignored by modules-load.
zram
tcp_bbr
sch_fq
# BFQ only used when udev picks it for rotational disks (see assets/udev).
bfq
EOF
cat > "$PERF_DIR/99-azurelinux-desktop-performance.conf" <<'EOF'
# BBR wants fq (or fq_codel). Load sch_fq first via modules-load.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Same idea as Fedora tuned's desktop profile: group tasks by session so
# a busy build does not starve the shell that started it.
kernel.sched_autogroup_enabled = 1

# Prefer RAM over swap under light pressure. Matches common tuned
# performance profiles and this project's Fedora host (10). Not 0 (OOM
# surprises). Not the cloud default of 60. With zram present, cold pages
# still have a fast place to go when memory is actually tight.
vm.swappiness = 10
vm.vfs_cache_pressure = 75

# Leave vm.dirty_* alone. Aggressive dirty_ratio tweaks stall writeback
# on desktops. Leave transparent hugepages at kernel default (madvise on AZL).

# Mild TCP socket caps for desktop bulk transfers (browser, flatpak, git).
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Desktop niceties that do not need a kernel rebuild:
# - split_lock_mitigate=0 drops the multi-ms penalty on split locks (Wine,
#   some JVMs) while still allowing detection; see kernel buslock docs.
# - nmi_watchdog=0 frees a PMC and a little idle power on a personal box.
kernel.split_lock_mitigate = 0
kernel.nmi_watchdog = 0
EOF
# zram-generator unit config. Only applies when zram-generator is installed
# (Fedora package on the desktop image). Size matches Fedora Workstation
# defaults (min of RAM and 8G). Prefer zstd when the kernel has the backend.
cat > "$PERF_DIR/zram-generator.conf" <<'EOF'
# Azure Linux Desktop: compressed RAM swap when zram-generator is present.
# Size matches common Fedora Workstation practice (cap 8G). zstd when available.
[zram0]
zram-size = min(ram, 8192)
compression-algorithm = zstd
EOF
cat > "$PERF_DIR/README" <<'EOF'
azurelinux-desktop-performance-kmod is conf-only:
  modules-load: zram, tcp_bbr, sch_fq, bfq
  sysctl: fq + bbr, sched_autogroup, swappiness=10, vfs_cache_pressure=75,
          mild tcp mem, split_lock_mitigate=0, nmi_watchdog=0
  zram-generator.conf when that package is installed

Image packages / assets (not this RPM): zram-generator, tuned + tuned-ppd
with the desktop profile, irqbalance, thermald, journald size caps,
rotational-disk BFQ udev rule. SELinux stays enforcing.

Already on in AZL stock kernel (no conf needed): MGLRU (LRU_GEN_ENABLED),
PSI, SCHED_CORE. Not portable here: PREEMPT model, HZ, NO_HZ_FULL, THP
mode. Avoid: swappiness=0, dirty_ratio tweaks, forcing elevators on NVMe,
kernel.sched_*_ns (gone on modern kernels), dual ppd+tuned stacks,
SELINUX=permissive.
EOF
touch "$PERF_DIR/.conf-only"
echo "=== stage performance done ==="
fi

# --- surface: upstream SSAM + HID (no linux-surface OOT fork) ---
# Stock AZL leaves CONFIG_SURFACE_PLATFORMS / SERIAL_DEV_BUS / HID_MICROSOFT
# / HID_MULTITOUCH off. Build only in-tree Microsoft Surface support from
# the matching CBL-Mariner source tarball.
if run_stage surface; then
echo "=== stage surface ==="
SURF_DIR="$WORKDIR/surface"
rm -rf "$SURF_DIR"
mkdir -p "$SURF_DIR/serdev" "$SURF_DIR/aggregator" "$SURF_DIR/platform" "$SURF_DIR/hid"

# Stock kernel-devel omits Surface Kconfig headers when CONFIG_SURFACE_* is
# off. Stage them into the build tree so aggregator/platform/HID OOT builds
# can #include <linux/surface_aggregator/*.h>. Container-local only.
if [[ -d "$SOURCE_DIR/include/linux/surface_aggregator" ]]; then
    mkdir -p "$BUILD_DIR/include/linux" "$SURF_DIR/include/linux"
    cp -a "$SOURCE_DIR/include/linux/surface_aggregator" \
        "$BUILD_DIR/include/linux/"
    cp -a "$SOURCE_DIR/include/linux/surface_aggregator" \
        "$SURF_DIR/include/linux/"
fi

# serdev core (SSAM transport dependency)
cp "$SOURCE_DIR/drivers/tty/serdev/core.c" "$SURF_DIR/serdev/core.c"
cat > "$SURF_DIR/serdev/Makefile" <<'EOF'
ccflags-y += -DCONFIG_SERIAL_DEV_BUS_MODULE=1
ccflags-y += -DCONFIG_SERIAL_DEV_CTRL_TTYPORT=1
obj-m += serdev.o
serdev-y := core.o
EOF
make -C "$BUILD_DIR" M="$SURF_DIR/serdev" \
    CONFIG_SERIAL_DEV_BUS=m CONFIG_SERIAL_DEV_CTRL_TTYPORT=y \
    modules
cp -f "$SURF_DIR/serdev/serdev.ko" "$SURF_DIR/serdev.ko"

# SSAM aggregator core + bus
cp -a "$SOURCE_DIR/drivers/platform/surface/aggregator/." "$SURF_DIR/aggregator/"
cat > "$SURF_DIR/aggregator/Makefile" <<'EOF'
ccflags-y += -DCONFIG_SURFACE_AGGREGATOR_MODULE=1
ccflags-y += -DCONFIG_SURFACE_AGGREGATOR_BUS=1
ccflags-y += -DCONFIG_SERIAL_DEV_BUS_MODULE=1
CFLAGS_core.o = -I$(src)
obj-m += surface_aggregator.o
surface_aggregator-y := core.o ssh_parser.o ssh_packet_layer.o ssh_request_layer.o bus.o controller.o
EOF
make -C "$BUILD_DIR" M="$SURF_DIR/aggregator" \
    KBUILD_EXTRA_SYMBOLS="$SURF_DIR/serdev/Module.symvers" \
    CONFIG_SURFACE_AGGREGATOR=m CONFIG_SURFACE_AGGREGATOR_BUS=y \
    CONFIG_SERIAL_DEV_BUS=m \
    modules
cp -f "$SURF_DIR/aggregator/surface_aggregator.ko" "$SURF_DIR/surface_aggregator.ko"

# Client drivers living next to aggregator/ in drivers/platform/surface
for src in \
    surface_aggregator_cdev.c \
    surface_aggregator_hub.c \
    surface_aggregator_registry.c \
    surface_aggregator_tabletsw.c \
    surface_dtx.c \
    surface_gpe.c \
    surface_hotplug.c \
    surface_platform_profile.c \
    surface_acpi_notify.c \
    surfacepro3_button.c \
    surface3_power.c \
    surface3-wmi.c
do
    if [[ -f "$SOURCE_DIR/drivers/platform/surface/$src" ]]; then
        cp "$SOURCE_DIR/drivers/platform/surface/$src" "$SURF_DIR/platform/"
    fi
done
# Object base names (surface3-wmi.o keeps hyphen)
cat > "$SURF_DIR/platform/Makefile" <<'EOF'
ccflags-y += -DCONFIG_SURFACE_AGGREGATOR_MODULE=1
ccflags-y += -DCONFIG_SURFACE_AGGREGATOR_BUS=1
ccflags-y += -DCONFIG_SURFACE_AGGREGATOR_CDEV_MODULE=1
ccflags-y += -DCONFIG_SURFACE_AGGREGATOR_HUB_MODULE=1
ccflags-y += -DCONFIG_SURFACE_AGGREGATOR_REGISTRY_MODULE=1
ccflags-y += -DCONFIG_SURFACE_AGGREGATOR_TABLET_SWITCH_MODULE=1
ccflags-y += -DCONFIG_SURFACE_DTX_MODULE=1
ccflags-y += -DCONFIG_SURFACE_GPE_MODULE=1
ccflags-y += -DCONFIG_SURFACE_HOTPLUG_MODULE=1
ccflags-y += -DCONFIG_SURFACE_PLATFORM_PROFILE_MODULE=1
ccflags-y += -DCONFIG_SURFACE_ACPI_NOTIFY_MODULE=1
ccflags-y += -DCONFIG_SURFACE_PRO3_BUTTON_MODULE=1
ccflags-y += -DCONFIG_SURFACE_3_POWER_OPREGION_MODULE=1
ccflags-y += -DCONFIG_SURFACE3_WMI_MODULE=1
obj-m += surface_aggregator_cdev.o
obj-m += surface_aggregator_hub.o
obj-m += surface_aggregator_registry.o
obj-m += surface_aggregator_tabletsw.o
obj-m += surface_dtx.o
obj-m += surface_gpe.o
obj-m += surface_hotplug.o
obj-m += surface_platform_profile.o
obj-m += surface_acpi_notify.o
obj-m += surfacepro3_button.o
obj-m += surface3_power.o
obj-m += surface3-wmi.o
EOF
make -C "$BUILD_DIR" M="$SURF_DIR/platform" \
    KBUILD_EXTRA_SYMBOLS="$SURF_DIR/serdev/Module.symvers $SURF_DIR/aggregator/Module.symvers" \
    CONFIG_SURFACE_AGGREGATOR=m CONFIG_SURFACE_AGGREGATOR_BUS=y \
    CONFIG_SURFACE_AGGREGATOR_CDEV=m CONFIG_SURFACE_AGGREGATOR_HUB=m \
    CONFIG_SURFACE_AGGREGATOR_REGISTRY=m CONFIG_SURFACE_AGGREGATOR_TABLET_SWITCH=m \
    CONFIG_SURFACE_DTX=m CONFIG_SURFACE_GPE=m CONFIG_SURFACE_HOTPLUG=m \
    CONFIG_SURFACE_PLATFORM_PROFILE=m CONFIG_SURFACE_ACPI_NOTIFY=m \
    CONFIG_SURFACE_PRO3_BUTTON=m CONFIG_SURFACE_3_POWER_OPREGION=m \
    CONFIG_SURFACE3_WMI=m \
    modules
find "$SURF_DIR/platform" -name '*.ko' -exec cp -t "$SURF_DIR/" {} +

# Generic Microsoft + multitouch HID (covers Type Covers / digitisers).
# drivers/hid/*.c use local "hid-ids.h" / "hid-haptic.h" — those are NOT
# in kernel-devel; copy from the matching source tarball. BTF skip
# warnings ("unavailability of vmlinux") are harmless for OOT modules.
cp "$SOURCE_DIR/drivers/hid/hid-microsoft.c" "$SURF_DIR/hid/"
cp "$SOURCE_DIR/drivers/hid/hid-multitouch.c" "$SURF_DIR/hid/"
cp "$SOURCE_DIR/drivers/hid/hid-ids.h" "$SURF_DIR/hid/"
if [[ -f "$SOURCE_DIR/drivers/hid/hid-haptic.h" ]]; then
    cp "$SOURCE_DIR/drivers/hid/hid-haptic.h" "$SURF_DIR/hid/"
fi
if [[ -f "$SOURCE_DIR/drivers/hid/hid-haptic.c" ]]; then
    cp "$SOURCE_DIR/drivers/hid/hid-haptic.c" "$SURF_DIR/hid/"
fi
# Optional SSAM HID transport (7th-gen+ keyboards/touchpads)
if [[ -d "$SOURCE_DIR/drivers/hid/surface-hid" ]]; then
    cp -a "$SOURCE_DIR/drivers/hid/surface-hid/." "$SURF_DIR/hid/"
fi
# surface_hid needs <linux/surface_aggregator/*.h>; stock kernel-devel
# omits them when CONFIG_SURFACE_* is off. Stage from the source tree.
if [[ -d "$SOURCE_DIR/include/linux/surface_aggregator" ]]; then
    mkdir -p "$SURF_DIR/include/linux"
    cp -a "$SOURCE_DIR/include/linux/surface_aggregator" \
        "$SURF_DIR/include/linux/"
fi
cat > "$SURF_DIR/hid/Makefile" <<'EOF'
ccflags-y += -I$(src)
ccflags-y += -I$(src)/../include
ccflags-y += -DCONFIG_HID_MICROSOFT_MODULE=1
ccflags-y += -DCONFIG_HID_MULTITOUCH_MODULE=1
ccflags-y += -DCONFIG_SURFACE_HID_CORE_MODULE=1
ccflags-y += -DCONFIG_SURFACE_HID_MODULE=1
ccflags-y += -DCONFIG_SURFACE_KBD_MODULE=1
ccflags-y += -DCONFIG_SURFACE_AGGREGATOR_MODULE=1
ccflags-y += -DCONFIG_SURFACE_AGGREGATOR_BUS=1
obj-m += hid-microsoft.o
obj-m += hid-multitouch.o
obj-m += surface_hid_core.o
obj-m += surface_hid.o
obj-m += surface_kbd.o
EOF
# surface_hid*.c may be missing on older trees; only build present objs
if [[ ! -f "$SURF_DIR/hid/surface_hid_core.c" ]]; then
    sed -i '/surface_hid/d;/surface_kbd/d' "$SURF_DIR/hid/Makefile"
fi
# Multitouch may pull hid-haptic helpers when present as a separate unit.
if [[ -f "$SURF_DIR/hid/hid-haptic.c" ]] && grep -q 'hid-haptic' "$SURF_DIR/hid/hid-multitouch.c" 2>/dev/null; then
    # Usually header-only; keep .c available if the tree ships one.
    :
fi
make -C "$BUILD_DIR" M="$SURF_DIR/hid" \
    KBUILD_EXTRA_SYMBOLS="$SURF_DIR/serdev/Module.symvers $SURF_DIR/aggregator/Module.symvers $SURF_DIR/platform/Module.symvers" \
    CONFIG_HID_MICROSOFT=m CONFIG_HID_MULTITOUCH=m \
    CONFIG_SURFACE_HID_CORE=m CONFIG_SURFACE_HID=m CONFIG_SURFACE_KBD=m \
    CONFIG_SURFACE_AGGREGATOR=m CONFIG_SURFACE_AGGREGATOR_BUS=y \
    modules
find "$SURF_DIR/hid" -name '*.ko' -exec cp -t "$SURF_DIR/" {} +

# Required core set
for need in serdev.ko surface_aggregator.ko hid-microsoft.ko hid-multitouch.ko \
    surface_aggregator_registry.ko surface_aggregator_hub.ko; do
    test -f "$SURF_DIR/$need"
done
mapfile -t SURFACE_MODULES < <(find "$SURF_DIR" -maxdepth 1 -name '*.ko' | sort)
test "${#SURFACE_MODULES[@]}" -ge 6
check_vermagic "${SURFACE_MODULES[@]}"
echo "=== stage surface done (${#SURFACE_MODULES[@]} modules) ==="
fi

# --- package RPMs ---
# Adaptive: package whichever family modules are present in WORKDIR.
# Missing families are skipped so partial CI matrix success still publishes.
if ! run_stage package; then
    exit 0
fi
echo "=== stage package ==="

have_ko() {
    local p="$1"
    [[ -f "$p" ]]
}

# Resolve optional module paths.
HID_MODULE="$WORKDIR/usbhid/usbhid.ko"
PS2_MODULE="$WORKDIR/psmouse/psmouse.ko"
STOR_MODULE="$WORKDIR/storage/usb-storage.ko"
UAS_MODULE="$WORKDIR/storage/uas.ko"
if [[ ! -f "$STOR_MODULE" && -f "$WORKDIR/usb-storage/usb-storage.ko" ]]; then
    STOR_MODULE="$WORKDIR/usb-storage/usb-storage.ko"
    UAS_MODULE="$WORKDIR/usb-storage/uas.ko"
fi
IWL_MODULE="$WORKDIR/intel/iwlwifi.ko"
IWL_MVM="$WORKDIR/intel/iwlmvm.ko"
IWL_DVM="$WORKDIR/intel/iwldvm.ko"
IWL_MLD="$WORKDIR/intel/iwlmld.ko"
# Compat paths if only legacy iwlwifi/ tree was merged from CI artifact
if [[ ! -f "$IWL_MODULE" && -f "$WORKDIR/iwlwifi/iwlwifi.ko" ]]; then
    IWL_MODULE="$WORKDIR/iwlwifi/iwlwifi.ko"
    IWL_MVM="$WORKDIR/iwlwifi/mvm/iwlmvm.ko"
    IWL_DVM="$WORKDIR/iwlwifi/dvm/iwldvm.ko"
    IWL_MLD="$WORKDIR/iwlwifi/mld/iwlmld.ko"
fi
UVC_COMMON_MODULE="$WORKDIR/uvc/uvc.ko"
UVC_MODULE="$WORKDIR/uvc/uvcvideo.ko"
ACPI_BATTERY_MODULE="$WORKDIR/acpibattery/battery.ko"
TP_PRIVACY_MODULE="$WORKDIR/thinkpad/drm_privacy_screen.ko"
TP_MODULE="$WORKDIR/thinkpad/thinkpad_acpi.ko"
TYPEC_MODULE="$WORKDIR/typec/typec.ko"
TYPEC_UCSI_MODULE="$WORKDIR/typec/typec_ucsi.ko"
UCSI_ACPI_MODULE="$WORKDIR/typec/ucsi_acpi.ko"
HIDMT_MODULE="$WORKDIR/hidmt/hid-multitouch.ko"
TOUCHPAD_RMI_CORE="$WORKDIR/touchpad/rmi_core.ko"
TOUCHPAD_RMI_I2C="$WORKDIR/touchpad/rmi_i2c.ko"
TOUCHPAD_ELAN="$WORKDIR/touchpad/elan_i2c.ko"
LOGI_DJ_MODULE="$WORKDIR/logitech/hid-logitech-dj.ko"
LOGI_HIDPP_MODULE="$WORKDIR/logitech/hid-logitech-hidpp.ko"
HIDQ_ASUS_MODULE="$WORKDIR/hidquirks/hid-asus.ko"
HIDQ_ELAN_MODULE="$WORKDIR/hidquirks/hid-elan.ko"
WACOM_MODULE="$WORKDIR/tablet/wacom.ko"
UCLOGIC_MODULE="$WORKDIR/tablet/hid-uclogic.ko"
WALTOP_MODULE="$WORKDIR/tablet/hid-waltop.ko"
R8152_MODULE="$WORKDIR/usbeth/r8152.ko"
ASIX_MODULE="$WORKDIR/usbeth/asix.ko"
AX88179_MODULE="$WORKDIR/usbeth/ax88179_178a.ko"
XPAD_MODULE="$WORKDIR/gamepad/xpad.ko"
HID_SONY_MODULE="$WORKDIR/gamepad/hid-sony.ko"
LED_MULTICOLOR_MODULE="$WORKDIR/gamepad/led-class-multicolor.ko"
HID_PLAYSTATION_MODULE="$WORKDIR/gamepad/hid-playstation.ko"
DELL_LAPTOP_MODULE="$WORKDIR/dell/dell-laptop.ko"
ASUS_WMI_MODULE="$WORKDIR/asus/asus-wmi.ko"
ASUS_NB_WMI_MODULE="$WORKDIR/asus/asus-nb-wmi.ko"
HUAWEI_WMI_MODULE="$WORKDIR/huawei/huawei-wmi.ko"
SYSTEM76_ACPI_MODULE="$WORKDIR/system76/system76_acpi.ko"
SAMSUNG_LAPTOP_MODULE="$WORKDIR/samsung/samsung-laptop.ko"
FUJITSU_LAPTOP_MODULE="$WORKDIR/fujitsu/fujitsu-laptop.ko"
USBSERIAL_MODULE="$WORKDIR/usbserial/usbserial.ko"
FTDI_SIO_MODULE="$WORKDIR/usbserial/ftdi_sio.ko"
CP210X_MODULE="$WORKDIR/usbserial/cp210x.ko"
PL2303_MODULE="$WORKDIR/usbserial/pl2303.ko"
CH341_MODULE="$WORKDIR/usbserial/ch341.ko"
UDL_MODULE="$WORKDIR/udl/udl.ko"

mapfile -t SOUND_MODULES < <(find "$WORKDIR/sound" -name '*.ko' 2>/dev/null | sort || true)
mapfile -t BT_MODULES < <(
    {
        find "$WORKDIR/btnet" -name '*.ko' 2>/dev/null || true
        find "$WORKDIR/btdrv" -name '*.ko' 2>/dev/null || true
    } | sort
)
mapfile -t SURFACE_MODULES < <(find "$WORKDIR/surface" -maxdepth 1 -name '*.ko' 2>/dev/null | sort || true)

PRESENT_PKGS=()
PRESENT_KOS=()

add_pkg() {
    local name="$1"
    PRESENT_PKGS+=("$name")
}

if have_ko "$HID_MODULE"; then
    PRESENT_KOS+=("$HID_MODULE")
    add_pkg usbhid
fi
if have_ko "$PS2_MODULE"; then
    PRESENT_KOS+=("$PS2_MODULE")
    # Optional RMI4 companions (same psmouse family dir).
    RMI_CORE_MODULE="$WORKDIR/psmouse/rmi_core.ko"
    RMI_SMBUS_MODULE="$WORKDIR/psmouse/rmi_smbus.ko"
    have_ko "$RMI_CORE_MODULE" && PRESENT_KOS+=("$RMI_CORE_MODULE")
    have_ko "$RMI_SMBUS_MODULE" && PRESENT_KOS+=("$RMI_SMBUS_MODULE")
    # Optional AMD/legacy SMBus adapter (only useful alongside RMI4).
    I2C_SMBUS_MODULE="$WORKDIR/psmouse/i2c-smbus.ko"
    I2C_PIIX4_MODULE="$WORKDIR/psmouse/i2c-piix4.ko"
    have_ko "$I2C_SMBUS_MODULE" && PRESENT_KOS+=("$I2C_SMBUS_MODULE")
    have_ko "$I2C_PIIX4_MODULE" && PRESENT_KOS+=("$I2C_PIIX4_MODULE")
    add_pkg psmouse
fi
if have_ko "$STOR_MODULE" && have_ko "$UAS_MODULE"; then
    PRESENT_KOS+=("$STOR_MODULE" "$UAS_MODULE")
    add_pkg storage
fi
if have_ko "$IWL_MODULE" && have_ko "$IWL_MVM" && have_ko "$IWL_DVM" && have_ko "$IWL_MLD"; then
    PRESENT_KOS+=("$IWL_MODULE" "$IWL_MVM" "$IWL_DVM" "$IWL_MLD")
    add_pkg intel
fi
if ((${#SOUND_MODULES[@]} >= 12)); then
    PRESENT_KOS+=("${SOUND_MODULES[@]}")
    add_pkg sound
fi
if ((${#BT_MODULES[@]} >= 6)); then
    PRESENT_KOS+=("${BT_MODULES[@]}")
    add_pkg bluetooth
fi
if have_ko "$UVC_COMMON_MODULE" && have_ko "$UVC_MODULE"; then
    PRESENT_KOS+=("$UVC_COMMON_MODULE" "$UVC_MODULE")
    add_pkg uvc
elif have_ko "$UVC_MODULE"; then
    # Older layout without separate common helper.
    PRESENT_KOS+=("$UVC_MODULE")
    add_pkg uvc
fi
mapfile -t TP_EXTRA_MODULES < <(find "$WORKDIR/thinkpad" -maxdepth 1 -name '*.ko' 2>/dev/null | sort || true)
if have_ko "$TP_MODULE" && have_ko "$TP_PRIVACY_MODULE"; then
    PRESENT_KOS+=("${TP_EXTRA_MODULES[@]}")
    add_pkg thinkpad
elif have_ko "$TP_MODULE"; then
    PRESENT_KOS+=("$TP_MODULE")
    add_pkg thinkpad
fi
if have_ko "$ACPI_BATTERY_MODULE"; then
    PRESENT_KOS+=("$ACPI_BATTERY_MODULE")
    add_pkg acpibattery
fi
if have_ko "$DELL_LAPTOP_MODULE"; then
    PRESENT_KOS+=("$DELL_LAPTOP_MODULE")
    add_pkg dell
fi
if have_ko "$ASUS_WMI_MODULE" && have_ko "$ASUS_NB_WMI_MODULE"; then
    PRESENT_KOS+=("$ASUS_WMI_MODULE" "$ASUS_NB_WMI_MODULE")
    add_pkg asus
fi
if have_ko "$HUAWEI_WMI_MODULE"; then
    PRESENT_KOS+=("$HUAWEI_WMI_MODULE")
    add_pkg huawei
fi
if have_ko "$SYSTEM76_ACPI_MODULE"; then
    PRESENT_KOS+=("$SYSTEM76_ACPI_MODULE")
    add_pkg system76
fi
if have_ko "$SAMSUNG_LAPTOP_MODULE"; then
    PRESENT_KOS+=("$SAMSUNG_LAPTOP_MODULE")
    add_pkg samsung
fi
if have_ko "$FUJITSU_LAPTOP_MODULE"; then
    PRESENT_KOS+=("$FUJITSU_LAPTOP_MODULE")
    add_pkg fujitsu
fi
if have_ko "$USBSERIAL_MODULE" && have_ko "$FTDI_SIO_MODULE" \
    && have_ko "$CP210X_MODULE" && have_ko "$PL2303_MODULE" && have_ko "$CH341_MODULE"; then
    PRESENT_KOS+=("$USBSERIAL_MODULE" "$FTDI_SIO_MODULE" "$CP210X_MODULE" \
        "$PL2303_MODULE" "$CH341_MODULE")
    add_pkg usbserial
fi
if have_ko "$UDL_MODULE"; then
    PRESENT_KOS+=("$UDL_MODULE")
    add_pkg udl
fi
if have_ko "$TYPEC_MODULE" && have_ko "$TYPEC_UCSI_MODULE" && have_ko "$UCSI_ACPI_MODULE"; then
    PRESENT_KOS+=("$TYPEC_MODULE" "$TYPEC_UCSI_MODULE" "$UCSI_ACPI_MODULE")
    add_pkg typec
fi
if have_ko "$HIDMT_MODULE"; then
    PRESENT_KOS+=("$HIDMT_MODULE")
    add_pkg hidmt
fi
TOUCHPAD_KOS=()
have_ko "$TOUCHPAD_RMI_CORE" && have_ko "$TOUCHPAD_RMI_I2C" && TOUCHPAD_KOS+=("$TOUCHPAD_RMI_CORE" "$TOUCHPAD_RMI_I2C")
have_ko "$TOUCHPAD_ELAN" && TOUCHPAD_KOS+=("$TOUCHPAD_ELAN")
if ((${#TOUCHPAD_KOS[@]} > 0)); then
    PRESENT_KOS+=("${TOUCHPAD_KOS[@]}")
    add_pkg touchpad
fi
if have_ko "$LOGI_DJ_MODULE" && have_ko "$LOGI_HIDPP_MODULE"; then
    PRESENT_KOS+=("$LOGI_DJ_MODULE" "$LOGI_HIDPP_MODULE")
    add_pkg logitech
fi
if have_ko "$HIDQ_ASUS_MODULE" && have_ko "$HIDQ_ELAN_MODULE"; then
    PRESENT_KOS+=("$HIDQ_ASUS_MODULE" "$HIDQ_ELAN_MODULE")
    add_pkg hidquirks
fi
if have_ko "$WACOM_MODULE" && have_ko "$UCLOGIC_MODULE" && have_ko "$WALTOP_MODULE"; then
    PRESENT_KOS+=("$WACOM_MODULE" "$UCLOGIC_MODULE" "$WALTOP_MODULE")
    add_pkg tablet
fi
USBETH_KOS=()
have_ko "$R8152_MODULE" && USBETH_KOS+=("$R8152_MODULE")
have_ko "$ASIX_MODULE" && USBETH_KOS+=("$ASIX_MODULE")
have_ko "$AX88179_MODULE" && USBETH_KOS+=("$AX88179_MODULE")
if ((${#USBETH_KOS[@]} > 0)); then
    PRESENT_KOS+=("${USBETH_KOS[@]}")
    add_pkg usbeth
fi
if have_ko "$XPAD_MODULE" && have_ko "$HID_SONY_MODULE" \
    && have_ko "$LED_MULTICOLOR_MODULE" && have_ko "$HID_PLAYSTATION_MODULE"; then
    PRESENT_KOS+=("$XPAD_MODULE" "$HID_SONY_MODULE" \
        "$LED_MULTICOLOR_MODULE" "$HID_PLAYSTATION_MODULE")
    add_pkg gamepad
fi
if ((${#SURFACE_MODULES[@]} >= 6)) \
    && have_ko "$WORKDIR/surface/serdev.ko" \
    && have_ko "$WORKDIR/surface/surface_aggregator.ko" \
    && have_ko "$WORKDIR/surface/hid-microsoft.ko" \
    && have_ko "$WORKDIR/surface/hid-multitouch.ko"; then
    PRESENT_KOS+=("${SURFACE_MODULES[@]}")
    add_pkg surface
fi
# Prefer conf payloads over .conf-only markers. actions/upload-artifact
# drops hidden files unless include-hidden-files is set, so the marker
# often never reaches the package job.
if [[ -f "$WORKDIR/sensors/azurelinux-desktop-sensors.conf" \
    || -f "$WORKDIR/sensors/.conf-only" ]]; then
    add_pkg sensors
fi
if [[ -f "$WORKDIR/performance/azurelinux-desktop-performance.conf" \
    || -f "$WORKDIR/performance/.conf-only" ]]; then
    add_pkg performance
fi

if ((${#PRESENT_PKGS[@]} == 0)); then
    echo "package: no family modules present in $WORKDIR" >&2
    exit 1
fi

echo "package: present families: ${PRESENT_PKGS[*]}"
if ((${#PRESENT_KOS[@]} > 0)); then
    check_vermagic "${PRESENT_KOS[@]}"
fi

RPMBUILD="$WORKDIR/rpmbuild"
rm -rf "$RPMBUILD"
mkdir -p "$RPMBUILD"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
EXTRA_INSTALL_DIR="extra/azurelinux-desktop"

install_ko_source() {
    local src="$1"
    cp "$src" "$RPMBUILD/SOURCES/$(basename "$src")"
}

for m in "${PRESENT_KOS[@]}"; do
    install_ko_source "$m"
done

pkg_enabled() {
    local want="$1" p
    for p in "${PRESENT_PKGS[@]}"; do
        [[ "$p" == "$want" ]] && return 0
    done
    return 1
}

# Conf-only family assets into rpm SOURCES
if pkg_enabled sensors && [[ -f "$WORKDIR/sensors/azurelinux-desktop-sensors.conf" ]]; then
    cp -f "$WORKDIR/sensors/azurelinux-desktop-sensors.conf" "$RPMBUILD/SOURCES/"
fi
if pkg_enabled performance; then
    [[ -f "$WORKDIR/performance/azurelinux-desktop-performance.conf" ]] && \
        cp -f "$WORKDIR/performance/azurelinux-desktop-performance.conf" "$RPMBUILD/SOURCES/"
    [[ -f "$WORKDIR/performance/99-azurelinux-desktop-performance.conf" ]] && \
        cp -f "$WORKDIR/performance/99-azurelinux-desktop-performance.conf" "$RPMBUILD/SOURCES/"
    [[ -f "$WORKDIR/performance/zram-generator.conf" ]] && \
        cp -f "$WORKDIR/performance/zram-generator.conf" "$RPMBUILD/SOURCES/"
fi

# Dynamic subpackage fragments.
REQUIRES_SIBLINGS=""
PACKAGE_SECTIONS=""
INSTALL_SECTION=""
FILES_SECTIONS=""
POST_SECTIONS=""

append_requires() {
    local rpmname="$1"
    REQUIRES_SIBLINGS+="Requires:       ${rpmname} = %{version}-%{release}"$'\n'
}

# helpers for multi-ko packages
ko_install_line() {
    local bn="$1"
    echo "install -Dpm 0644 %{_sourcedir}/${bn} %{buildroot}%{_usr}/lib/modules/${KVERREL}/${EXTRA_INSTALL_DIR}/${bn}"
}
ko_files_line() {
    local bn="$1"
    echo "%{_usr}/lib/modules/${KVERREL}/${EXTRA_INSTALL_DIR}/${bn}"
}

if pkg_enabled usbhid; then
    append_requires azurelinux-desktop-usbhid-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-usbhid-kmod
Summary:        USB HID transport module for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-usbhid-kmod
The usbhid module built for Azure Linux kernel ${KVERREL}.
"
    INSTALL_SECTION+="$(ko_install_line usbhid.ko)"$'\n'
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-usbhid.conf <<'DRACUT'
add_drivers+=\" usbhid \"
DRACUT"$'\n'
    # Also modules-load: USB tablet (Boxes/VBox/QEMU) needs usbhid before
    # hid-generic can bind. Alias autoload is racy on some SPICE USB paths.
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-usbhid.conf <<'ML'
usbhid
ML"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-usbhid-kmod
$(ko_files_line usbhid.ko)
%config(noreplace) %{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-usbhid.conf
%config(noreplace) %{_sysconfdir}/modules-load.d/azurelinux-desktop-usbhid.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-usbhid-kmod
/usr/sbin/depmod -a ${KVERREL} || :
if [ -x /usr/bin/dracut ] && [ -e /boot/initramfs-${KVERREL}.img ]; then
  /usr/bin/dracut --force --kver ${KVERREL} || :
fi
%postun -n azurelinux-desktop-usbhid-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled psmouse; then
    append_requires azurelinux-desktop-psmouse-kmod
    PSMOUSE_HAS_RMI=0
    have_ko "$WORKDIR/psmouse/rmi_core.ko" && have_ko "$WORKDIR/psmouse/rmi_smbus.ko" && PSMOUSE_HAS_RMI=1
    PSMOUSE_HAS_PIIX4=0
    have_ko "$WORKDIR/psmouse/i2c-smbus.ko" && have_ko "$WORKDIR/psmouse/i2c-piix4.ko" && PSMOUSE_HAS_PIIX4=1
    if [[ "$PSMOUSE_HAS_RMI" -eq 1 ]]; then
        PSMOUSE_SUMMARY="PS/2 mouse + Synaptics RMI4 SMBus for Azure Linux ${KVERREL}"
        PSMOUSE_DESC="psmouse for Azure Linux kernel ${KVERREL}. Covers GNOME Boxes and other
hypervisors that default to a PS/2 mouse for unknown Linux guests.
On bare-metal ThinkPads with Synaptics InterTouch, also ships rmi_core
and rmi_smbus so the pad can leave relative PS/2 mode (two-finger
scroll, proper clickpad). See findings/thinkpad-two-finger-scroll-rmi-smbus.md."
        if [[ "$PSMOUSE_HAS_PIIX4" -eq 1 ]]; then
            PSMOUSE_DESC="${PSMOUSE_DESC}
Also ships i2c-piix4 (plus its i2c-smbus dependency), the SMBus host
controller AMD chipsets need for that same RMI4 SMBus handoff. Stock
AZL already builds i2c-i801 in-tree for Intel; i2c-piix4 is its AMD
(and legacy Intel PIIX4) counterpart, so this pad fix now works on
AMD laptops too."
        fi
    else
        PSMOUSE_SUMMARY="PS/2 mouse module for Azure Linux ${KVERREL}"
        PSMOUSE_DESC="psmouse for Azure Linux kernel ${KVERREL}. Covers GNOME Boxes and other
hypervisors that default to a PS/2 mouse for unknown Linux guests.
This build has no drivers/input/rmi4 sources, so RMI4 SMBus modules are not included."
    fi
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-psmouse-kmod
Summary:        ${PSMOUSE_SUMMARY}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-psmouse-kmod
${PSMOUSE_DESC}
"
    INSTALL_SECTION+="$(ko_install_line psmouse.ko)"$'\n'
    if [[ "$PSMOUSE_HAS_RMI" -eq 1 ]]; then
        INSTALL_SECTION+="$(ko_install_line rmi_core.ko)"$'\n'
        INSTALL_SECTION+="$(ko_install_line rmi_smbus.ko)"$'\n'
    fi
    if [[ "$PSMOUSE_HAS_PIIX4" -eq 1 ]]; then
        INSTALL_SECTION+="$(ko_install_line i2c-smbus.ko)"$'\n'
        INSTALL_SECTION+="$(ko_install_line i2c-piix4.ko)"$'\n'
    fi
    # Initramfs: psmouse is enough for early PS/2; RMI loads from rootfs.
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-psmouse.conf <<'DRACUT'
add_drivers+=\" psmouse \"
DRACUT"$'\n'
    # Load the SMBus adapter, then RMI, then psmouse, so the handoff can
    # bind immediately: i2c-piix4 must register the bus before rmi_smbus
    # can claim the rmi4_smbus device psmouse creates.
    if [[ "$PSMOUSE_HAS_RMI" -eq 1 ]]; then
        PSMOUSE_ML_MODULES="rmi_core"$'\n'"rmi_smbus"$'\n'"psmouse"
        if [[ "$PSMOUSE_HAS_PIIX4" -eq 1 ]]; then
            PSMOUSE_ML_MODULES="i2c-piix4"$'\n'"$PSMOUSE_ML_MODULES"
        fi
        INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-psmouse.conf <<ML
${PSMOUSE_ML_MODULES}
ML"$'\n'
        INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modprobe.d/azurelinux-desktop-psmouse.conf <<'MP'
# Prefer SMBus+RMI when the pad advertises InterTouch. Safe on VMs:
# non-Synaptics PS/2 mice never hit this path. softdep keeps order if
# something else pulls psmouse first.
options psmouse synaptics_intertouch=1
softdep psmouse pre: rmi_core rmi_smbus
MP"$'\n'
    else
        INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-psmouse.conf <<'ML'
psmouse
ML"$'\n'
    fi
    FILES_SECTIONS+="
%files -n azurelinux-desktop-psmouse-kmod
$(ko_files_line psmouse.ko)
"
    if [[ "$PSMOUSE_HAS_RMI" -eq 1 ]]; then
        FILES_SECTIONS+="$(ko_files_line rmi_core.ko)"$'\n'
        FILES_SECTIONS+="$(ko_files_line rmi_smbus.ko)"$'\n'
        FILES_SECTIONS+="%config(noreplace) %{_sysconfdir}/modprobe.d/azurelinux-desktop-psmouse.conf"$'\n'
    fi
    if [[ "$PSMOUSE_HAS_PIIX4" -eq 1 ]]; then
        FILES_SECTIONS+="$(ko_files_line i2c-smbus.ko)"$'\n'
        FILES_SECTIONS+="$(ko_files_line i2c-piix4.ko)"$'\n'
    fi
    FILES_SECTIONS+="%config(noreplace) %{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-psmouse.conf
%config(noreplace) %{_sysconfdir}/modules-load.d/azurelinux-desktop-psmouse.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-psmouse-kmod
/usr/sbin/depmod -a ${KVERREL} || :
if [ -x /usr/bin/dracut ] && [ -e /boot/initramfs-${KVERREL}.img ]; then
  /usr/bin/dracut --force --kver ${KVERREL} || :
fi
%postun -n azurelinux-desktop-psmouse-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled storage; then
    append_requires azurelinux-desktop-storage-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-storage-kmod
Summary:        Desktop storage modules (USB MSD/UAS) for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
Provides:       azurelinux-desktop-usb-storage-kmod = %{version}-%{release}
Obsoletes:      azurelinux-desktop-usb-storage-kmod < %{version}-%{release}
%description -n azurelinux-desktop-storage-kmod
usb-storage and uas for Azure Linux ${KVERREL} (CONFIG_USB_STORAGE off
in the stock cloud kernel). NVMe/ext4/device-mapper core are built-in;
xfs, btrfs, dm-crypt, and dm-integrity ship as stock kernel modules —
not rebuilt here to avoid conflicts.
"
    INSTALL_SECTION+="$(ko_install_line usb-storage.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line uas.ko)"$'\n'
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-storage.conf <<'DRACUT'
add_drivers+=\" usb-storage uas \"
DRACUT"$'\n'
    # Keep legacy dracut drop-in name as a symlink-compatible second file
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-usb-storage.conf <<'DRACUT'
add_drivers+=\" usb-storage uas \"
DRACUT"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-storage-kmod
$(ko_files_line usb-storage.ko)
$(ko_files_line uas.ko)
%config(noreplace) %{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-storage.conf
%config(noreplace) %{_sysconfdir}/dracut.conf.d/90-azurelinux-desktop-usb-storage.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-storage-kmod
/usr/sbin/depmod -a ${KVERREL} || :
if [ -x /usr/bin/dracut ] && [ -e /boot/initramfs-${KVERREL}.img ]; then
  /usr/bin/dracut --force --kver ${KVERREL} || :
fi
%postun -n azurelinux-desktop-storage-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled intel; then
    append_requires azurelinux-desktop-intel-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-intel-kmod
Summary:        Intel Wi-Fi (iwlwifi) modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
# Smooth upgrades from the former package name.
Provides:       azurelinux-desktop-iwlwifi-kmod = %{version}-%{release}
Obsoletes:      azurelinux-desktop-iwlwifi-kmod < %{version}-%{release}
%description -n azurelinux-desktop-intel-kmod
Intel wireless (iwlwifi + mvm/dvm/mld opmodes) for Azure Linux ${KVERREL}.
Already stock (not rebuilt): i915/xe DRM, e1000e, MEI, intel_pstate,
intel_idle, RAPL, PMC core, TCC cooling, uncore freq, aesni-intel,
powerclamp, msr/cpuid. Sibling packages: sound-kmod (HDA/HDMI/Realtek),
bluetooth-kmod (btintel). SOF ASoC deferred (large graph; HDA covers
Skylake-class and many Surfaces).
"
    for bn in iwlwifi.ko iwlmvm.ko iwldvm.ko iwlmld.ko; do
        INSTALL_SECTION+="$(ko_install_line "$bn")"$'\n'
    done
    FILES_SECTIONS+="
%files -n azurelinux-desktop-intel-kmod
$(ko_files_line iwlwifi.ko)
$(ko_files_line iwlmvm.ko)
$(ko_files_line iwldvm.ko)
$(ko_files_line iwlmld.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-intel-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-intel-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled sound; then
    append_requires azurelinux-desktop-sound-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-sound-kmod
Summary:        ALSA HDA and USB audio modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-sound-kmod
ALSA core, Intel HDA, common codecs, and USB audio for ${KVERREL}.
Pair with intel-audio-firmware and alsa-ucm.
"
    SOUND_FILES=""
    for m in "${SOUND_MODULES[@]}"; do
        bn="$(basename "$m")"
        INSTALL_SECTION+="$(ko_install_line "$bn")"$'\n'
        SOUND_FILES+="$(ko_files_line "$bn")"$'\n'
    done
    # Do not force-load snd-hda-intel at boot. On VMs without a working
# codec it returns Invalid argument and fails systemd-modules-load.
# Fedora's dist-alsa install rule also pulls snd-seq, which the AZL
# kernel does not ship. udev binds HDA when hardware is present.
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-sound.conf <<'ML'
# snd-hda-intel is loaded by udev when HDA audio hardware appears.
ML"$'\n'
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modprobe.d/azurelinux-desktop-alsa.conf <<'ML'
# Override Fedora dist-alsa.conf: AZL kernel has no snd-seq module.
# Keep snd-pcm loadable without failing the install hook.
install snd-pcm /sbin/modprobe --ignore-install snd-pcm \$CMDLINE_OPTS
ML"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-sound-kmod
${SOUND_FILES}%config(noreplace) %{_sysconfdir}/modules-load.d/azurelinux-desktop-sound.conf
%config(noreplace) %{_sysconfdir}/modprobe.d/azurelinux-desktop-alsa.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-sound-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-sound-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled bluetooth; then
    append_requires azurelinux-desktop-bluetooth-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-bluetooth-kmod
Summary:        Bluetooth core and USB modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-bluetooth-kmod
Bluetooth core and USB controllers for ${KVERREL}. Pair with BlueZ
and Intel BT firmware (ibt-*).
"
    BT_FILES=""
    for m in "${BT_MODULES[@]}"; do
        bn="$(basename "$m")"
        INSTALL_SECTION+="$(ko_install_line "$bn")"$'\n'
        BT_FILES+="$(ko_files_line "$bn")"$'\n'
    done
    # Do not force-load btusb at boot. On ThinkPads, early btusb races
    # thinkpad_acpi rfkill and HCI reset times out (no firmware load).
    # udev loads btusb from USB aliases when the controller appears.
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-bluetooth.conf <<'ML'
# btusb is loaded by udev when a Bluetooth controller appears.
ML"$'\n'
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modprobe.d/azurelinux-desktop-bluetooth.conf <<'ML'
# Prefer platform rfkill (thinkpad_acpi) before binding btusb when present.
softdep btusb pre: thinkpad_acpi
options btusb reset=1
options btusb enable_autosuspend=0
ML"$'\n'
    # USB authorize-cycle recover: BT device often enumerates before
    # thinkpad_acpi unblocks platform rfkill (HCI 0x0c03 timeout).
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    BT_RESET_SRC="$REPO_ROOT/assets/bluetooth/azurelinux-desktop-bt-usb-reset"
    BT_SVC_SRC="$REPO_ROOT/assets/systemd/azurelinux-desktop-bt-recover.service"
    BT_LATE_SRC="$REPO_ROOT/assets/systemd/azurelinux-desktop-bt-recover-late.service"
    if [[ -f "$BT_RESET_SRC" && -f "$BT_SVC_SRC" ]]; then
        install_ko_source "$BT_RESET_SRC"
        install_ko_source "$BT_SVC_SRC"
        INSTALL_SECTION+="install -Dpm 0755 %{_sourcedir}/azurelinux-desktop-bt-usb-reset %{buildroot}/usr/libexec/azurelinux-desktop-bt-usb-reset"$'\n'
        INSTALL_SECTION+="install -Dpm 0644 %{_sourcedir}/azurelinux-desktop-bt-recover.service %{buildroot}/usr/lib/systemd/system/azurelinux-desktop-bt-recover.service"$'\n'
        BT_RECOVER_FILES="/usr/libexec/azurelinux-desktop-bt-usb-reset
/usr/lib/systemd/system/azurelinux-desktop-bt-recover.service
"
        if [[ -f "$BT_LATE_SRC" ]]; then
            install_ko_source "$BT_LATE_SRC"
            INSTALL_SECTION+="install -Dpm 0644 %{_sourcedir}/azurelinux-desktop-bt-recover-late.service %{buildroot}/usr/lib/systemd/system/azurelinux-desktop-bt-recover-late.service"$'\n'
            BT_RECOVER_FILES+="/usr/lib/systemd/system/azurelinux-desktop-bt-recover-late.service
"
        fi
    else
        echo "warning: BT recover assets missing; shipping modules only" >&2
        BT_RECOVER_FILES=""
    fi
    FILES_SECTIONS+="
%files -n azurelinux-desktop-bluetooth-kmod
${BT_FILES}%config(noreplace) %{_sysconfdir}/modules-load.d/azurelinux-desktop-bluetooth.conf
%config(noreplace) %{_sysconfdir}/modprobe.d/azurelinux-desktop-bluetooth.conf
${BT_RECOVER_FILES}"
    POST_SECTIONS+="
%post -n azurelinux-desktop-bluetooth-kmod
/usr/sbin/depmod -a ${KVERREL} || :
if [ -x /usr/libexec/azurelinux-desktop-bt-usb-reset ]; then
    /usr/bin/systemctl enable azurelinux-desktop-bt-recover.service 2>/dev/null || :
    /usr/bin/systemctl enable azurelinux-desktop-bt-recover-late.service 2>/dev/null || :
fi
%postun -n azurelinux-desktop-bluetooth-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled uvc; then
    append_requires azurelinux-desktop-uvc-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-uvc-kmod
Summary:        USB Video Class modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-uvc-kmod
uvc common helper and uvcvideo for Azure Linux kernel ${KVERREL}.
"
    UVC_FILES=""
    if have_ko "$UVC_COMMON_MODULE"; then
        INSTALL_SECTION+="$(ko_install_line uvc.ko)"$'\n'
        UVC_FILES+="$(ko_files_line uvc.ko)"$'\n'
    fi
    INSTALL_SECTION+="$(ko_install_line uvcvideo.ko)"$'\n'
    UVC_FILES+="$(ko_files_line uvcvideo.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-uvc-kmod
${UVC_FILES}"
    POST_SECTIONS+="
%post -n azurelinux-desktop-uvc-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-uvc-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled hidmt; then
    append_requires azurelinux-desktop-hid-multitouch-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-hid-multitouch-kmod
Summary:        Generic HID-over-I2C Precision Touchpad module for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-hid-multitouch-kmod
hid-multitouch for Azure Linux kernel ${KVERREL}. Covers trackpads and
touchscreens that report through the generic Windows Precision
Touchpad / multitouch HID protocol over i2c-hid, used by some modern
ThinkPad and other laptop models instead of the Synaptics RMI4 SMBus
path already covered by psmouse-kmod.
"
    INSTALL_SECTION+="$(ko_install_line hid-multitouch.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-hid-multitouch-kmod
$(ko_files_line hid-multitouch.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-hid-multitouch-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-hid-multitouch-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled touchpad; then
    append_requires azurelinux-desktop-touchpad-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-touchpad-kmod
Summary:        I2C-native precision touchpad modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-touchpad-kmod
elan_i2c and Synaptics RMI4-over-I2C (rmi_core, rmi_i2c) modules for
Azure Linux kernel ${KVERREL}. Covers trackpads wired straight to an
I2C bus instead of PS/2 or SMBus, common on many consumer and
enterprise laptops (Dell, HP, ASUS, Acer, and some ThinkPads).
psmouse-kmod already covers PS/2 and RMI4-over-SMBus.
"
    TOUCHPAD_INSTALL=""
    TOUCHPAD_FILES=""
    if have_ko "$TOUCHPAD_RMI_CORE"; then
        TOUCHPAD_INSTALL+="$(ko_install_line rmi_core.ko)"$'\n'
        TOUCHPAD_INSTALL+="$(ko_install_line rmi_i2c.ko)"$'\n'
        TOUCHPAD_FILES+="$(ko_files_line rmi_core.ko)"$'\n'
        TOUCHPAD_FILES+="$(ko_files_line rmi_i2c.ko)"$'\n'
    fi
    if have_ko "$TOUCHPAD_ELAN"; then
        TOUCHPAD_INSTALL+="$(ko_install_line elan_i2c.ko)"$'\n'
        TOUCHPAD_FILES+="$(ko_files_line elan_i2c.ko)"$'\n'
    fi
    INSTALL_SECTION+="${TOUCHPAD_INSTALL}"
    FILES_SECTIONS+="
%files -n azurelinux-desktop-touchpad-kmod
${TOUCHPAD_FILES}"
    POST_SECTIONS+="
%post -n azurelinux-desktop-touchpad-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-touchpad-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled logitech; then
    append_requires azurelinux-desktop-logitech-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-logitech-kmod
Summary:        Logitech Unifying receiver and HID++ modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-logitech-kmod
hid-logitech-dj and hid-logitech-hidpp modules for Azure Linux kernel
${KVERREL}. Decodes the Logitech Unifying receiver's multiplexed
reports and HID++ protocol used by Logitech's wireless and Bluetooth
mice and keyboards (MX series, Unifying receivers), common on both
consumer and enterprise desks. Without these, affected devices fall
back to generic HID and lose battery reporting, DPI/multi-button
features, and in some cases pairing entirely.
"
    INSTALL_SECTION+="$(ko_install_line hid-logitech-dj.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line hid-logitech-hidpp.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-logitech-kmod
$(ko_files_line hid-logitech-dj.ko)
$(ko_files_line hid-logitech-hidpp.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-logitech-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-logitech-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled hidquirks; then
    append_requires azurelinux-desktop-hid-quirks-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-hid-quirks-kmod
Summary:        ASUS and ELAN HID vendor quirk modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-hid-quirks-kmod
hid-asus and hid-elan modules for Azure Linux kernel ${KVERREL}.
hid-asus covers extra keys, keyboard backlight, and touchpad quirks on
ASUS consumer and commercial laptops. hid-elan covers ELAN touchpads
that present over USB/HID rather than native I2C; azurelinux-desktop-
touchpad-kmod covers the native I2C transport (elan_i2c) separately.
"
    INSTALL_SECTION+="$(ko_install_line hid-asus.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line hid-elan.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-hid-quirks-kmod
$(ko_files_line hid-asus.ko)
$(ko_files_line hid-elan.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-hid-quirks-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-hid-quirks-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled tablet; then
    append_requires azurelinux-desktop-tablet-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-tablet-kmod
Summary:        Drawing tablet / pen digitizer HID modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-tablet-kmod
wacom.ko, hid-uclogic.ko, and hid-waltop.ko for Azure Linux kernel
${KVERREL}. Covers Wacom Intuos/Bamboo/Cintiq (USB and Bluetooth),
Huion/UC-Logic, and Waltop graphics tablets and pen displays. Stock
AZL has none of HID_WACOM/HID_UCLOGIC/HID_WALTOP.
"
    INSTALL_SECTION+="$(ko_install_line wacom.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line hid-uclogic.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line hid-waltop.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-tablet-kmod
$(ko_files_line wacom.ko)
$(ko_files_line hid-uclogic.ko)
$(ko_files_line hid-waltop.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-tablet-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-tablet-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled usbeth; then
    append_requires azurelinux-desktop-usbeth-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-usbeth-kmod
Summary:        USB Ethernet adapter modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-usbeth-kmod
r8152 (Realtek RTL8152/8153, nearly every USB-C dock/hub), asix
(older ASIX AX8817X), and ax88179_178a (newer ASIX USB3 gigabit)
modules for Azure Linux kernel ${KVERREL}. Wired ethernet through one
of these chips is often the simplest fallback when a laptop's
built-in Wi-Fi chipset isn't covered by azurelinux-desktop-intel-kmod.
"
    USBETH_INSTALL=""
    USBETH_FILES=""
    if have_ko "$R8152_MODULE"; then
        USBETH_INSTALL+="$(ko_install_line r8152.ko)"$'\n'
        USBETH_FILES+="$(ko_files_line r8152.ko)"$'\n'
    fi
    if have_ko "$ASIX_MODULE"; then
        USBETH_INSTALL+="$(ko_install_line asix.ko)"$'\n'
        USBETH_FILES+="$(ko_files_line asix.ko)"$'\n'
    fi
    if have_ko "$AX88179_MODULE"; then
        USBETH_INSTALL+="$(ko_install_line ax88179_178a.ko)"$'\n'
        USBETH_FILES+="$(ko_files_line ax88179_178a.ko)"$'\n'
    fi
    INSTALL_SECTION+="${USBETH_INSTALL}"
    FILES_SECTIONS+="
%files -n azurelinux-desktop-usbeth-kmod
${USBETH_FILES}"
    POST_SECTIONS+="
%post -n azurelinux-desktop-usbeth-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-usbeth-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled gamepad; then
    append_requires azurelinux-desktop-gamepad-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-gamepad-kmod
Summary:        Common USB/Bluetooth game controller modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-gamepad-kmod
xpad (wired Xbox controllers), hid-sony (PS3/PS4 DualShock), and
hid-playstation (PS5 DualSense, plus the small led-class-multicolor
helper its lightbar/mic-mute LED needs) for Azure Linux kernel
${KVERREL}. The stock kernel already ships CONFIG_HID_STEAM in-tree;
this package covers the other common consumer controller families.
"
    INSTALL_SECTION+="$(ko_install_line xpad.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line hid-sony.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line led-class-multicolor.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line hid-playstation.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-gamepad-kmod
$(ko_files_line xpad.ko)
$(ko_files_line hid-sony.ko)
$(ko_files_line led-class-multicolor.ko)
$(ko_files_line hid-playstation.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-gamepad-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-gamepad-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled acpibattery; then
    append_requires azurelinux-desktop-acpi-battery-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-acpi-battery-kmod
Summary:        ACPI battery module for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-acpi-battery-kmod
battery.ko (drivers/acpi/battery.c) for Azure Linux kernel ${KVERREL}.
Stock AZL leaves CONFIG_ACPI_BATTERY off since it targets cloud/server
hardware without a battery. A handful of vendor laptop platform
drivers (thinkpad_acpi, ideapad-laptop, dell-laptop, asus-wmi, and
their siblings) hard-depend on its battery_hook_register() API at
link time, so it ships as its own small foundational package instead
of being duplicated in each of theirs.
"
    INSTALL_SECTION+="$(ko_install_line battery.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-acpi-battery-kmod
$(ko_files_line battery.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-acpi-battery-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-acpi-battery-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled thinkpad; then
    append_requires azurelinux-desktop-thinkpad-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-thinkpad-kmod
Summary:        ThinkPad and Lenovo consumer laptop modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
Requires:       azurelinux-desktop-acpi-battery-kmod
Recommends:     azurelinux-desktop-hid-multitouch-kmod
%description -n azurelinux-desktop-thinkpad-kmod
thinkpad_acpi (hotkey poll + video), privacy-screen, hid-lenovo, USB
WWAN/tether (usbnet, cdc_mbim, qmi_wwan, …), ideapad-laptop (rfkill,
hotkeys, backlight, fan/thermal profile on Lenovo IdeaPad and Legion
consumer laptops), and lenovo-ymc (tablet-mode switch on Lenovo Yoga
convertibles) for ${KVERREL}. PS/2 TrackPoint/ALPS/SMBus live in
psmouse-kmod. Some newer ThinkPad trackpads report through the generic
HID-over-I2C Precision Touchpad protocol instead of the Synaptics RMI4
SMBus path; this package recommends azurelinux-desktop-hid-multitouch-
kmod for full trackpad coverage on those models. Stock AZL already has
think-lmi, intel-hid, and Lenovo WMI helpers.
"
    TP_FILES=""
    mapfile -t _tp_src < <(find "$WORKDIR/thinkpad" -maxdepth 1 -name '*.ko' -printf '%f\n' 2>/dev/null | sort || true)
    for bn in "${_tp_src[@]}"; do
        if [[ -f "$RPMBUILD/SOURCES/$bn" ]]; then
            INSTALL_SECTION+="$(ko_install_line "$bn")"$'\n'
            TP_FILES+="$(ko_files_line "$bn")"$'\n'
        fi
    done
    # Do not force-load at boot: thinkpad_acpi returns -ENODEV off-machine
    # and fails systemd-modules-load. udev/ACPI loads it on match.
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-thinkpad.conf <<'ML'
# Loaded by udev/ACPI on matching hardware; do not force-load at boot.
ML"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-thinkpad-kmod
${TP_FILES}%config(noreplace) %{_sysconfdir}/modules-load.d/azurelinux-desktop-thinkpad.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-thinkpad-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-thinkpad-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled dell; then
    append_requires azurelinux-desktop-dell-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-dell-kmod
Summary:        Dell laptop platform extras for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
Requires:       azurelinux-desktop-acpi-battery-kmod
%description -n azurelinux-desktop-dell-kmod
dell-laptop.ko for Azure Linux kernel ${KVERREL}. Adds rfkill and
backlight control on Dell Latitude, XPS, Precision, and Inspiron
laptops. Stock AZL already has dell-wmi and dell-smbios, which this
depends on; dell-laptop is the missing piece that actually exposes
rfkill/backlight through them.
"
    INSTALL_SECTION+="$(ko_install_line dell-laptop.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-dell-kmod
$(ko_files_line dell-laptop.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-dell-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-dell-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled asus; then
    append_requires azurelinux-desktop-asus-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-asus-kmod
Summary:        ASUS WMI laptop platform extras for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
Requires:       azurelinux-desktop-acpi-battery-kmod
%description -n azurelinux-desktop-asus-kmod
asus-wmi and asus-nb-wmi for Azure Linux kernel ${KVERREL}. Adds
backlight, rfkill, keyboard backlight, and hotkey support on modern
ASUS laptops (Zenbook, Vivobook, ROG, TUF) via their WMI interface.
Stock AZL only has the legacy ASUS_LAPTOP driver, which doesn't cover
current-generation ASUS hardware; azurelinux-desktop-hid-quirks-kmod
covers hid-asus separately (HID-level quirks, a different subsystem).
"
    INSTALL_SECTION+="$(ko_install_line asus-wmi.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line asus-nb-wmi.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-asus-kmod
$(ko_files_line asus-wmi.ko)
$(ko_files_line asus-nb-wmi.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-asus-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-asus-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled huawei; then
    append_requires azurelinux-desktop-huawei-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-huawei-kmod
Summary:        Huawei laptop WMI platform extras for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
Requires:       azurelinux-desktop-acpi-battery-kmod
%description -n azurelinux-desktop-huawei-kmod
huawei-wmi.ko for Azure Linux kernel ${KVERREL}. Adds hotkeys, fn-lock,
battery charge control, and mic-mute LED on Huawei MateBook laptops.
Stock AZL has no HUAWEI_WMI.
"
    INSTALL_SECTION+="$(ko_install_line huawei-wmi.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-huawei-kmod
$(ko_files_line huawei-wmi.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-huawei-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-huawei-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled system76; then
    append_requires azurelinux-desktop-system76-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-system76-kmod
Summary:        System76 laptop ACPI platform extras for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
Requires:       azurelinux-desktop-acpi-battery-kmod
%description -n azurelinux-desktop-system76-kmod
system76_acpi.ko for Azure Linux kernel ${KVERREL}. Adds Fn-Fx hotkeys,
keyboard backlight, and airplane-mode LED on System76 laptops running
open firmware. Stock AZL has no SYSTEM76_ACPI.
"
    INSTALL_SECTION+="$(ko_install_line system76_acpi.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-system76-kmod
$(ko_files_line system76_acpi.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-system76-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-system76-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled samsung; then
    append_requires azurelinux-desktop-samsung-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-samsung-kmod
Summary:        Samsung laptop platform extras for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
Requires:       azurelinux-desktop-acpi-battery-kmod
%description -n azurelinux-desktop-samsung-kmod
samsung-laptop.ko for Azure Linux kernel ${KVERREL}. Adds function
keys, wireless LED, and LCD backlight control on Samsung laptops.
Stock AZL has no SAMSUNG_LAPTOP.
"
    INSTALL_SECTION+="$(ko_install_line samsung-laptop.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-samsung-kmod
$(ko_files_line samsung-laptop.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-samsung-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-samsung-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled fujitsu; then
    append_requires azurelinux-desktop-fujitsu-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-fujitsu-kmod
Summary:        Fujitsu Lifebook laptop platform extras for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
Requires:       azurelinux-desktop-acpi-battery-kmod
%description -n azurelinux-desktop-fujitsu-kmod
fujitsu-laptop.ko for Azure Linux kernel ${KVERREL}. Adds hotkeys and
backlight control on Fujitsu Lifebook laptops. Stock AZL has no
FUJITSU_LAPTOP.
"
    INSTALL_SECTION+="$(ko_install_line fujitsu-laptop.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-fujitsu-kmod
$(ko_files_line fujitsu-laptop.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-fujitsu-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-fujitsu-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled usbserial; then
    append_requires azurelinux-desktop-usbserial-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-usbserial-kmod
Summary:        Common USB-to-serial converter modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-usbserial-kmod
usbserial.ko plus ftdi_sio.ko, cp210x.ko, pl2303.ko, and ch341.ko for
Azure Linux kernel ${KVERREL}. Covers FTDI, Silicon Labs CP210x,
Prolific PL2303, and WCH CH340/CH341 - the chips behind most consumer
USB-serial cables and adapters (Arduino, GPS mice, some docks and KVM
switch config ports). Stock AZL has no USB_SERIAL at all.
"
    INSTALL_SECTION+="$(ko_install_line usbserial.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line ftdi_sio.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line cp210x.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line pl2303.ko)"$'\n'
    INSTALL_SECTION+="$(ko_install_line ch341.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-usbserial-kmod
$(ko_files_line usbserial.ko)
$(ko_files_line ftdi_sio.ko)
$(ko_files_line cp210x.ko)
$(ko_files_line pl2303.ko)
$(ko_files_line ch341.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-usbserial-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-usbserial-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled udl; then
    append_requires azurelinux-desktop-udl-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-udl-kmod
Summary:        DisplayLink USB video adapter driver for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-udl-kmod
udl.ko for Azure Linux kernel ${KVERREL}. Adds KMS/DRM support for
USB-attached DisplayLink video adapters, common on docking stations
and multi-monitor USB hubs without native DisplayPort/HDMI
passthrough. Stock AZL has no DRM_UDL.
"
    INSTALL_SECTION+="$(ko_install_line udl.ko)"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-udl-kmod
$(ko_files_line udl.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-udl-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-udl-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled typec; then
    append_requires azurelinux-desktop-typec-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-typec-kmod
Summary:        USB Type-C and UCSI modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-typec-kmod
typec, typec_ucsi, and ucsi_acpi for Azure Linux kernel ${KVERREL}.
Stock companions (not rebuilt): thunderbolt/USB4 (CONFIG_USB4),
USB role switch, intel_xhci_usb_role_switch. DP altmode object is
linked into typec_ucsi.
"
    for bn in typec.ko typec_ucsi.ko ucsi_acpi.ko; do
        INSTALL_SECTION+="$(ko_install_line "$bn")"$'\n'
    done
    FILES_SECTIONS+="
%files -n azurelinux-desktop-typec-kmod
$(ko_files_line typec.ko)
$(ko_files_line typec_ucsi.ko)
$(ko_files_line ucsi_acpi.ko)
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-typec-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-typec-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled surface; then
    append_requires azurelinux-desktop-surface-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-surface-kmod
Summary:        Microsoft Surface SSAM/HID modules for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-surface-kmod
Upstream Microsoft Surface platform support for ${KVERREL}: serdev,
Surface System Aggregator (SSAM) core and clients, hid-microsoft,
hid-multitouch, and SSAM HID transports when present. No out-of-tree
linux-surface fork — sources match the Azure Linux kernel tarball.
Pair with azurelinux-desktop-intel-kmod (iwlwifi), sound-kmod (HDA),
and bluetooth-kmod (btintel) on Intel Surfaces.
"
    SURFACE_FILES=""
    for m in "${SURFACE_MODULES[@]}"; do
        bn="$(basename "$m")"
        INSTALL_SECTION+="$(ko_install_line "$bn")"$'\n'
        SURFACE_FILES+="$(ko_files_line "$bn")"$'\n'
    done
    INSTALL_SECTION+="install -Dpm 0644 /dev/stdin %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-surface.conf <<'ML'
# Surface SSAM/HID bind via ACPI/serdev/udev; do not force-load at boot.
ML"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-surface-kmod
${SURFACE_FILES}%config(noreplace) %{_sysconfdir}/modules-load.d/azurelinux-desktop-surface.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-surface-kmod
/usr/sbin/depmod -a ${KVERREL} || :
%postun -n azurelinux-desktop-surface-kmod
/usr/sbin/depmod -a ${KVERREL} || :
"
fi

if pkg_enabled sensors; then
    append_requires azurelinux-desktop-sensors-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-sensors-kmod
Summary:        Desktop sensor module load policy for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-sensors-kmod
modules-load policy for stock hwmon/i2c/thermal modules (coretemp,
i2c-i801, …). Does not rebuild sensors already present in kernel-modules.
"
    INSTALL_SECTION+="install -Dpm 0644 %{_sourcedir}/azurelinux-desktop-sensors.conf %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-sensors.conf"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-sensors-kmod
%config(noreplace) %{_sysconfdir}/modules-load.d/azurelinux-desktop-sensors.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-sensors-kmod
:
%postun -n azurelinux-desktop-sensors-kmod
:
"
fi

if pkg_enabled performance; then
    append_requires azurelinux-desktop-performance-kmod
    PACKAGE_SECTIONS+="
%package -n azurelinux-desktop-performance-kmod
Summary:        Desktop performance helpers for Azure Linux ${KVERREL}
Requires:       kernel-core-uname-r = ${KVERREL}
%description -n azurelinux-desktop-performance-kmod
Conf-only desktop helpers: load stock zram/tcp_bbr/sch_fq/bfq, sysctl for
fq+bbr, sched_autogroup, swappiness=10, mild VM/TCP defaults,
split_lock_mitigate/nmi_watchdog, and zram-generator.conf. Pair with
Fedora zram-generator, tuned+tuned-ppd, and irqbalance on the image.
Does not rebuild the kernel (PREEMPT/HZ/THP stay stock Azure Linux).
"
    INSTALL_SECTION+="install -Dpm 0644 %{_sourcedir}/azurelinux-desktop-performance.conf %{buildroot}%{_sysconfdir}/modules-load.d/azurelinux-desktop-performance.conf"$'\n'
    INSTALL_SECTION+="install -Dpm 0644 %{_sourcedir}/99-azurelinux-desktop-performance.conf %{buildroot}%{_sysconfdir}/sysctl.d/99-azurelinux-desktop-performance.conf"$'\n'
    INSTALL_SECTION+="install -Dpm 0644 %{_sourcedir}/zram-generator.conf %{buildroot}%{_sysconfdir}/systemd/zram-generator.conf"$'\n'
    FILES_SECTIONS+="
%files -n azurelinux-desktop-performance-kmod
%config(noreplace) %{_sysconfdir}/modules-load.d/azurelinux-desktop-performance.conf
%config(noreplace) %{_sysconfdir}/sysctl.d/99-azurelinux-desktop-performance.conf
%config(noreplace) %{_sysconfdir}/systemd/zram-generator.conf
"
    POST_SECTIONS+="
%post -n azurelinux-desktop-performance-kmod
/usr/lib/systemd/systemd-sysctl 99-azurelinux-desktop-performance.conf 2>/dev/null || :
%postun -n azurelinux-desktop-performance-kmod
:
"
fi

FAMILY_LIST="${PRESENT_PKGS[*]}"

cat > "$RPMBUILD/SPECS/azurelinux-desktop-kmods.spec" <<EOF
Name:           azurelinux-desktop-policy
Version:        ${KERNEL_VERSION}
Release:        ${KERNEL_RELEASE}
Summary:        Exact Azure Linux kernel and desktop kmod update policy
License:        GPL-2.0-only
BuildArch:      ${KERNEL_ARCH}
Requires:       kernel-core-uname-r = ${KVERREL}
${REQUIRES_SIBLINGS}
%description
Keeps Azure Linux kernel updates paired with matching desktop modules
built in this set (${FAMILY_LIST}).
${PACKAGE_SECTIONS}
%install
${INSTALL_SECTION}
${POST_SECTIONS}
%files
${FILES_SECTIONS}
EOF

rpmbuild --define "_topdir $RPMBUILD" -bb \
    "$RPMBUILD/SPECS/azurelinux-desktop-kmods.spec"
find "$RPMBUILD/RPMS" -type f -name '*.rpm' -exec cp -v {} "$OUTPUT_DIR/" \;

# Record which families shipped for CI publish validation.
printf '%s\n' "${PRESENT_PKGS[@]}" > "$OUTPUT_DIR/present-families.txt"

echo "Built kmods for $KVERREL (families: ${FAMILY_LIST}):"
ls -la "$OUTPUT_DIR"/*.rpm
