# Generate the ARM64 variant of the live kickstart: aarch64 repo URLs
# and EFI packages, x86_64-only packages dropped, and the %post block
# that side-loads x86_64 binaries (the thirdparty fetch) neutralized.
# The Copilot Flatpak prestage block stays: since copilot-desktop-gtk
# v0.1.21 the app publishes an aarch64 build, so the block's AppStream
# paths are swapped to aarch64 and the ARM workflow prestages from the
# project's repo-aarch64 Pages remote. Edge has no arm64 Linux build,
# so the ARM variant also adds the edge-arm-bridge repo and package:
# FEX running the x86_64 Edge build, with the sync service mirroring
# the profile to native Chromium. Usage: make-arm-ks.py <in.ks> <out.ks>
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
# Arch URLs
src = src.replace('azurelinux/4.0/beta/base/x86_64','azurelinux/4.0/beta/base/aarch64')
src = src.replace('azurelinux/4.0/beta/microsoft/x86_64','azurelinux/4.0/beta/microsoft/aarch64')
src = src.replace('releases/45/Everything/x86_64','releases/45/Everything/aarch64')
src = src.replace('updates/45/Everything/x86_64','updates/45/Everything/aarch64')
src = src.replace('arch=x86_64','arch=aarch64')
lines = src.split('\n'); out=[]
for ln in lines:
    s = ln.strip()
    if s == 'grub2-efi-x64': ln = ln.replace('grub2-efi-x64','grub2-efi-aa64')
    elif s == 'grub2-efi-x64-modules': ln = ln.replace('grub2-efi-x64-modules','grub2-efi-aa64-modules')
    elif s == 'grub2-efi-x64-cdboot': ln = ln.replace('grub2-efi-x64-cdboot','grub2-efi-aa64-cdboot')
    elif s == 'shim': ln = ln.replace('shim','shim-aa64')
    out.append(ln)
src = '\n'.join(out)
# Drop x86-only packages (bare lines in %packages)
drops = ['azurelinux-desktop-policy','microsoft-edge-canary','powershell','code-insiders','gh','github-desktop','virtualbox-guest-additions','microcode_ctl','thermald','intel-media-driver','intel-mediasdk']
for pkg in drops:
    src = re.sub(r'(?m)^'+re.escape(pkg)+r'\n', '', src)
# Edge on ARM comes from the edge-arm-bridge Pages repo (baseurl matches
# the project's published .repo file, which sets gpgcheck=0).
src = re.sub(r'(?m)^(repo --name=azl-desktop-kmods .*)$',
    r'\1\nrepo --name=edge-arm-bridge --baseurl=https://sirredbeard.github.io/edge-arm-bridge/repo/ --cost=1', src, count=1)
# Chromium is the bridge's sync target (the bridge RPM now requires
# chromium or google-chrome-stable, so the image must carry it).
src = re.sub(r'(?m)^(%packages.*)$', r'\1\nedge-arm-bridge\nchromium', src, count=1)
# Dock and launcher layout for ARM: the dock holds Copilot, the synced
# Chromium entry, and Files. Edge (microsoft-edge-fex.desktop) and the
# bridge configurator stay in the app grid, out of the dock.
ARM_FAVORITES = "['com.github.sirredbeard.copilot-desktop-gtk.desktop', 'chromium-edge-synced.desktop', 'org.gnome.Nautilus.desktop']"
OLD_FAVORITES = "['com.github.sirredbeard.copilot-desktop-gtk.desktop', 'microsoft-edge-canary.desktop', 'code-insiders.desktop', 'org.azurelinux.PowerShell.desktop', 'GitHub Copilot.desktop', 'org.gnome.Nautilus.desktop']"
assert OLD_FAVORITES in src, 'favorites list not found in kickstart'
src = src.replace(OLD_FAVORITES, ARM_FAVORITES)
# The installed-system dconf defaults get the same list: rewrite the
# file right after the %post installs it, before `dconf update` runs.
anchor = 'install -m 0644 "$ASSETS"/dconf/db/local.d/00-azl-desktop-defaults \\\n    /etc/dconf/db/local.d/00-azl-desktop-defaults'
assert anchor in src, 'dconf defaults install line not found'
src = src.replace(anchor, anchor + '\n# ARM dock layout (see make-arm-ks.py): synced Chromium in the dock, Edge in the app grid only.\nsed -i "s|^favorite-apps=.*|favorite-apps=' + ARM_FAVORITES + '|" /etc/dconf/db/local.d/00-azl-desktop-defaults')
# Ship the labeled Chromium entry itself.
anchor2 = 'install -m 0644 /workspace/assets/desktop/dotnet.desktop /mnt/sysimage/usr/share/applications/dotnet.desktop'
assert anchor2 in src, 'desktop asset install block not found'
src = src.replace(anchor2, anchor2 + '\ninstall -m 0644 /workspace/assets/desktop/chromium-edge-synced.desktop /mnt/sysimage/usr/share/applications/chromium-edge-synced.desktop')
# Neutralize the thirdparty fetch block in %post --nochroot
src = src.replace('''if [ ! -x /workspace/scripts/fetch-latest-thirdparty.sh ]; then
    echo "error: /workspace/scripts/fetch-latest-thirdparty.sh missing" >&2
    exit 1
fi
/workspace/scripts/fetch-latest-thirdparty.sh /mnt/sysimage/root/thirdparty''',
'''# ARM test build: thirdparty side-loads are x86_64 binaries; skipped.
mkdir -p /mnt/sysimage/root/thirdparty''')
# Keep the flatpak prestage block; swap its AppStream arch paths to
# aarch64 (the tree the ARM workflow's prestage produces).
m = re.search(r'STAGE_FP=/workspace/prestage/flatpak-system\n.*?test -d /mnt/sysimage/var/lib/flatpak/appstream/flathub/x86_64/active/icons\n', src, flags=re.S)
assert m, 'Copilot prestage block not found in kickstart'
src = src[:m.start()] + m.group(0).replace('x86_64', 'aarch64') + src[m.end():]
# Every transform above has to have landed. The anchors with inline
# asserts are the historical failure points; these cover the rest, so a
# source-kickstart change fails generation loudly instead of leaking
# x86_64 content into the ARM image.
assert 'releases/45/Everything/aarch64' in src, 'fedora aarch64 repo URL missing'
assert 'arch=x86_64' not in src, 'x86_64 arch parameter survived generation'
assert 'repo --name=edge-arm-bridge' in src, 'edge-arm-bridge repo line missing'
assert re.search(r'(?m)^chromium$', src), 'chromium missing from %packages'
assert 'fetch-latest-thirdparty.sh /mnt/sysimage' not in src, 'thirdparty fetch was not neutralized'
p = pathlib.Path(sys.argv[2])
p.write_text(src)
print('arm ks written', len(src.split(chr(10))), 'lines')
for probe in ['fetch-latest-thirdparty.sh /mnt/sysimage','STAGE_FP=','grub2-efi-aa64-cdboot','shim-aa64','microsoft-edge-canary','azurelinux-desktop-policy','chromium-edge-synced.desktop','edge-arm-bridge']:
    print(probe, '->', src.count(probe))
