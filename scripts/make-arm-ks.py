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
# Drop x86-only packages (bare lines in %packages). The desktop policy
# is not in this list: the kmod publish workflow builds an aarch64
# policy alongside the x86_64 one into the same flat repo, and the ARM
# image pulls it (and the sound family it Requires) from there.
drops = ['microsoft-edge-canary','powershell','code-insiders','gh','github-desktop','virtualbox-guest-additions','microcode_ctl','thermald','intel-media-driver','intel-mediasdk']
for pkg in drops:
    src = re.sub(r'(?m)^'+re.escape(pkg)+r'\n', '', src)
# Edge on ARM comes from the edge-arm-bridge Pages repo (baseurl matches
# the project's published .repo file, which sets gpgcheck=0).
src = re.sub(r'(?m)^(repo --name=azl-desktop-kmods .*)$',
    r'\1\nrepo --name=edge-arm-bridge --baseurl=https://sirredbeard.github.io/edge-arm-bridge/repo/ --cost=1', src, count=1)
# Chromium is the bridge's sync target (the bridge RPM now requires
# chromium or google-chrome-stable, so the image must carry it).
# qcom-firmware is the Fedora package that carries the Qualcomm
# firmware Azure's linux-firmware lacks: the qcom/qcs8300 DSP set,
# the Adreno 623 zap (a623_zap.mbn), and the audio topology binaries
# (including arduino-monza-tplg.bin). Phase 0 verified the two
# firmware packages co-install clean against this kickstart's repos.
src = re.sub(r'(?m)^(%packages.*)$', r'\1\nedge-arm-bridge\nchromium\nqcom-firmware', src, count=1)
# Azure ships its own qcom-firmware (20260221) and the azl-base repo's
# cost of 1 beats the Fedora repos' 50, so the solve installs Azure's
# older snapshot, which predates the arduino-monza topology binary and
# the gpdsp remoteproc map. Hide Azure's build on ARM so the Fedora
# package the line above asks for is the one that lands.
def _azl_base_exclude_qcom(m):
    line = m.group(0)
    assert '--excludepkgs=' in line, 'azl-base excludepkgs anchor missing'
    return line.replace('--excludepkgs=', '--excludepkgs=qcom-firmware,', 1)
src = re.sub(r'(?m)^(repo --name=azl-base .*)$', _azl_base_exclude_qcom, src, count=1)
# The azl-base hide is not sufficient on its own. Fedora's
# qcom-firmware version-locks to its own family (atheros-firmware
# and linux-firmware-whence at the same EVR), Azure's
# linux-firmware locks to Azure's whence, and the shared claw-back
# list freezes the whole firmware family to Azure, so Fedora's
# qcom-firmware cannot solve at all and the solver falls back to
# Azure's build. Measured Nov 9, 2026: the stage 1 proof image
# carried Azure's 20260221 despite the hide (the live build's
# lorax does not reliably honor repo --excludepkgs either). On
# ARM the family moves together instead: strip the firmware
# family from the Fedora repos' excludepkgs in the generated ks
# and the solver takes Fedora's consistent, newer set wholesale.
def _unfreeze_firmware_family(m):
    line = m.group(0)
    head, sep, rest = line.partition('--excludepkgs=')
    assert sep, 'fedora excludepkgs anchor missing'
    names, sp, tail = rest.partition(' ')
    kept = [n for n in names.split(',')
            if n not in ('linux-firmware', 'linux-firmware-whence')
            and not n.endswith('-firmware')]
    return head + sep + ','.join(kept) + (sp + tail if sp else '')
src = re.sub(r'(?m)^(repo --name=fedora45(?:-updates)? .*)$',
             _unfreeze_firmware_family, src)
