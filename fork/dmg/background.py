#!/usr/bin/env python3
"""Draws the DMG's background: the window people see when they open Maggie.dmg,
with an arrow from where the app sits to where the Applications link sits.

    python3 fork/dmg/background.py

Writes background.tiff next to this script, at 1x and 2x so it is sharp on
Retina. The positions match the --icon and --app-drop-link arguments the release
workflow gives create-dmg: a 660x400 window, icons 128px, the app at (180, 170)
and Applications at (480, 170).

Needs Pillow: python3 -m pip install Pillow
"""
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
WIDTH, HEIGHT = 660, 400
APP_X, LINK_X, ICON_Y = 180, 480, 170
ICON = 128


def draw(scale: int) -> Image.Image:
    w, h = WIDTH * scale, HEIGHT * scale
    image = Image.new("RGB", (w, h), (14, 14, 16))
    px = image.load()
    # A slow vertical gradient, near-black at the bottom, so the icons' black tiles
    # don't float on a flat field.
    top, bottom = (30, 31, 36), (10, 10, 12)
    for y in range(h):
        t = y / (h - 1)
        c = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        for x in range(w):
            px[x, y] = c

    d = ImageDraw.Draw(image)
    s = scale
    # The arrow, between the two icons at their vertical centre.
    x0 = (APP_X + ICON // 2 + 24) * s
    x1 = (LINK_X - ICON // 2 - 24) * s
    y = ICON_Y * s
    width = 6 * s
    grey = (120, 122, 130)
    d.line([(x0, y), (x1, y)], fill=grey, width=width)
    head = 22 * s
    d.polygon([(x1 + 6 * s, y), (x1 - head, y - head * 0.65), (x1 - head, y + head * 0.65)], fill=grey)

    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 15 * s)
    except OSError:
        font = ImageFont.load_default()
    caption = "Drag Maggie to Applications"
    box = d.textbbox((0, 0), caption, font=font)
    d.text(((w - (box[2] - box[0])) / 2, (ICON_Y + ICON // 2 + 58) * s), caption, fill=(150, 152, 160), font=font)
    return image


one = HERE / "background.png"
two = HERE / "background@2x.png"
draw(1).save(one)
draw(2).save(two)
# One TIFF holding both: Finder picks the right one for the display.
subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(HERE / "background.tiff")], check=True)
one.unlink()
two.unlink()
print("wrote background.tiff")
