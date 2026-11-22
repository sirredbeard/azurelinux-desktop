# Installed systems do not follow repo channel moves

On November 22, 2026, a ThinkPad installed from the 2026.11.16
installer ran `dnf upgrade` after the Azure Linux 4 GA migration
(PR #60) and the kmods republish that followed it. The upgrade
reported 29 problems of one shape, then skipped the whole desktop
package set:

```
Problem 1: cannot install the best update candidate for package
azurelinux-desktop-sound-kmod-6.18.62-1.1.azl4.x86_64
 - nothing provides kernel-core-uname-r = 6.18.62-1.1.azl4.x86_64
   needed by azurelinux-desktop-sound-kmod-6.18.62-1.1.azl4.x86_64
Skipping packages with broken dependencies:
azurelinux-desktop-policy  x86_64  6.18.62-1.1.azl4  azl-desktop-kmods
```

The machine still carried the repo files it was installed with.
The beta build of azurelinux-repos (4.0-17) writes its baseurls as
packages.microsoft.com/azurelinux/$releasever/beta, with the dnf
variable $releasever standing in for the version. On an Azure
Linux 4 system that resolves to 4.0/beta, and the beta tree froze
at kernel 6.18.31 when GA shipped. The kmods repo is ours, and it
moved to kernel 6.18.62 with the GA publish. Kmod packages require
the exact kernel through kernel-core-uname-r, so the solver skipped
all 28 kmods. azurelinux-desktop-policy requires the same kernel,
so the solver skipped the policy too, and with it every fix the
policy carries. On this machine that included the RPM Fusion
updates repos from the ffmpeg/openapv fix, so that older problem
stayed in place as well.

PR #60 changed the URLs the images build from. Nothing in this repo
changes the repo files on a system that is already installed, and
the frozen beta tree will never ship an updated azurelinux-repos to
do it. An installed system cannot follow a channel move on its own.

## What fixed the test machine

Repoint the repo files by hand, then upgrade twice. The pattern
has to match the $releasever form the vendor package writes. A
first attempt searched for the literal azurelinux/4.0/beta string,
matched no file on the machine, and changed nothing:

```
sudo grep -rl 'releasever/beta' /etc/yum.repos.d/ | xargs sudo sed -i 's|azurelinux/\$releasever/beta|azurelinux/4/prod|g'
sudo dnf upgrade -y --refresh
sudo dnf upgrade -y --refresh
```

The second run is not a typo. The first run installs the kernel,
the kmods, and the policy, and the policy installs the RPM Fusion
updates repo file during that run. dnf only sees the new repo file
on the next run, which is where ffmpeg-libs and openapv-libs
resolve.

Verified in an x86_64 installroot that mirrors the installed
machine's repo state (beta Azure repos, the GitHub Pages kmods
repo, kernel and policy at 6.18.31): the upgrade reproduced the
same 29 kernel-core-uname-r problems. After the repoint the upgrade
resolved with zero problems and installed kernel 6.18.62, policy
6.18.62, and 28 kmods at 6.18.62, and the policy landed
azl-desktop-rpmfusion.repo with both updates sections present.
The installroot's repo files carried the literal URL form, so that
test verified the solver behavior. The shipped file contents were
checked separately, against the azurelinux-repos RPM in the beta
tree, which is where the $releasever form came to light.

## Planned migration path

The manual repoint fixes one machine at a time. The installed base
needs a package that carries the new URLs to it, and the policy
package cannot be that package: its kernel requirement is the very
thing a wedged system cannot meet, so dnf skips the fix along with
everything else.

Plan:

- Add a small migration package, working name
  azurelinux-desktop-repo-migration, published to the
  azl-desktop-kmods repo next to the policy. It requires nothing
  beyond /bin/sh and sed, so dnf can install it on a system whose
  kernel is far behind the kmods repo. Nothing kernel-coupled may
  sit in its requirement chain, or it wedges with everything else.
- Discovery is not the problem. The repo file that configures
  azl-desktop-kmods points at the GitHub Pages URL, which does not
  change with the Azure channel. That is how the wedged ThinkPad
  saw the 6.18.62 packages at all: the kmods repo reached it fine,
  the Azure base repo did not move.
- A wedged system takes the package with one command,
  `sudo dnf install azurelinux-desktop-repo-migration`. No solver
  path installs a new standalone package on its own, so the doc
  does not pretend otherwise. Systems that are not wedged pick the
  package up without being asked: the policy gains a Requires on
  it, so the migration lands with a normal policy update ahead of
  any future channel move.
- Its %post rewrites the old channel string to the new one in every
  file under /etc/yum.repos.d that contains it, whichever package
  owns the file, %config(noreplace) files included. The rewrite
  pair has to cover the $releasever form the vendor package writes,
  not only the literal form, or it repeats the failed first attempt
  above. Once no file
  matches, the scriptlet is a no-op and the package can stay
  installed or be removed by hand. The rewrite is safe to re-run:
  if a %post ever stops halfway, the files sit in a mixed state
  that the manual repoint above, or a reinstall of the package,
  puts right.
- Build and publish it in publish-desktop-kmods.yml alongside the
  policy, for x86_64 and aarch64. Version each build by date with
  an incrementing release, so a later channel move ships a new
  build with a new rewrite pair and dnf always takes the newest.
- Ship order matters: publish the migration package first and let
  it sit for one weekly release cycle before the kmods kernel
  moves to the new channel's kernel. Moving the kernel first is
  what wedged the test machine.
- Test it the way this failure was tested: in an installroot
  pinned to the old channel, install the old kernel and policy,
  run an upgrade and count the kernel-core-uname-r problems, then
  install the migration package and run the upgrade again. The
  second run must report zero problems and land the new kernel,
  the new policy, and the new kmods.
- Keep the manual repoint above as the fallback for any machine
  that needs help before the package reaches it.

The same path covers the next channel move, whatever it is: a new
prod tree, an Azure Linux 5 tree, or a signing key change that
ships in repo files. The rule from here on is that a channel move
does not ship in image config alone.

Lesson: changing the repo URLs in the image build only changes new
installs. Systems in the field keep the repo files they were
installed with, and a frozen channel never delivers its own fix. A
channel move is not done until a package the installed base can
install carries the new URLs to it, and the kmods kernel does not
move until that package has had time to land.
