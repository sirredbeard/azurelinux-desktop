# Screenshot app mixed light/dark chrome

**Status:** Fixed and shipped. Live, installer, and canary list
`gnome-themes-extra`. Metal: Screenshot consistent dark after install.
Text Editor, Characters, Calculator, Software, Nautilus dark. Evolution
may flash mixed chrome briefly then go fully dark (GTK3 + WebKit
startup, not missing theme files).

## Symptom

GNOME Screenshot (`gnome-screenshot`) in a dark session shows split
theming. Header and Capture Area tiles stay light gray. Lower rows
(Show Pointer, Delay) follow dark style. Looks broken even though
Settings says Dark.

## Cause

1. System dconf defaults set both:
   - `org.gnome.desktop.interface color-scheme = 'prefer-dark'`
     (libadwaita / GTK4)
   - `org.gnome.desktop.interface gtk-theme = 'Adwaita-dark'` (GTK3)
2. `gnome-screenshot` is GTK3 + libhandy, not libadwaita.
3. `gnome-themes-extra` was not installed, so `/usr/share/themes/` had
   no `Adwaita` / `Adwaita-dark` directories.
4. GTK3 then partially falls back. Some widgets pick dark from
   `prefer-dark` / libhandy. Others stay light Adwaita defaults.

libadwaita apps looked fine because they ignore the old `gtk-theme`
name and use `color-scheme` only.

## Fix

Install `gnome-themes-extra` (pulls theme CSS; may pull
`highcontrast-icon-theme`).

```
/usr/share/themes/Adwaita
/usr/share/themes/Adwaita-dark
```

Restart Screenshot (or log out/in). Metal verified package install
creates those dirs while dconf already had `Adwaita-dark` + `prefer-dark`.

## Product wiring

- Live: `%packages`: `gnome-themes-extra`
- Installer: `kiwi/config.sh` TARGET_PKGS
- Canary: PKGS (dconf also sets Adwaita-dark)

Keep both dconf keys: `prefer-dark` for modern apps, `Adwaita-dark` for
remaining GTK3 (Screenshot, some indicators).

## Evolution brief flash

Evolution is GTK3 + WebKitGTK. With `gnome-themes-extra` installed it
settles on dark. A short mixed frame at launch is WebKit/UI init, not
the missing-theme bug. No extra package required beyond themes-extra.

## Not the same bug as emoji tofu

Color emoji is separate (`missing-color-emoji-fonts.md`). This is pure
GTK3 theme files missing.
