#!/usr/bin/env bash
# Compare a live-session screenshot against candidate GNOME wallpapers inside a
# live ISO using local, on-device numeric image analysis.
set -euo pipefail

LIVE_ISO="${1:?usage: $0 /path/to/live.iso /path/to/screenshot.png [output_report.txt]}"
SCREENSHOT="${2:?usage: $0 /path/to/live.iso /path/to/screenshot.png [output_report.txt]}"
OUT="${3:-}"

if [ ! -f "$LIVE_ISO" ]; then
    echo "error: live ISO not found: $LIVE_ISO" >&2
    exit 1
fi
if [ ! -f "$SCREENSHOT" ]; then
    echo "error: screenshot not found: $SCREENSHOT" >&2
    exit 1
fi

WORKROOT="${AZL_QEMU_WORKDIR:-$HOME/azl-work}"
WORK="$WORKROOT/wallpaper-analysis-$(date +%Y%m%d-%H%M%S)"
ISO_MNT="$WORK/iso"
SQ_MNT="$WORK/sq"
mkdir -p "$ISO_MNT" "$SQ_MNT" "$WORK"

cleanup() {
    set +e
    mountpoint -q "$SQ_MNT" && sudo umount "$SQ_MNT"
    mountpoint -q "$ISO_MNT" && sudo umount "$ISO_MNT"
}
trap cleanup EXIT

sudo mount -o loop "$LIVE_ISO" "$ISO_MNT"
sudo mount -o loop "$ISO_MNT/LiveOS/squashfs.img" "$SQ_MNT"

DARK_JXL="$SQ_MNT/usr/share/backgrounds/gnome/adwaita-d.jxl"
LIGHT_JXL="$SQ_MNT/usr/share/backgrounds/gnome/adwaita-l.jxl"
DARK_PNG="$WORK/adwaita-d.png"
LIGHT_PNG="$WORK/adwaita-l.png"

magick "$DARK_JXL" "$DARK_PNG"
magick "$LIGHT_JXL" "$LIGHT_PNG"

python3 - "$SCREENSHOT" "$DARK_PNG" "$LIGHT_PNG" "$OUT" <<'PY'
import json
import sys
from pathlib import Path
from PIL import Image, ImageOps
import statistics

shot_path = Path(sys.argv[1])
dark_path = Path(sys.argv[2])
light_path = Path(sys.argv[3])
out_path = Path(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else None

shot = Image.open(shot_path).convert("L")
w, h = shot.size

patches = [
    (0.10, 0.15, 0.30, 0.35),
    (0.35, 0.20, 0.55, 0.40),
    (0.60, 0.18, 0.82, 0.38),
    (0.20, 0.52, 0.40, 0.74),
    (0.58, 0.54, 0.80, 0.76),
]

def patch_metrics(a, b):
    va = list(a.getdata())
    vb = list(b.getdata())
    mean_a = statistics.fmean(va)
    mean_b = statistics.fmean(vb)
    std_a = statistics.pstdev(va)
    std_b = statistics.pstdev(vb)
    if std_a < 1e-9 or std_b < 1e-9:
        corr = 0.0
    else:
        cov = statistics.fmean((x - mean_a) * (y - mean_b) for x, y in zip(va, vb))
        corr = cov / (std_a * std_b)
    mae = statistics.fmean(abs(x - y) for x, y in zip(va, vb))
    return corr, mae

def score_candidate(name, path):
    cand = Image.open(path).convert("L")
    fit = ImageOps.fit(cand, (w, h), method=Image.Resampling.LANCZOS, centering=(0.5, 0.5))

    patch_rows = []
    for idx, (x1f, y1f, x2f, y2f) in enumerate(patches, start=1):
        x1, y1 = int(x1f * w), int(y1f * h)
        x2, y2 = int(x2f * w), int(y2f * h)
        sa = shot.crop((x1, y1, x2, y2))
        sb = fit.crop((x1, y1, x2, y2))
        corr, mae = patch_metrics(sa, sb)
        patch_rows.append({"patch": idx, "corr": corr, "mae": mae})

    corr_mean = statistics.fmean([r["corr"] for r in patch_rows])
    mae_mean = statistics.fmean([r["mae"] for r in patch_rows])
    # Higher is better; penalize absolute error.
    score = corr_mean - (mae_mean / 255.0)
    return {
        "candidate": name,
        "corr_mean": corr_mean,
        "mae_mean": mae_mean,
        "score": score,
        "patches": patch_rows,
    }

results = [
    score_candidate("adwaita-d.jxl", dark_path),
    score_candidate("adwaita-l.jxl", light_path),
]
results.sort(key=lambda x: x["score"], reverse=True)

report = {
    "screenshot": str(shot_path),
    "resolution": [w, h],
    "winner": results[0]["candidate"],
    "results": results,
}

text = json.dumps(report, indent=2)
print(text)
if out_path:
    out_path.write_text(text + "\n", encoding="utf-8")
PY
