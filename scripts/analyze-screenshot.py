#!/usr/bin/env python3
"""
Screenshot analyzer for Azure Linux Desktop boot validation.
Classifies a screenshot and reports what boot stage it likely shows.
Used by validate-boot-behavior.sh at each checkpoint.

Usage: analyze-screenshot.py <image-path> [label]

Prints a one-line classification and supporting metrics.
Exit 0 always - caller decides whether to fail based on content.
"""
import sys
import os
from pathlib import Path

try:
    from PIL import Image, ImageStat
    import colorsys
except ImportError:
    print("    PIL not available - install python3-pillow for image analysis")
    sys.exit(0)

def dominant_colors(img, n=8):
    """Get n most common colors by quantizing to a small palette."""
    small = img.resize((64, 64)).convert("RGB")
    quantized = small.quantize(colors=n, method=Image.Quantize.FASTOCTREE)
    palette = quantized.getpalette()[:n*3]
    colors = [(palette[i], palette[i+1], palette[i+2]) for i in range(0, n*3, 3)]
    return colors

def brightness(img):
    """Mean brightness 0-255."""
    gray = img.convert("L")
    return ImageStat.Stat(gray).mean[0]

def color_variance(img):
    """How colorful is the image - high = more varied colors."""
    stat = ImageStat.Stat(img.convert("RGB"))
    return sum(stat.stddev)

def text_density(img):
    """
    Rough estimate of text-like content. Text creates many sharp
    horizontal transitions (light->dark->light). Count them.
    """
    gray = img.convert("L").resize((320, 240))
    pixels = list(gray.getdata())
    width = 320
    transitions = 0
    threshold = 60
    for row in range(240):
        for col in range(1, width):
            diff = abs(pixels[row * width + col] - pixels[row * width + col - 1])
            if diff > threshold:
                transitions += 1
    return transitions / (320 * 240)

def has_top_bar(img):
    """
    Check for GNOME top bar - a mostly-dark horizontal band at the top.
    The GNOME top bar is approximately 32px high.
    """
    w, h = img.size
    if h < 100:
        return False
    top_strip = img.crop((0, 0, w, min(40, h))).convert("L")
    mean_brightness = ImageStat.Stat(top_strip).mean[0]
    return mean_brightness < 60  # dark band

def classify(img_path):
    try:
        img = Image.open(img_path).convert("RGB")
    except Exception as e:
        return f"ERROR opening image: {e}", {}

    w, h = img.size
    br = brightness(img)
    cv = color_variance(img)
    td = text_density(img)
    top_bar = has_top_bar(img)
    colors = dominant_colors(img)

    metrics = {
        "size": f"{w}x{h}",
        "brightness": round(br, 1),
        "color_variance": round(cv, 1),
        "text_density": round(td, 4),
        "top_dark_bar": top_bar,
    }

    # Black screen - nothing rendered yet or display off
    if br < 8:
        return "BLACK_SCREEN (boot not started or display off)", metrics

    # Mostly black with low variance - early boot text or error
    if br < 30 and cv < 30:
        return "DARK_TEXT_MODE (early boot, BIOS, or text console)", metrics

    # High text density + dark background = text mode (Plymouth text, terminal)
    if td > 0.04 and br < 80:
        return "TEXT_MODE (Plymouth text/details fallback or console)", metrics

    # Has GNOME top bar + reasonable brightness = GNOME session
    if top_bar and br > 40 and cv > 20:
        return "GNOME_SESSION (top bar detected - GNOME appears to be running)", metrics

    # Moderate brightness, low text density, some color = graphical (Plymouth or GRUB graphical)
    if br > 20 and td < 0.03 and cv > 15:
        if br < 100:
            return "GRAPHICAL_BOOT (Plymouth logo or GRUB graphical menu likely)", metrics
        else:
            return "GRAPHICAL_BRIGHT (GNOME loading screen or bright graphical stage)", metrics

    # Fallback
    return f"UNKNOWN (br={br:.0f} cv={cv:.0f} td={td:.4f})", metrics


def main():
    if len(sys.argv) < 2:
        print("Usage: analyze-screenshot.py <image> [label]")
        sys.exit(1)

    img_path = sys.argv[1]
    label = sys.argv[2] if len(sys.argv) > 2 else Path(img_path).stem

    if not os.path.exists(img_path):
        print(f"    image not found: {img_path}")
        sys.exit(0)

    classification, metrics = classify(img_path)
    print(f"    [{label}] {classification}")
    for k, v in metrics.items():
        print(f"      {k}: {v}")


if __name__ == "__main__":
    main()
