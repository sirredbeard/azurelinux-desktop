#!/usr/bin/env python3
"""
Delta-based boot monitor for Azure Linux Desktop live ISO.

Takes a screenshot via QEMU monitor socket every INTERVAL seconds,
computes mean absolute pixel delta vs the previous saved frame, and
saves only frames that exceed THRESHOLD percent change. Exits after
DURATION seconds. Saved keyframes are named:

    key_<sequence>_<frame>.png

Usage:
    boot-monitor.py <monitor.sock> <output-dir> [interval] [threshold] [duration]

Defaults: interval=1.5s  threshold=3.0%  duration=240s

Notes:
- Requires: socat, Pillow (python3-pillow)
- QEMU must be launched with -monitor unix:<sock>,server,nowait
- The ⚠ CONSOLE TEXT flag triggers if >0.5% of the left strip has
  brightness >180 — catches dracut/kernel error lines immediately.
- The ⚠ CURSOR flag checks only rows 40-80 of the leftmost 12px to
  avoid false positives from the GNOME Activities pill button at (0,0).
"""

import sys
import os
import time
import subprocess
from PIL import Image, ImageChops


def screenshot(sock, path):
    cmd = f"screendump {path}\n"
    subprocess.run(
        ["socat", "-", f"UNIX-CONNECT:{sock}"],
        input=cmd, capture_output=True, text=True, timeout=5,
    )
    return os.path.exists(path)


def pixel_delta(a, b):
    """Mean absolute per-channel difference, 0-255 scale."""
    try:
        diff = ImageChops.difference(a.resize(b.size), b)
        px = list(diff.getdata())
        return sum(sum(p) / 3 for p in px) / len(px)
    except Exception:
        return 100.0


def classify(img):
    w, h = img.size

    def avg(x1, y1, x2, y2):
        px = list(img.crop((x1, y1, x2, y2)).getdata())
        return [sum(p[i] for p in px) / len(px) for i in range(3)]

    center = avg(w // 4, h // 3, 3 * w // 4, 2 * h // 3)
    top    = avg(0, 0, w, 35)
    br     = sum(center) / 3

    # Console text: bright pixels in left strip (rows 40+, below top bar)
    left = img.crop((0, 40, 200, h - 40))
    lpx  = list(left.getdata())
    bright_pct = sum(1 for p in lpx if sum(p) / 3 > 180) / len(lpx) * 100

    # Blinking text cursor: rows 40-80 of leftmost 12px only
    # (avoids the GNOME Activities pill which sits at the very top-left corner)
    cursor_zone = img.crop((0, 40, 12, 80))
    cpx = list(cursor_zone.getdata())
    cursor = sum(1 for p in cpx if p[0] > 200 and p[1] > 200 and p[2] > 200) > 8

    flags = ""
    if bright_pct > 0.5:
        flags += f"  ⚠ CONSOLE TEXT ({bright_pct:.1f}%)"
    if cursor:
        flags += "  ⚠ CURSOR"

    if br < 5:
        return f"BLACK{flags}"

    logo = avg(w // 2 - 120, h // 2 - 120, w // 2 + 120, h // 2 + 120)
    logo_br = sum(logo) / 3
    if br < 30 and logo_br > 25:
        return f"PLYMOUTH logo_br={logo_br:.0f}{flags}"
    if br < 30:
        return f"DARK br={br:.0f}{flags}"
    if sum(top) / 3 > 100:
        return f"GNOME/GDM active{flags}"

    r, g, b = center
    return f"MID br={br:.0f} c=({r:.0f},{g:.0f},{b:.0f}){flags}"


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    sock      = sys.argv[1]
    outdir    = sys.argv[2]
    interval  = float(sys.argv[3]) if len(sys.argv) > 3 else 1.5
    threshold = float(sys.argv[4]) if len(sys.argv) > 4 else 3.0
    duration  = int(sys.argv[5])   if len(sys.argv) > 5 else 240

    os.makedirs(outdir, exist_ok=True)
    prev   = None
    saved  = 0
    n      = 0
    start  = time.time()

    print(f"Boot monitor: interval={interval}s  threshold={threshold}%  duration={duration}s")
    print(f"Output: {outdir}")
    print("-" * 60)
    sys.stdout.flush()

    while time.time() - start < duration:
        elapsed = time.time() - start
        ppm = os.path.join(outdir, f"f{n:04d}.ppm")

        if screenshot(sock, ppm):
            img   = Image.open(ppm).convert("RGB")
            d     = pixel_delta(prev, img) if prev is not None else 100.0
            state = classify(img)
            ts    = f"{elapsed:6.1f}s"

            if d >= threshold or prev is None:
                png = os.path.join(outdir, f"key_{saved:03d}_{n:04d}.png")
                img.save(png)
                saved += 1
                print(f"[{ts}] SAVE  d={d:5.1f}  {state}")
                prev = img
            else:
                print(f"[{ts}] skip  d={d:5.1f}  {state}")

            os.remove(ppm)

        sys.stdout.flush()
        n += 1
        time.sleep(interval)

    print("-" * 60)
    print(f"Done. {saved} keyframes saved to {outdir}")


if __name__ == "__main__":
    main()
