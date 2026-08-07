# .NET launcher missing and CLI first-run noise

**Status:** Resolved (launcher). First-run workload warning mitigated /
documented; capture exact CLI stderr on a fresh image if it reappears.

## Observed failure

1. No `.NET` icon in GNOME overview or dock.
2. Running `dotnet` showed first-run banners and a yellow workload
   verification warning, sometimes followed by a vague
   "specified command or file was not found" style failure.

## Missing .NET icon

### Root cause

`assets/desktop/dotnet.desktop` used an invalid `Exec` line:

```ini
Exec=gnome-terminal --title=".NET" -- /bin/sh -c 'dotnet --info; exec $SHELL'
```

Desktop Entry Specification violations:

- Single quotes are not legal quoting (only double quotes).
- Semicolon is reserved.
- `$SHELL` is not expanded in bare `Exec` values.

`desktop-file-validate` rejected the entry. GNOME Shell omits invalid
desktop files from application discovery.

### Resolution

Helper script pattern (same shape as PowerShell):

`assets/bin/azl-dotnet-terminal`:

```sh
#!/bin/sh
exec gnome-terminal --title=".NET" -- sh -c 'dotnet --info; exec "${SHELL:-/bin/bash}"'
```

`assets/desktop/dotnet.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=.NET
Comment=Check the installed .NET SDK/runtime versions
Exec=/usr/local/bin/azl-dotnet-terminal
Icon=/usr/share/pixmaps/dotnet.svg
Terminal=false
Categories=Development;
StartupNotify=true
```

Staged from live and installer kickstarts with `install -m 0755` /
`install -m 0644`.

### Verification

- `desktop-file-validate assets/desktop/dotnet.desktop` passes.
- Filesystem: helper and desktop entry present on live ISO/qcow2.
- Interactive: `.NET` appears in GNOME search with the correct icon.

## First-run noise and workload verification

### What first-run does

From `dotnet/sdk` first-run sources:

1. Missing `FirstTimeUseNoticeSentinel` under `~/.dotnet/` → first run.
2. Welcome/telemetry banner (suppressed by `DOTNET_NOLOGO=true`).
3. NuGet state migration.
4. ASP.NET dev cert generation (suppressed by
   `DOTNET_GENERATE_ASPNET_CERTIFICATE=false`).
5. Global tools PATH sentinel (`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=false`).
6. Workload integrity check (suppressed by
   `DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=true`).

The yellow message is the workload integrity check error. The exception
is swallowed; the CLI continues.

### Why the integrity check fails here

The checker resolves the SDK feature band and looks for install records
under `/usr/share/dotnet/metadata/workloads/<band>/`. Preview manifest
trees can both be present under `/usr/share/dotnet/sdk-manifests/`. If
records exist, the checker tries to reinstall packs from NuGet feeds that
may not match the offline/image feed layout. That throws, gets caught,
and prints the yellow warning.

On Linux, workload signature verification is compile-time disabled, so
this is package resolution, not signing.

### Useful environment variables

- `DOTNET_NOLOGO`: suppress welcome/telemetry banner
- `DOTNET_SKIP_FIRST_TIME_EXPERIENCE`: deprecated; do not use
- `DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK`: skip integrity repair
- `DOTNET_GENERATE_ASPNET_CERTIFICATE`: dev-cert generation
- `DOTNET_CLI_TELEMETRY_OPTOUT`: telemetry opt-out
- `DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE`: background manifest
  updates
- `SuppressNETCoreSdkPreviewMessage`: preview banner

### Remediation options researched

1. System-wide `/etc/profile.d/dotnet-firstrun.sh` exporting the
   suppression variables above.
2. Remove stale preview manifest trees and workload records during
   `%post`.
3. Pre-seed first-run sentinels under `/etc/skel/.dotnet/`
   (version-string sensitive).
4. Optional `dotnet workload update` during install against the offline
   repo (may fail offline; non-fatal).

The launcher-format fix is what unblocked GNOME discovery. First-run
noise is handled by image configuration as needed. If the "file was not
found" path returns:

```bash
DOTNET_HOST_TRACE=1 DOTNET_HOST_TRACEFILE=$HOME/host_trace.txt \
  dotnet --info 2>&1 | tee $HOME/dotnet-info.txt
dotnet workload list 2>&1 | tee $HOME/dotnet-workload-list.txt
ls /usr/share/dotnet/sdk-manifests/
ls /usr/share/dotnet/metadata/workloads/ 2>/dev/null || echo "(no workload metadata)"
```

Keep traces under the work tree or home, not under `/tmp` in automated
agent sessions.

## Changed files

- `assets/desktop/dotnet.desktop`
- `assets/bin/azl-dotnet-terminal`
- live and installer kickstart staging blocks

## References

- Desktop Entry Spec §6.6
- Related: `powershell-dock-identity.md`, `gnome-desktop-defaults.md`
