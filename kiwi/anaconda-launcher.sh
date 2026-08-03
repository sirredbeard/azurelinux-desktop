#!/bin/bash
mkdir -p /run/install

# Clean up stale PID file from any previous run
rm -f /run/user/0/anaconda.pid

# Disable all system repos so anaconda only uses the offline repo.
# This prevents silent network fetches even when a NIC is present.
for repo_file in /etc/yum.repos.d/*.repo; do
    [ -f "$repo_file" ] && sed -i -E 's/^enabled\s*=\s*.*/enabled=0/' "$repo_file"
done

# Check kernel cmdline for custom kickstart (inst.ks=<url>)
CUSTOM_KS=""
if grep -qo 'inst\.ks=[^ ]*' /proc/cmdline 2>/dev/null; then
    CUSTOM_KS=$(grep -o 'inst\.ks=[^ ]*' /proc/cmdline | sed 's/inst\.ks=//')
    echo ""
    echo "========================================"
    echo "  Azure Linux 4.0 Offline Installer"
    echo "========================================"
    echo ""
    echo "  Custom kickstart detected: $CUSTOM_KS"
    echo "  Launching anaconda with custom kickstart..."
    echo ""
    /usr/sbin/anaconda --text --kickstart="$CUSTOM_KS"
    RC=$?
    rm -f /run/install/ks.cfg
    if [ $RC -eq 0 ]; then
        echo "Installation complete."
        echo "Press Enter to reboot..."
        read -r
        systemctl reboot
    else
        echo "Anaconda exited with code $RC. Dropping to shell."
        exec /bin/bash
    fi
    exit 0
fi

echo ""
echo "========================================"
echo "  Azure Linux Desktop - Offline Installer"
echo "========================================"
echo ""
echo "  You will be asked to:"
echo "    1. Set an administrator username and password"
echo "    2. Configure storage (disk selection, partitioning,"
echo "       and optional LUKS encryption) in the installer"
echo ""

collect_admin_account() {
    while :; do
        read -r -p "Administrator username: " ADMIN_USER
        if [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
            break
        fi
        echo "Use a lowercase username beginning with a letter or underscore." >&2
    done

    while :; do
        read -r -s -p "Administrator password: " ADMIN_PASSWORD
        echo
        read -r -s -p "Confirm administrator password: " ADMIN_PASSWORD_CONFIRM
        echo
        if [ -n "$ADMIN_PASSWORD" ] && [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ]; then
            break
        fi
        echo "Passwords must be non-empty and match." >&2
    done

    ADMIN_PASSWORD_HASH="$(printf '%s\n' "$ADMIN_PASSWORD" | openssl passwd -6 -stdin)"
    unset ADMIN_PASSWORD ADMIN_PASSWORD_CONFIRM
}

write_kickstart_with_admin_user() {
    local template="$1"
    local account_directive

    umask 077
    account_directive="$(mktemp /run/install/account.XXXXXX)"
    printf 'user --name=%s --groups=wheel --password=%s --iscrypted --shell=/usr/bin/pwsh\n' \
        "$ADMIN_USER" "$ADMIN_PASSWORD_HASH" > "$account_directive"
    awk -v account_directive="$account_directive" '
        /^%packages/ && !inserted {
            while ((getline line < account_directive) > 0) print line
            close(account_directive)
            inserted = 1
        }
        { print }
    ' "$template" > /run/install/ks.cfg
    rm -f "$account_directive"
}

collect_admin_account

write_kickstart_with_admin_user /root/azl-install.ks

echo ""
/usr/sbin/anaconda --text --kickstart=/run/install/ks.cfg
RC=$?

rm -f /run/install/ks.cfg

if [ $RC -eq 0 ]; then
    echo ""
    echo "Installation complete."
    echo ""
    echo "=== Bootloader log (from %post --nochroot) ==="
    for mnt in /mnt/sysroot /mnt/sysimage; do
        [ -f "$mnt/var/log/anaconda-bootloader.log" ] && {
            tail -60 "$mnt/var/log/anaconda-bootloader.log"
            break
        }
    done
    echo ""
    echo "Ejecting installation media..."
    eject /dev/sr0 2>/dev/null || eject /dev/cdrom 2>/dev/null || true
    echo "Press Enter to reboot into the installed system..."
    read -r
    systemctl reboot
else
    echo ""
    echo "======================================================"
    echo " Anaconda exited with code $RC."
    echo " You are now in the live ISO shell."
    echo " Run 'anaconda --text' to retry, or investigate logs."
    echo " Logs: /tmp/anaconda.log, /tmp/packaging.log"
    echo "======================================================"
    exec /bin/bash
fi
