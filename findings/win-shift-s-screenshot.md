# Windows screenshot and emoji chords in GNOME

**Status:** Implemented. Host-tested. Shared system dconf + Flatpak
prestage cover live, disk, installer target, and canary.

## Goal

Match common Windows desktop habits:

* `Win+Shift+S` opens screenshot UI ready to capture (Snipping Tool)
* `Win+.` and `Win+;` open a popup emoji picker

## Screenshot

Stock GNOME:

* `show-screenshot-ui` = `['Print']` only
* `Super+s` = Quick Settings
* `Alt+Super+s` = screen reader
* `Super+Shift+s` was free

Product dconf:

```
[org/gnome/shell/keybindings]
show-screenshot-ui=['Print', '<Shift><Super>s']
```

Host: `gsettings set` accepted the binding. Manual `Win+Shift+S`
confirmed.

## Emoji (Emote)

Closest Flatpak to the Windows emoji panel is
[Emote](https://github.com/tom-james-watson/Emote)
(`com.tomjwatson.Emote` on Flathub). IBus `Super+period` only fires
with a focused IBus text context. Emote is a global popup.

Product dconf:

```
[org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1]
name='Emoji panel'
command='flatpak run com.tomjwatson.Emote'
binding='<Super>period'

[org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom2]
name='Emoji panel'
command='flatpak run com.tomjwatson.Emote'
binding='<Super>semicolon'

[org/freedesktop/ibus/panel/emoji]
hotkey=@as []
```

Host: `flatpak run com.tomjwatson.Emote` opens the picker. gsettings
custom1/custom2 accepted Super+period and Super+semicolon.

## Flatpak preseed

`scripts/install-copilot-desktop-flatpak.sh` now installs both:

* `com.github.sirredbeard.copilot-desktop-gtk` (Pages)
* `com.tomjwatson.Emote` (Flathub)

Same `org.gnome.Platform//50` runtime. `prestage-copilot-flatpak-system.sh`
asserts both app dirs and exported `.desktop` files. Live kickstart,
installer `azl-install.ks.in`, and canary Dockerfile fail closed if Emote
is missing from the staged `/var/lib/flatpak` tree.

## Carried on every path

* Live / disk: kickstart copies prestaged flatpak tree + installs
  `00-azl-desktop-defaults`
* Disk CI overlay `01-azl-desktop-favorites` mirrors the same bindings
* Installer target: kiwi product ks copies the same tree and dconf asset
* Canary: Dockerfile runs the install helper and asserts both apps

## Validation

* `validate-live-iso-filesystem.sh` / `validate-live-qcow2.sh`
* `verify-release-features.sh`
* `test-canary-container.sh` (dconf strings + `flatpak info` Emote)
