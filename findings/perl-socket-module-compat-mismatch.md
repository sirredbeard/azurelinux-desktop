# perl-Socket can outrun the Azure Linux Perl ABI

**Status:** Fixed in package policy. Image rebuild still required.

The bare-metal RPM survey found one broken dependency in 1,473 installed
RPMs. Flatpaks were counted separately and were not part of the survey:

```
$ dnf check
perl-Socket-4:2.043-1.fc43.x86_64
 missing require "perl(:MODULE_COMPAT_5.42.3)"
Check discovered 1 problem(s) in 1 package(s)
```

The system had Azure Linux `perl-libs` 5.42.2 and Fedora
`perl-Socket` 2.043. Fedora built that Socket package against Perl
5.42.3:

```
$ rpm -q perl-libs perl-Socket
perl-libs-5.42.2-525.azl4.x86_64
perl-Socket-2.043-1.fc43.x86_64

$ rpm -q --requires perl-Socket | grep MODULE_COMPAT
perl(:MODULE_COMPAT_5.42.3)
```

The full installed RPM check found one other Fedora Perl package with a
compiled module requirement. `perl-Data-Dumper` requires
`perl(:MODULE_COMPAT_5.42.2)`, which the Azure Linux runtime provides.
`dnf check` reported no other broken package.

Azure Linux provides `perl-Socket` 2.040 built for its 5.42.2 Perl
ABI. Fedora's newer package won because the Fedora claw-back list kept
the Perl interpreter and core libraries on Azure Linux, but did not
include this compiled core module.

Added `perl-Socket` to `FEDORA_EXCLUDES` in the live kickstart,
installer download path, installed-system repo asset, and canary repo
asset. New images resolve the Azure Linux build with the matching ABI.
The existing machine can be repaired with:

```
sudo dnf downgrade perl-Socket
sudo dnf check
```
