# Screenshot app mixed light/dark chrome

**Status:** Diagnosed and fixed on metal 2026-08-06. Product ships
`gnome-themes-extra` so `gtk-theme='Adwaita-dark'` resolves.

## Symptom

GNOME Screenshot (`gnome-screenshot`) in a dark session shows **split
theming**: header / “Capture Area” tiles stay light gray; lower rows
(“Show Pointer”, “Delay”) follow dark style. Looks broken even though
Settings says Dark.

## Cause

1. System dconf defaults set both:
   * `org.gnome.desktop.interface color-scheme = 'prefer-dark'` (libadwaita / GTK4)
   * `org.gnome.desktop.interface gtk-theme = 'Adwaita-dark'` (GTK3)
2. **`gnome-screenshot` is GTK3 + libhandy**, not libadwaita.
3. **`gnome-themes-extra` was not installed**, so `/usr/share/themes/`
   had no `Adwaita` / `Adwaita-dark` directories (only Default, Emacs).
4. GTK3 then partially falls back: some widgets pick dark from
   `prefer-dark` / libhandy, others stay light Adwaita defaults → mixed UI.

libadwaita apps (most of GNOME 49) looked fine because they ignore the
old `gtk-theme` name and use `color-scheme` only.

## Fix

Install **`gnome-themes-extra`** (pulls theme CSS; may pull
`highcontrast-icon-theme`).

```
/usr/share/themes/Adwaita
/usr/share/themes/Adwaita-dark
```

Restart Screenshot (or log out/in). Metal verified package install
creates those dirs while dconf already had `Adwaita-dark` + `prefer-dark`.

## Product wiring

| Path | Change |
| --- | --- |
| Live | `%packages`: `gnome-themes-extra` |
| Installer | `kiwi/config.sh` TARGET_PKGS |
| Canary | PKGS (dconf also sets Adwaita-dark) |

Keep both dconf keys: `prefer-dark` for modern apps, `Adwaita-dark` for
remaining GTK3 (Screenshot, some indicators).

## Not the same bug as emoji tofu

Color emoji is separate (`missing-color-emoji-fonts.md`). This is pure
GTK3 theme files missing.
