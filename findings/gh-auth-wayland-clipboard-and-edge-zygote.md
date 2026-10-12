# GitHub CLI auth clipboard and Edge zygote noise

**Status:** clipboard fix implemented, image rebuild pending; Edge message confirmed harmless upstream noise

## Symptoms

On the default GNOME Wayland desktop, `gh auth login` printed:

```text
Failed to copy one-time code to clipboard
No clipboard utilities available. Please install xsel, xclip, wl-clipboard or Termux:API add-on for termux-clipboard-get/set.
```

Opening the device login page in an existing Edge Canary session also printed:

```text
Opening in existing browser session.
ERROR:content/zygote/zygote_linux.cc:662] write: Broken pipe (32)
ERROR:content/zygote/zygote_main_linux.cc:197] Failed sending zygote boot message: Broken pipe (32)
```

Authentication still completed.

## Clipboard root cause and fix

GitHub CLI uses `github.com/atotto/clipboard`. On Linux, that library checks
`WAYLAND_DISPLAY`, then looks for both `wl-copy` and `wl-paste`. Those commands
come from Fedora's `wl-clipboard` package.

`xclip` and `xsel` use the X11 clipboard. They are not the right default for
this GNOME Wayland image.

Add `wl-clipboard` to:

- `kickstart/azurelinux-desktop-live.ks`
- `kiwi/config.sh`

The package comes from the existing Fedora fallback repository. The canary
does not get it because the canary has no Wayland session or desktop runtime.

## Edge broken pipe

The Edge lines reproduce with plain `xdg-open`, without GitHub CLI:

```text
$ XDG_UTILS_DEBUG_LEVEL=2 xdg-open https://github.com/login/device
Selected DE gnome3
Opening in existing browser session.
ERROR:content/zygote/zygote_linux.cc:662] write: Broken pipe (32)
ERROR:content/zygote/zygote_main_linux.cc:197] Failed sending zygote boot message: Broken pipe (32)
```

`xdg-open` exits with status 0 and the existing browser opens the URL.

Chromium's `content/zygote/zygote_main_linux.cc` explains this exact path:
the browser process can quickly exit while the zygote starts, so failure to
send the zygote boot message is logged instead of treated as a fatal check.
Edge starts a short-lived process, hands the URL to the existing browser
session, and exits while that helper is still starting.

This is noisy, but it is not an authentication, browser, sandbox, or image
failure. Do not redirect browser or `gh` stderr to hide it. The same stream
reports real browser launch failures.

## Verification

The affected session was Wayland:

```text
XDG_SESSION_TYPE=wayland
WAYLAND_DISPLAY=wayland-0
```

Fedora's configured repository resolves:

```text
wl-clipboard 2.2.1-5.fc43 fedora43
```

After an image rebuild, verify:

```bash
command -v wl-copy
command -v wl-paste
printf test | wl-copy
test "$(wl-paste)" = test
gh auth login
```
