# Windows screenshot chord in GNOME

**Status:** Implemented. Host-tested. System dconf on live, disk,
installer target, and canary.

## Goal

`Win+Shift+S` opens the GNOME screenshot UI ready to capture, like
Windows Snipping Tool.

## Binding

Stock GNOME:

* `show-screenshot-ui` = `['Print']` only
* `Super+s` = Quick Settings
* `Super+Shift+s` was free

Product dconf (`assets/dconf/db/local.d/00-azl-desktop-defaults`):

```
[org/gnome/shell/keybindings]
show-screenshot-ui=['Print', '<Shift><Super>s']
```

Disk CI overlay `01-azl-desktop-favorites` mirrors the same key.

## Validation

* `validate-live-iso-filesystem.sh` / `validate-live-qcow2.sh`
* `verify-release-features.sh`
* `test-canary-container.sh` (dconf string + compiled key)
