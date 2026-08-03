#!/usr/bin/env bash
# Render a disk-image kickstart variant for CI testing. It keeps the shared
# live-image kickstart as the source of truth, applies the same disk-image
# fixes build-live-iso.yml already uses, then appends a small test-only
# systemd service that runs the post-boot checks once and reports back over
# the serial console.

set -euo pipefail

INPUT_KS="${1:?usage: $0 /path/to/azurelinux-desktop-live.ks /path/to/output.ks}"
OUTPUT_KS="${2:?usage: $0 /path/to/azurelinux-desktop-live.ks /path/to/output.ks}"

sed \
    -e 's/^bootloader --location=none/bootloader/' \
    -e 's/^part \/ --size=16384/part \/ --fstype=xfs --size=16384 --grow/' \
    -e 's/^# AZL_GROWROOT_ENABLE_MARKER$/systemctl enable azl-growroot.service/' \
    "$INPUT_KS" > "$OUTPUT_KS"

cat >> "$OUTPUT_KS" <<'KSPOST'

# Regular (chrooted) %post has no access to /workspace - it's the build
# container's own checkout, not something bind-mounted into the sysimage
# chroot. The main live kickstart already hits this exact wall for its
# icons/plymouth-theme assets (see its own %post --nochroot block); same
# fix here: --nochroot runs in the build container itself, so /workspace
# is reachable, and it can write straight into /mnt/sysimage.
%post --nochroot --log=/mnt/sysimage/var/log/azl-desktop-test-suite-post-nochroot.log
set -x
install -D -m 0755 /workspace/scripts/test-in-guest-checks.sh /mnt/sysimage/usr/local/sbin/azl-image-test
install -D -m 0644 /workspace/scripts/test-repo-common.sh /mnt/sysimage/usr/local/lib/azl-test-repo-common.sh
%end

%post --log=/var/log/azl-desktop-test-suite-post.log
set -x

cat > /usr/lib/systemd/system/azl-image-test.service << 'EOF'
[Unit]
Description=Run Azure Linux Desktop CI guest checks once on first boot
ConditionPathExists=!/var/lib/azl-image-test.done

[Service]
Type=oneshot
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=0
ExecStart=/usr/local/sbin/azl-image-test

[Install]
WantedBy=multi-user.target
EOF

systemctl enable azl-image-test.service
%end
KSPOST
