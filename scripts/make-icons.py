#!/usr/bin/env python3
"""Writes the extension's images from the single icon source.

  python3 scripts/make-icons.py

Extension/Resources/images/icon-*.png are scaled from icon/AppIcon.png (the packaged app icon).
toolbar-*.png is the small toolbar glyph: two forward triangles, drawn here because a 16 px toolbar
button needs a flat shape rather than the rendered icon.
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Extension" / "Resources" / "images"
SOURCE = ROOT / "icon" / "AppIcon.png"
GLYPH = (224, 72, 28, 255)


def toolbar(size: int) -> Image.Image:
    scale = 8
    n = size * scale
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    top, bottom, mid = n * 0.2, n * 0.8, n * 0.5
    for left, right in ((n * 0.08, n * 0.52), (n * 0.5, n * 0.94)):
        draw.polygon([(left, top), (right, mid), (left, bottom)], fill=GLYPH)
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    source = Image.open(SOURCE).convert("RGBA")
    for size in (48, 96, 128, 256, 512):
        source.resize((size, size), Image.LANCZOS).save(OUT / f"icon-{size}.png")
    for size in (16, 19, 32, 38, 48, 72):
        toolbar(size).save(OUT / f"toolbar-{size}.png")
    print(f"icons written to {OUT}")


if __name__ == "__main__":
    main()
