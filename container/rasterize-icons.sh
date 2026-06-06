#!/bin/bash
# Fedora 43 dropped the librsvg gdk-pixbuf loader; SVG decode now routes
# through glycin, whose bubblewrap sandbox cannot start inside the container
# (no unprivileged user namespaces). Every SVG icon renders as a missing
# placeholder and some GTK apps crash hunting for one. Sidestep the decoder
# entirely: rasterize every theme SVG to PNG with rsvg-convert (plain
# librsvg, no sandbox), mirror the symlink farm, and rebuild the caches.
set -u

# Pass 0: git on Windows (core.symlinks=false) checks out symlinks as plain
# text files holding the target path, and the staged Bluecurve trees carry
# thousands of them. A path-only file with no newline is one of those;
# recreate the real symlink. Run before rasterizing so .svg pseudo-links
# get re-pointed by the symlink pass below like any other link.
find /usr/share/icons /usr/share/themes /usr/share/pixmaps /usr/share/fonts /usr/share/backgrounds \
     -type f -size -300c 2>/dev/null | while read -r f; do
  if LC_ALL=C grep -qE '^[A-Za-z0-9@._+/-]+$' "$f" && [ "$(wc -l < "$f")" -eq 0 ]; then
    ln -sf "$(cat "$f")" "$f"
  fi
done

# Real files first: size from the path's NNN or NNNxNNN component, 96 for
# scalable directories.
find /usr/share/icons /usr/share/pixmaps -type f -name '*.svg' -print0 \
  | xargs -0 -r -P "$(nproc)" -n 64 bash -c 'for f; do
      sz=$(printf "%s\n" "$f" | sed -n "s|.*/\([0-9]\{1,\}\)\(x[0-9]\{1,\}\)\{0,1\}/.*|\1|p")
      rsvg-convert -w "${sz:-96}" -h "${sz:-96}" "$f" -o "${f%.svg}.png" 2>/dev/null && rm -f "$f"
    done' _

# Icon themes alias heavily through symlinks; re-point each at the converted
# name, then drop any that ended up dangling.
find /usr/share/icons /usr/share/pixmaps -type l -name '*.svg' | while read -r l; do
  t=$(readlink "$l")
  ln -sf "${t%.svg}.png" "${l%.svg}.png"
  rm -f "$l"
done
find /usr/share/icons /usr/share/pixmaps -xtype l -name '*.png' -delete

for d in /usr/share/icons/*/; do
  if [ -f "$d/index.theme" ]; then
    gtk-update-icon-cache -f -q "$d" || true
  fi
done

echo "rasterize-icons: done, $(find /usr/share/icons -name '*.svg' | wc -l) svg left"
