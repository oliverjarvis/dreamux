#!/usr/bin/env python3
"""Build AppIcon.icns: the black sheep on a star-speckled night-blue squircle.

Usage:  python3 assets/icon/make-appicon.py
Reads   assets/icon/sheep-source.png   (black sheep artwork on white)
Writes  assets/icon/appicon-1024.png   (preview of the full-size icon)
        Sources/Dreamux/Resources/AppIcon.icns

Layout follows the Big Sur icon grid: 1024 canvas, 824x824 squircle at
(100,100), corner radius 185, soft baked-in drop shadow. The sheep is cut
out by flood-filling the OUTER white only, so the white face/ear strokes
survive; the mask is eroded a touch to kill the light fringe a white
background leaves on a dark one. Stars are seeded, so re-runs are
byte-stable — tweak constants, don't hunt pixels.
"""

import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "assets/icon/sheep-source.png"
PREVIEW = ROOT / "assets/icon/appicon-1024.png"
ICNS = ROOT / "Sources/Dreamux/Resources/AppIcon.icns"

CANVAS = 1024
SQUIRCLE = (100, 100, 924, 924)     # Apple's 824x824 icon rect
RADIUS = 185

SKY_TOP = (74, 90, 152)             # darkish blue, deliberately not too dark
SKY_BOTTOM = (37, 47, 92)
GLOW = (126, 142, 200)              # faint moonlit lift behind the sheep

SHEEP_WIDTH = 640                    # sheep footprint on the 824 squircle
SHEEP_CENTER = (512, 522)

STAR_SEED = 20260730
STAR_COUNT = 130
BRIGHT_STAR_COUNT = 10


def cut_out_sheep() -> Image.Image:
    """The source is black ink + alpha; every 'white' is transparency —
    including the FACE, which is an enclosed hole in the ink. Fill the
    enclosed holes with opaque white (so the >_ face keeps its paper) and
    leave the outer transparency alone; real gaps that reach the border
    (between the legs) stay see-through."""
    art = Image.open(SRC).convert("RGBA")
    w, h = art.size
    alpha = art.getchannel("A").load()

    # BFS from every border pixel across transparent-ish alpha = outside.
    outside = bytearray(w * h)
    stack = [(x, y) for x in range(w) for y in (0, h - 1)]
    stack += [(x, y) for y in range(h) for x in (0, w - 1)]
    while stack:
        x, y = stack.pop()
        if not (0 <= x < w and 0 <= y < h):
            continue
        i = y * w + x
        if outside[i] or alpha[x, y] >= 128:
            continue
        outside[i] = 1
        stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]

    holes = Image.frombytes("L", (w, h), bytes(
        255 if (alpha[i % w, i // w] < 128 and not outside[i]) else 0
        for i in range(w * h)))

    sheep = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sheep.paste((255, 255, 255, 255), (0, 0), holes)
    sheep.alpha_composite(art)
    return sheep.crop(sheep.getbbox())


def night_sky() -> Image.Image:
    sky = Image.new("RGB", (CANVAS, CANVAS))
    top, bottom = SKY_TOP, SKY_BOTTOM
    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        row = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        sky.paste(row, (0, y, CANVAS, y + 1))

    # Soft glow behind the sheep so the black silhouette separates.
    glow = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(glow).ellipse((512 - 360, 470 - 300, 512 + 360, 470 + 300), fill=64)
    glow = glow.filter(ImageFilter.GaussianBlur(130))
    sky = Image.composite(Image.new("RGB", sky.size, GLOW), sky, glow)

    stars = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(stars)
    rng = random.Random(STAR_SEED)
    x0, y0, x1, y1 = SQUIRCLE
    pad = 26
    for _ in range(STAR_COUNT):
        x = rng.uniform(x0 + pad, x1 - pad)
        y = rng.uniform(y0 + pad, y1 - pad)
        r = rng.uniform(1.0, 2.6)
        alpha = rng.randint(80, 210)
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, alpha))
    for _ in range(BRIGHT_STAR_COUNT):
        x = rng.uniform(x0 + pad * 2, x1 - pad * 2)
        y = rng.uniform(y0 + pad * 2, y1 - pad * 2)
        r = rng.uniform(3.0, 4.2)
        arm = rng.uniform(9, 15)
        draw.line((x - arm, y, x + arm, y), fill=(255, 255, 255, 120), width=2)
        draw.line((x, y - arm, x, y + arm), fill=(255, 255, 255, 120), width=2)
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, 235))
    stars = stars.filter(ImageFilter.GaussianBlur(0.6))
    sky = sky.convert("RGBA")
    sky.alpha_composite(stars)
    return sky


def build_icon() -> Image.Image:
    sheep = cut_out_sheep()
    scale = SHEEP_WIDTH / sheep.width
    sheep = sheep.resize(
        (SHEEP_WIDTH, round(sheep.height * scale)), Image.LANCZOS)

    face = night_sky()
    cx, cy = SHEEP_CENTER
    face.alpha_composite(
        sheep, (cx - sheep.width // 2, cy - sheep.height // 2))

    mask = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(mask).rounded_rectangle(SQUIRCLE, RADIUS, fill=255)

    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    # Baked-in drop shadow, like every stock macOS icon.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (0, 10, CANVAS, CANVAS + 10), mask)
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
    icon.paste(face, (0, 0), mask)
    return icon


def write_icns(icon: Image.Image) -> None:
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for factor, suffix in ((1, ""), (2, "@2x")):
                px = size * factor
                icon.resize((px, px), Image.LANCZOS).save(
                    iconset / f"icon_{size}x{size}{suffix}.png")
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS)],
            check=True)


if __name__ == "__main__":
    icon = build_icon()
    icon.save(PREVIEW)
    write_icns(icon)
    print(f"wrote {PREVIEW.relative_to(ROOT)} and {ICNS.relative_to(ROOT)}")
