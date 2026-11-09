# Generate the ARM64 variant of the live kickstart: aarch64 repo URLs
# and EFI packages, x86_64-only packages dropped, and the %post blocks
# that side-load x86_64 binaries (thirdparty fetch, Copilot Flatpak
# prestage) neutralized. Usage: make-arm-ks.py <in.ks> <out.ks>
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
# Neutralize the thirdparty fetch block in %post --nochroot
src = src.replace('''if [ ! -x /workspace/scripts/fetch-latest-thirdparty.sh ]; then
    echo "error: /workspace/scripts/fetch-latest-thirdparty.sh missing" >&2
    exit 1
fi
/workspace/scripts/fetch-latest-thirdparty.sh /mnt/sysimage/root/thirdparty''',
'''# ARM test build: thirdparty side-loads are x86_64 binaries; skipped.
mkdir -p /mnt/sysimage/root/thirdparty''')
# Neutralize the flatpak prestage block
src = re.sub(r'STAGE_FP=/workspace/prestage/flatpak-system\nif \[ ! -f.*?test -d /mnt/sysimage/var/lib/flatpak/appstream/flathub/x86_64/active/icons\n',
'# ARM test build: Copilot Flatpak prestage skipped (x86_64 app).\n', src, flags=re.S)
p = pathlib.Path(sys.argv[2])
p.write_text(src)
print('arm ks written', len(src.split(chr(10))), 'lines')
for probe in ['fetch-latest-thirdparty.sh /mnt/sysimage','STAGE_FP=','grub2-efi-aa64-cdboot','shim-aa64','microsoft-edge-canary','azurelinux-desktop-policy']:
    print(probe, '->', src.count(probe))