# Fedora also carries the Monza DSP binaries as their own package;
# it requires qcom-firmware and belongs in the same solve.
src = src.replace('edge-arm-bridge\nchromium\nqcom-firmware',
                  'edge-arm-bridge\nchromium\nqcom-firmware\nhexagon-dsp-binaries-arduino-monza\nqcom-fastrpc\nqcom-libdmabufheap\nqrtr-tools\nalsa-conf-qcom', 1)
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
# Stage the Monza device tree (stage 3): the compiled blob lands in
# the kernel's dtb directory under its upstream name, and the
# sources that produced it ship alongside for on-device reference.
# The blob is built from assets/dtb against the Azure kernel tree
# (see findings/ventunoq-arm-hardware-enablement.md); grub does not
# load it yet, the firmware-supplied tree stays authoritative
# until the Phase 1 census says otherwise.
anchor3 = 'install -m 0644 /workspace/assets/desktop/chromium-edge-synced.desktop /mnt/sysimage/usr/share/applications/chromium-edge-synced.desktop'
assert anchor3 in src, 'chromium desktop install line not found'
src = src.replace(anchor3, anchor3 + '''
install -D -m 0644 /workspace/assets/dtb/monaco-monza.dtb \\
    "$(echo /mnt/sysimage/usr/lib/modules/*/dtb/qcom)/monaco-monza.dtb"
install -D -m 0644 /workspace/assets/dtb/monaco-arduino-monza.dts \\
    /mnt/sysimage/usr/share/azl/monza-dt/monaco-arduino-monza.dts
install -m 0644 /workspace/assets/dtb/monaco-monza-som.dtsi \\
    /mnt/sysimage/usr/share/azl/monza-dt/monaco-monza-som.dtsi
install -m 0644 /workspace/assets/dtb/monaco-azl-supplement.dtsi \\
    /mnt/sysimage/usr/share/azl/monza-dt/monaco-azl-supplement.dtsi''')
# Neutralize the thirdparty fetch block in %post --nochroot
src = src.replace('''if [ ! -x /workspace/scripts/fetch-latest-thirdparty.sh ]; then
    echo "error: /workspace/scripts/fetch-latest-thirdparty.sh missing" >&2
    exit 1
fi
/workspace/scripts/fetch-latest-thirdparty.sh /mnt/sysimage/root/thirdparty''',
'''# ARM test build: thirdparty side-loads are x86_64 binaries; skipped.
mkdir -p /mnt/sysimage/root/thirdparty''')
# Neutralize the Copilot GUI install in the chrooted %post. The RPM
# is x86_64 only and the fetch above never stages it for ARM, so the
# install fails on the missing file. The checks after it exit the
# %post on failure (they are the PR #41 loud-failure fix, correct on
# x86_64), which silently dropped every later %post step out of the
# ARM RC image, the keyring helper install among them. Caught by
# the RC census against the final heads, 2026-11-09.
src = src.replace('''rpm -i --replacefiles --nosignature /root/thirdparty/github-copilot.rpm
# Fail loudly if the app did not land this time. These checks failed
# in that same verification build and the build still shipped,
# because a bare test in %post only logs; exit explicitly.
rpm -q github || { echo "error: GitHub Copilot GUI package did not install" >&2; exit 1; }
test -f "/usr/share/applications/GitHub Copilot.desktop" || { echo "error: GitHub Copilot.desktop missing after install" >&2; exit 1; }''',
'''# ARM build: the GitHub Copilot GUI ships x86_64 only; skipped.''')
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
assert re.search(r'(?m)^qcom-firmware$', src), 'qcom-firmware missing from %packages'
assert re.search(r'(?m)^repo --name=azl-base .*--excludepkgs=qcom-firmware,', src), 'azl-base still offers its own qcom-firmware'
assert re.search(r'(?m)^azurelinux-desktop-policy$', src), 'azurelinux-desktop-policy missing from %packages'
assert re.search(r'(?m)^hexagon-dsp-binaries-arduino-monza$', src), 'hexagon DSP package missing from %packages'
assert 'monaco-monza.dtb' in src, 'monza dtb staging missing'
for _rp in ['qcom-fastrpc', 'qcom-libdmabufheap', 'qrtr-tools', 'alsa-conf-qcom']:
    assert re.search(r'(?m)^' + _rp + r'$', src), _rp + ' missing from ARM %packages'
for _m in re.finditer(r'(?m)^repo --name=fedora45(?:-updates)? .*--excludepkgs=(\S+)', src):
    _names = _m.group(1).split(',')
    assert 'linux-firmware' not in _names and 'linux-firmware-whence' not in _names, 'firmware family still frozen for ARM'
assert 'fetch-latest-thirdparty.sh /mnt/sysimage' not in src, 'thirdparty fetch was not neutralized'
assert 'rpm -i --replacefiles --nosignature /root/thirdparty/github-copilot.rpm' not in src, 'Copilot GUI install survived generation'
assert 'GitHub Copilot GUI package did not install' not in src, 'Copilot GUI assertion survived generation'
p = pathlib.Path(sys.argv[2])
p.write_text(src)
print('arm ks written', len(src.split(chr(10))), 'lines')
for probe in ['fetch-latest-thirdparty.sh /mnt/sysimage','STAGE_FP=','grub2-efi-aa64-cdboot','shim-aa64','microsoft-edge-canary','azurelinux-desktop-policy','chromium-edge-synced.desktop','edge-arm-bridge']:
    print(probe, '->', src.count(probe))
