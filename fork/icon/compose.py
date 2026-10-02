#!/usr/bin/env python3
"""Builds the Maggie app icon from the two magpie images next to this script.

    python3 fork/icon/compose.py

The photo (magpie-photo.png) carries the large sizes, the flat drawing
(magpie-flat.png) the small ones, where feather detail would turn to noise.
Both are framed the same so the icon doesn't jump as the Dock scales it.

Writes, next to this script:
    Maggie.iconset/     every size macOS wants; the install script runs
                        iconutil on it to make the app's .icns
    Maggie.png          the 1024px tile, for READMEs and release pages
and refreshes
    images/Maggie.icon/Assets/Maggie.png    the layer of the Icon Composer icon
                                            Xcode builds into the app
    macos/Assets.xcassets/AppIconImage.imageset/    what the app shows in its
                                                    own windows

Needs Pillow: python3 -m pip install Pillow
"""
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
PHOTO = HERE / "magpie-photo.png"
FLAT = HERE / "magpie-flat.png"
ICONSET = HERE / "Maggie.iconset"
ROOT = HERE.parent.parent
ICON_LAYER = ROOT / "images/Maggie.icon/Assets/Maggie.png"
IMAGESET = ROOT / "macos/Assets.xcassets/AppIconImage.imageset"
SIZE = 1024

# Crown to the top of the breast, nape to beak tip; square so it scales straight
# onto the tile and bleeds off the bottom.
CROP = (150, 20, 1254, 1124)

# Apple's icon mask is a continuous-curve rounded rect; this radius is close
# enough for an .icns. Icon Composer masks its own layers.
MASK = Image.new("L", (SIZE, SIZE), 0)
ImageDraw.Draw(MASK).rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=229, fill=255)


def layer(src: Path) -> Image.Image:
    return Image.open(src).convert("RGBA").crop(CROP).resize((SIZE, SIZE), Image.LANCZOS)


def tile(bird: Image.Image) -> Image.Image:
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 255))
    out.alpha_composite(bird)
    out.putalpha(MASK)
    return out


photo = tile(layer(PHOTO))
flat = tile(layer(FLAT))

photo.save(HERE / "Maggie.png")
ICON_LAYER.parent.mkdir(parents=True, exist_ok=True)
layer(PHOTO).save(ICON_LAYER)

ICONSET.mkdir(exist_ok=True)
for name, px in [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]:
    src = flat if px <= 128 else photo
    src.resize((px, px), Image.LANCZOS).save(ICONSET / name)

for name, px in [
    ("macOS-AppIcon-1024px.png", 1024),
    ("macOS-AppIcon-512px.png", 512),
    ("macOS-AppIcon-256px-128pt@2x.png", 256),
]:
    photo.resize((px, px), Image.LANCZOS).save(IMAGESET / name)

# The glyph: the swooping magpie (magpie-emblem.png), for the sidebar row of a
# session that has no title yet. 32pt tall at 1x, 2x and 3x, on transparency;
# rows draw it at 22pt, extended rows at 30pt.
GLYPH = ROOT / "macos/Assets.xcassets/MaggieGlyph.imageset"
GLYPH.mkdir(parents=True, exist_ok=True)
emblem = Image.open(HERE / "magpie-emblem.png").convert("RGBA")
emblem = emblem.crop(emblem.getbbox())
for scale in (1, 2, 3):
    height = 32 * scale
    width = round(emblem.width * height / emblem.height)
    suffix = "" if scale == 1 else f"@{scale}x"
    emblem.resize((width, height), Image.LANCZOS).save(GLYPH / f"MaggieGlyph{suffix}.png")
(GLYPH / "Contents.json").write_text(
    '{\n  "images" : [\n'
    + ",\n".join(
        f'    {{\n      "filename" : "MaggieGlyph{"" if s == 1 else f"@{s}x"}.png",\n'
        f'      "idiom" : "universal",\n      "scale" : "{s}x"\n    }}'
        for s in (1, 2, 3)
    )
    + '\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
)

print("wrote Maggie.iconset, Maggie.png, the Maggie.icon layer and the AppIconImage imageset")
