#!/usr/bin/env bash
# restage-azl-nested-boot.sh
#
# Purpose: After host dual-boot changes, restage nested boot bits, dracut
#   50azl-nested-partx, and GRUB stubs on the nested root.
# Usage:   ./scripts/restage-azl-nested-boot.sh
# Needs:   root; host partition mounted or mountable; assets/dracut module.
# CI:      No.

set -euo pipefail

PART="${AZL_NESTED_PART:-/dev/nvme0n1p4}"
MNT="${AZL_NESTED_MNT:-/mnt/azl-dual}"
GRUB_DROPIN="${AZL_GRUB_DROPIN:-/etc/grub.d/45_azurelinux_desktop_nested}"
STAGED_VMLINUZ="${AZL_STAGED_VMLINUZ:-/boot/vmlinuz-azl-desktop-nested}"
STAGED_INITRD="${AZL_STAGED_INITRD:-/boot/initramfs-azl-desktop-nested.img}"
FEDORA_BOOT_UUID="${AZL_FEDORA_BOOT_UUID:-}"

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "re-exec with pkexec..." >&2
        local self
        self="$(readlink -f "$0")"
        exec pkexec env PATH="$PATH" \
            AZL_NESTED_PART="$PART" \
            AZL_NESTED_MNT="$MNT" \
            AZL_GRUB_DROPIN="$GRUB_DROPIN" \
            AZL_STAGED_VMLINUZ="$STAGED_VMLINUZ" \
            AZL_STAGED_INITRD="$STAGED_INITRD" \
            AZL_FEDORA_BOOT_UUID="$FEDORA_BOOT_UUID" \
            AZL_FORCE_DRACUT="${AZL_FORCE_DRACUT:-0}" \
            bash "$self" "$@"
    fi
}

umount_all() {
    if mountpoint -q "$MNT" 2>/dev/null; then
        for d in home boot/efi boot; do
            umount "$MNT/$d" 2>/dev/null || true
        done
        umount "$MNT" 2>/dev/null || true
    fi
    kpartx -d "$PART" 2>/dev/null || true
}

mount_nested() {
    mkdir -p "$MNT"
    kpartx -d "$PART" 2>/dev/null || true
    kpartx -av "$PART"
    sleep 1

    local base maps
    base="$(basename "$PART")"
    maps=()
    while read -r name; do
        [ -n "$name" ] || continue
        maps+=("/dev/mapper/$name")
    done < <(ls /dev/mapper 2>/dev/null | grep -E "^${base}p[0-9]+$" | sort -V)

    if [ "${#maps[@]}" -lt 3 ]; then
        echo "error: expected nested ESP/boot/root under $PART (got: ${maps[*]:-none})" >&2
        exit 1
    fi

    # Standard Anaconda desktop layout inside the container:
    # p1 EFI, p2 /boot, p3 /, p4 /home (home optional for restage).
    local esp boot root home
    esp="${maps[0]}"
    boot="${maps[1]}"
    root="${maps[2]}"
    home="${maps[3]:-}"

    mount "$root" "$MNT"
    mkdir -p "$MNT/boot" "$MNT/boot/efi"
    mount "$boot" "$MNT/boot"
    mount "$esp" "$MNT/boot/efi" 2>/dev/null || true
    if [ -n "$home" ]; then
        mkdir -p "$MNT/home"
        mount "$home" "$MNT/home" 2>/dev/null || true
    fi

    echo "mounted nested root=$root boot=$boot"
}

pick_kernel() {
    local k
    k="$(ls -1 "$MNT/boot"/vmlinuz-* 2>/dev/null | grep -v '\.old$' | sort -V | tail -1 || true)"
    if [ -z "$k" ]; then
        echo "error: no vmlinuz-* under nested /boot" >&2
        exit 1
    fi
    echo "$k"
}

