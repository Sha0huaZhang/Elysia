#!/usr/bin/env python3
"""Regenerate the Elysia AppIcon set as a macOS-style rounded square (squircle).

Usage:
    python3 Scripts/generate-appicon.py <source-image>

The source image is letterboxed inside Apple's app icon grid -- an 824x824
rounded square centred on a 1024x1024 canvas -- and composited over an opaque
white plate. Everything outside the rounded square stays transparent, which is
what macOS expects: the system adds the drop shadow and the masking itself.

Requires Pillow:  python3 -m pip install pillow
"""
import argparse
import os

from PIL import Image, ImageChops

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(REPO_ROOT, "Elysia", "Assets.xcassets", "AppIcon.appiconset")

MASTER = 1024             # master canvas size
TILE = 824                # Apple's macOS icon grid: side of the rounded square
SQUIRCLE_N = 5            # superellipse exponent (Apple-like continuous corners)
SUPERSAMPLE = 8           # supersampling factor for the corner mask
PLATE = (255, 255, 255)   # fill behind the artwork

ICONS = {
    "icon_16.png": 16, "icon_32.png": 32, "icon_33.png": 32, "icon_64.png": 64,
    "icon_128.png": 128, "icon_256.png": 256, "icon_257.png": 256,
    "icon_512.png": 512, "icon_513.png": 512, "icon_1024.png": 1024,
}


def squircle_mask(side):
    """Anti-aliased alpha mask of a superellipse with the given side length."""
    big = side * SUPERSAMPLE
    half = big / 2.0
    mask = Image.new("L", (big, big), 0)
    for y in range(big):
        dy = abs(y + 0.5 - half) / half
        if dy >= 1.0:
            continue
        span = half * (1.0 - dy ** SQUIRCLE_N) ** (1.0 / SQUIRCLE_N)
        x0 = max(0, min(big, int(round(half - span))))
        x1 = max(0, min(big, int(round(half + span))))
        if x1 > x0:
            mask.paste(255, (x0, y, x1, y + 1))
    return mask.resize((side, side), Image.LANCZOS)


def premultiplied_resize(img, size):
    """Resize RGBA by scaling premultiplied colour, so edges do not darken."""
    r, g, b, a = img.split()
    channels = [
        ImageChops.multiply(c, a).resize((size, size), Image.LANCZOS) for c in (r, g, b)
    ]
    alpha = a.resize((size, size), Image.LANCZOS)

    alpha_px = alpha.load()
    src_px = [c.load() for c in channels]
    dst = [Image.new("L", (size, size), 0) for _ in range(3)]
    dst_px = [d.load() for d in dst]

    for y in range(size):
        for x in range(size):
            av = alpha_px[x, y]
            if av == 0:
                continue
            if av == 255:
                for i in range(3):
                    dst_px[i][x, y] = src_px[i][x, y]
                continue
            for i in range(3):
                value = src_px[i][x, y] * 255 // av
                dst_px[i][x, y] = 255 if value > 255 else value

    return Image.merge("RGBA", (dst[0], dst[1], dst[2], alpha))


def build_master(source):
    art = Image.open(source).convert("RGBA")

    bbox = art.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    if bbox is None:
        raise SystemExit(f"{source}: image is fully transparent")
    art = art.crop(bbox)

    scale = min(TILE / art.width, TILE / art.height)
    art = art.resize(
        (max(1, round(art.width * scale)), max(1, round(art.height * scale))),
        Image.LANCZOS,
    )

    plate = Image.new("RGBA", (TILE, TILE), PLATE + (255,))
    plate.alpha_composite(art, ((TILE - art.width) // 2, (TILE - art.height) // 2))

    offset = (MASTER - TILE) // 2
    canvas = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    canvas.paste(plate, (offset, offset))

    mask = Image.new("L", (MASTER, MASTER), 0)
    mask.paste(squircle_mask(TILE), (offset, offset))
    canvas.putalpha(ImageChops.multiply(canvas.getchannel("A"), mask))
    return canvas


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", help="artwork to turn into an app icon")
    args = parser.parse_args()

    if not os.path.isdir(ICONSET):
        raise SystemExit(f"icon set not found: {ICONSET}")

    master = build_master(args.source)
    for name, size in ICONS.items():
        image = master if size == MASTER else premultiplied_resize(master, size)
        image.save(os.path.join(ICONSET, name))
        print(f"{name}: {size}x{size}")


if __name__ == "__main__":
    main()
