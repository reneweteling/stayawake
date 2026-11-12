#!/usr/bin/env python3
"""Composite the generated StayAwake artwork into a macOS Big Sur style icon.

Same grid as TidyDrive's make-icon.swift: the rounded square sits inset 9.8%
from each edge, corner radius 22.5% of the shape, soft drop shadow below and
a faint highlight on top. Writes the 1024 master, the .iconset and the .icns.

Run: python3 design/source/build_icon.py
"""
import subprocess
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

DESIGN = Path(__file__).resolve().parent.parent
ART = DESIGN / "icon/candidates/icon-a2-moon-gauge-bold.png"
OUT = DESIGN / "icon"
SS = 4  # supersampling for the shape mask


def rounded_mask(size: int, inset: float, radius: float) -> Image.Image:
    big = size * SS
    m = Image.new("L", (big, big), 0)
    d = ImageDraw.Draw(m)
    i = inset * SS
    d.rounded_rectangle([i, i, big - i - 1, big - i - 1], radius=radius * SS, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def render(size: int = 1024, art_zoom: float = 1.0) -> Image.Image:
    s = size
    inset = round(s * 0.098)
    shape = s - inset * 2
    radius = shape * 0.225

    art = Image.open(ART).convert("RGB")
    # Crop a little in so the ring fills the tile like TidyDrive's dial does.
    w, h = art.size
    c = int(w * (1 - 0.92 / art_zoom) / 2)
    art = art.crop((c, c, w - c, h - c)).resize((shape, shape), Image.LANCZOS)

    # Faint top highlight, like the sibling icon
    hl = Image.new("L", (shape, shape), 0)
    hd = ImageDraw.Draw(hl)
    for y in range(shape // 2):
        hd.line([(0, y), (shape, y)], fill=int(26 * (1 - y / (shape / 2))))
    white = Image.new("RGB", (shape, shape), (255, 255, 255))
    art = Image.composite(white, art, hl)

    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    mask = rounded_mask(s, inset, radius)

    # Drop shadow
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sh_alpha = mask.point(lambda v: int(v * 0.35))
    sh_alpha = ImageChops.offset(sh_alpha, 0, max(1, round(s * 0.012)))
    sh_alpha = sh_alpha.filter(ImageFilter.GaussianBlur(max(0.5, s * 0.015)))
    shadow.putalpha(sh_alpha)
    canvas = Image.alpha_composite(canvas, shadow)

    body = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    body.paste(art, (inset, inset))
    body.putalpha(mask)
    canvas = Image.alpha_composite(canvas, body)

    # Hairline inner edge for definition on dark backgrounds
    edge = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ring = ImageChops.subtract(mask, rounded_mask(s, inset + max(1, s / 512), radius - max(1, s / 512)))
    edge.paste((255, 255, 255, 255), (0, 0), ring.point(lambda v: int(v * 0.10)))
    return Image.alpha_composite(canvas, edge)


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def render_small(size: int) -> Image.Image:
    """Simplified glyph for 16 and 32 px: heavier ring, bigger moon, no ticks or star."""
    import math
    B = 512
    img = Image.new("RGBA", (B, B), (0, 0, 0, 0))
    inset = B * 0.06
    shape = B - inset * 2
    mask = rounded_mask(B, inset, shape * 0.225)
    bg = Image.new("RGB", (B, B))
    bd = ImageDraw.Draw(bg)
    for y in range(B):
        bd.line([(0, y), (B, y)], fill=lerp((30, 50, 55), (8, 14, 16), y / B))
    img.paste(bg, (0, 0), mask)
    d = ImageDraw.Draw(img)
    cx = cy = B / 2
    r = shape * 0.36
    w = shape * 0.13
    R = r + w / 2  # PIL draws arc width inward from the box
    box = [cx - R, cy - R, cx + R, cy + R]
    d.arc(box, 0, 360, fill=(58, 74, 77, 255), width=round(w))
    # Filled part: from 12 o'clock counterclockwise to about 4 o'clock, vermilion to amber
    start, sweep = -90, -250
    steps = 120
    for k in range(steps):
        a0 = start + sweep * k / steps
        a1 = start + sweep * (k + 1.5) / steps
        col = lerp((255, 90, 54), (255, 181, 71), k / steps)
        d.arc(box, min(a0, a1), max(a0, a1), fill=col + (255,), width=round(w))
    for ang, col in ((start, (255, 90, 54)), (start + sweep, (243, 245, 242))):
        x = cx + math.cos(math.radians(ang)) * r
        y = cy + math.sin(math.radians(ang)) * r
        rr = w / 2 if col != (243, 245, 242) else w * 0.55
        d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=col + (255,))
    # Crescent moon: disc minus offset disc
    mr = r * 0.54
    moon = Image.new("L", (B, B), 0)
    md = ImageDraw.Draw(moon)
    mx, my = cx - r * 0.04, cy + r * 0.04
    md.ellipse([mx - mr, my - mr, mx + mr, my + mr], fill=255)
    ox, oy = mx + mr * 0.48, my - mr * 0.42
    md.ellipse([ox - mr * 0.82, oy - mr * 0.82, ox + mr * 0.82, oy + mr * 0.82], fill=0)
    mc = Image.new("RGB", (B, B))
    mcd = ImageDraw.Draw(mc)
    for y in range(B):
        mcd.line([(0, y), (B, y)], fill=lerp((255, 205, 110), (255, 138, 61), y / B))
    img.paste(mc, (0, 0), moon)
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    master = render(1024)
    master.save(OUT / "icon-1024.png", optimize=True)

    iconset = OUT / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    src = OUT / "icon-1024.png"
    sizes = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
        ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for name, px in sizes:
        dst = iconset / f"{name}.png"
        subprocess.run(["sips", "-z", str(px), str(px), str(src), "--out", str(dst)],
                       check=True, capture_output=True)
    # Hand-tuned glyph for the tiny sizes, the generated art turns to mush there
    for name, px in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32)]:
        render_small(px).save(iconset / f"{name}.png", optimize=True)
    render_small(512).save(OUT / "icon-small-glyph-512.png", optimize=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "AppIcon.icns")], check=True)
    print("wrote", OUT / "icon-1024.png", OUT / "AppIcon.icns")


if __name__ == "__main__":
    main()