main() {
    need_root "$@"
    umount_all
    mount_nested

    local kpath kver initrd root_uuid boot_uuid
    kpath="$(pick_kernel)"
    kver="$(basename "$kpath" | sed 's/^vmlinuz-//')"
    initrd="$MNT/boot/initramfs-${kver}.img"
    if [ ! -f "$initrd" ]; then
        initrd="$(ls -1 "$MNT/boot"/initramfs-"${kver}"*.img 2>/dev/null | head -1 || true)"
    fi
    if [ ! -f "$initrd" ]; then
        echo "error: missing initramfs for $kver under nested /boot" >&2
        ls -la "$MNT/boot" | head -40 >&2 || true
        exit 1
    fi

    root_uuid="$(findmnt -no UUID "$MNT")"
    if [ -z "$root_uuid" ]; then
        root_uuid="$(blkid -s UUID -o value "$(findmnt -no SOURCE "$MNT")")"
    fi
    if [ -z "$root_uuid" ]; then
        echo "error: could not read nested root UUID" >&2
        exit 1
    fi

    if [ -n "$FEDORA_BOOT_UUID" ]; then
        boot_uuid="$FEDORA_BOOT_UUID"
    else
        boot_uuid="$(findmnt -no UUID /boot 2>/dev/null || true)"
    fi
    if [ -z "$boot_uuid" ]; then
        boot_uuid="$(blkid -s UUID -o value "$(findmnt -no SOURCE /boot)")"
    fi
    if [ -z "$boot_uuid" ]; then
        echo "error: could not read Fedora /boot UUID" >&2
        exit 1
    fi

    echo "staging kernel $kver"
    echo "  nested root UUID=$root_uuid"
    echo "  Fedora /boot UUID=$boot_uuid"

    # Ensure dual-boot nested-partx dracut module exists, then rebuild
    # initrd if the hook is missing. Stock Anaconda images do not ship it.
    local repo_root mod_src
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    mod_src="$repo_root/assets/dracut/50azl-nested-partx"
    if [ -d "$mod_src" ]; then
        install -d "$MNT/usr/lib/dracut/modules.d/50azl-nested-partx"
        install -m 0755 "$mod_src/module-setup.sh" \
            "$MNT/usr/lib/dracut/modules.d/50azl-nested-partx/module-setup.sh"
        install -m 0755 "$mod_src/azl-nested-partx.sh" \
            "$MNT/usr/lib/dracut/modules.d/50azl-nested-partx/azl-nested-partx.sh"
    fi
    # Drop missing bochs_drm from early-kms if present (not in AZL module set).
    if [ -f "$MNT/etc/dracut.conf.d/early-kms.conf" ]; then
        sed -i 's/bochs_drm//g' "$MNT/etc/dracut.conf.d/early-kms.conf"
    fi

    # Keep first-boot and hardware-check logs across reboots on the nested root.
    mkdir -p "$MNT/var/log/journal" "$MNT/etc/systemd/journald.conf.d"
    chmod 2755 "$MNT/var/log/journal"
    printf '%s\n' '[Journal]' 'Storage=persistent' 'SystemMaxUse=256M' \
        >"$MNT/etc/systemd/journald.conf.d/90-azl-desktop-persistent.conf"
    # Quiet optional modules that fail off-hardware so
    # systemd-modules-load.service does not fail the boot unit on VMs.
    if [ -f "$MNT/etc/modules-load.d/azurelinux-desktop-thinkpad.conf" ]; then
        cat >"$MNT/etc/modules-load.d/azurelinux-desktop-thinkpad.conf" <<'EOF'
# Loaded by udev/ACPI on matching hardware; do not force-load at boot.
EOF
    fi
    if [ -f "$MNT/etc/modules-load.d/azurelinux-desktop-sound.conf" ]; then
        cat >"$MNT/etc/modules-load.d/azurelinux-desktop-sound.conf" <<'EOF'
# snd-hda-intel is loaded by udev when HDA audio hardware appears.
EOF
    fi
    if [ ! -f "$MNT/etc/modprobe.d/azurelinux-desktop-alsa.conf" ]; then
        cat >"$MNT/etc/modprobe.d/azurelinux-desktop-alsa.conf" <<'EOF'
# Override Fedora dist-alsa.conf: AZL kernel has no snd-seq module.
install snd-pcm /sbin/modprobe --ignore-install snd-pcm $CMDLINE_OPTS
EOF
    fi

    local need_rebuild=0
    if command -v lsinitrd >/dev/null 2>&1; then
        if ! lsinitrd "$initrd" 2>/dev/null | grep -q 'azl-nested-partx'; then
            need_rebuild=1
        fi
    else
        need_rebuild=1
    fi
    # Always rebuild once after install so nested kpartx + journal path land
    # in the staged host initrd used for bare-metal GRUB.
    if [ ! -f "$MNT/usr/lib/dracut/modules.d/50azl-nested-partx/module-setup.sh" ]; then
        need_rebuild=1
    fi
    if [ "$need_rebuild" = "1" ] || [ "${AZL_FORCE_DRACUT:-0}" = "1" ]; then
        echo "rebuilding nested initrd with 50azl-nested-partx..."
        mount --bind /dev "$MNT/dev"
        mount --bind /proc "$MNT/proc"
        mount --bind /sys "$MNT/sys"
        mount --bind /run "$MNT/run"
        # Force-add the nested mapper; omit-by-host-policy has bitten before.
        if ! chroot "$MNT" dracut -f --add azl-nested-partx --kver "$kver" \
            "/boot/initramfs-${kver}.img"; then
            umount "$MNT/run" "$MNT/sys" "$MNT/proc" "$MNT/dev" 2>/dev/null || true
            echo "error: dracut rebuild failed" >&2
            exit 1
        fi
        umount "$MNT/run" "$MNT/sys" "$MNT/proc" "$MNT/dev"
        initrd="$MNT/boot/initramfs-${kver}.img"
    fi

    install -m 0755 "$kpath" "$STAGED_VMLINUZ"
    # 0644 so host tooling (lsinitrd) can verify the staged image.
    install -m 0644 "$initrd" "$STAGED_INITRD"

    if command -v lsinitrd >/dev/null 2>&1; then
        local staged_list
        staged_list="$(lsinitrd "$STAGED_INITRD" 2>&1 || true)"
        if printf '%s\n' "$staged_list" | grep -Eq 'azl-nested-partx|10-azl-nested-partx'; then
            echo "staged initrd: nested kpartx hook present"
        else
            echo "warning: staged initrd may lack nested kpartx hook" >&2
        fi
        if printf '%s\n' "$staged_list" | grep -Eq 'usbhid\.ko|usb-storage\.ko'; then
            echo "staged initrd: project USB modules present"
        fi
    fi

    cat >"$GRUB_DROPIN" <<EOF
#!/usr/bin/sh
set -e
# Dual-boot Azure Linux Desktop nested install on host container partition.
# Kernel/initrd are staged on Fedora /boot because this GRUB build has
# no search_part_uuid module, and nested filesystems are not visible to
# GRUB until loopback. Staging avoids fragile loopback at menu time.
# Nested initramfs still runs kpartx so root=UUID works on bare metal.
# Regenerated by scripts/restage-azl-nested-boot.sh — do not hand-edit
# UUIDs here; re-run the script after a nested reinstall.
cat << "MENU"
menuentry "Azure Linux Desktop (test install on nvme0n1p4)" --class azurelinux --class gnu-linux --class gnu --class os {
    insmod part_gpt
    insmod ext2
    insmod gzio
    search --no-floppy --fs-uuid --set=root ${boot_uuid}
    echo "Loading Azure Linux Desktop nested install (kernel from Fedora /boot)..."
    # rhgb quiet: graphical Plymouth. console=tty0 only (no ttyS0) so
    # Plymouth is not suppressed by a serial console.
    linux /vmlinuz-azl-desktop-nested root=UUID=${root_uuid} ro rootwait console=tty0 rhgb quiet
    initrd /initramfs-azl-desktop-nested.img
}
menuentry "Azure Linux Desktop rescue (nested nvme0n1p4)" --class azurelinux --class gnu-linux --class gnu --class os {
    insmod part_gpt
    insmod ext2
    insmod gzio
    search --no-floppy --fs-uuid --set=root ${boot_uuid}
    echo "Loading Azure Linux Desktop rescue..."
    linux /vmlinuz-azl-desktop-nested root=UUID=${root_uuid} ro rootwait console=tty0 systemd.unit=rescue.target
    initrd /initramfs-azl-desktop-nested.img
}
menuentry "Azure Linux Desktop (loopback fallback)" --class azurelinux --class gnu-linux --class gnu --class os {
    insmod part_gpt
    insmod ext2
    insmod loopback
    insmod gzio
    search --no-floppy --fs-uuid --set=fedoraboot ${boot_uuid}
    set found=0
    for d in hd0 hd1 hd2; do
        if [ -e (\$d,gpt4) ]; then
            loopback azldisk (\$d,gpt4)
            if [ -e (azldisk,gpt2)/vmlinuz-${kver} ]; then
                set root=(azldisk,gpt2)
                set found=1
                break
            fi
            loopback -d azldisk
        fi
    done
    if [ "\$found" != "1" ]; then
        echo "Nested Azure Linux boot files not found via loopback"
        sleep 5
        false
    fi
    linux /vmlinuz-${kver} root=UUID=${root_uuid} ro rootwait console=tty0
    initrd /initramfs-${kver}.img
}
MENU
EOF
    chmod 0755 "$GRUB_DROPIN"

    if command -v grub2-mkconfig >/dev/null 2>&1; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        grub-mkconfig -o /boot/grub2/grub.cfg
    fi

    if command -v grub2-script-check >/dev/null 2>&1; then
        grub2-script-check /boot/grub2/grub.cfg
        echo "grub2-script-check: OK"
    fi

    echo "=== staged files ==="
    ls -la "$STAGED_VMLINUZ" "$STAGED_INITRD"
    echo "=== drop-in root= line ==="
    grep -E 'linux /vmlinuz-azl|root=UUID' "$GRUB_DROPIN" | head -10
    echo "=== grub.cfg menu titles ==="
    grep -E 'Azure Linux Desktop' /boot/grub2/grub.cfg | head -10

    # Spot-check desktop kmods / firmware on nested root when present.
    if [ -d "$MNT/usr/lib/modules/$kver" ]; then
        echo "=== nested modules snapshot ==="
        ls "$MNT/usr/lib/modules/$kver/extra/azurelinux-desktop" 2>/dev/null \
            || echo "(no project extra modules dir)"
        if ls "$MNT/usr/lib/modules/$kver/extra/azurelinux-desktop"/iwlwifi*.ko* \
            >/dev/null 2>&1; then
            echo "iwlwifi: present under extra/azurelinux-desktop"
        else
            echo "iwlwifi: missing under extra/azurelinux-desktop"
        fi
    fi
    echo "=== nested desktop packages ==="
    rpm --root "$MNT" -qa \
        'azurelinux-desktop*' 'iwlwifi*' kernel-modules-extra \
        2>/dev/null | sort || true
    if [ -f "$MNT/etc/systemd/journald.conf.d/90-azl-desktop-persistent.conf" ]; then
        echo "journald: persistent storage enabled on nested root"
    fi

    umount_all
    echo "restage complete. nested maps removed."
    echo "Reboot and pick 'Azure Linux Desktop (test install on nvme0n1p4)' for bare metal."
}

main "$@"
