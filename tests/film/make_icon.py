"""Draws docs/images/icon.png (256x256) from addons/schematic/icons/schematic.svg's shapes.

The Godot Asset Library only takes a png or jpg icon URL, so this is the same icon as the plugin's SVG, rasterised.
Needs Pillow. Run from anywhere: python tests/film/make_icon.py
"""
from pathlib import Path
from PIL import Image, ImageDraw

out = Path(__file__).resolve().parents[2] / "docs/images/icon.png"
S = 256
K = 4                       # supersampling
u = S * K / 16.0            # the SVG is a 16 x 16 box
im = Image.new("RGBA", (S * K, S * K), (0, 0, 0, 0))
d = ImageDraw.Draw(im)
d.rounded_rectangle((1 * u, 1 * u, 15 * u, 15 * u), radius=3 * u, fill=(0x1C, 0x6F, 0xD6, 255))


def bez(p0, p1, p2, p3, n=40):
    pts = []
    for i in range(n + 1):
        t = i / n
        a = (1 - t) ** 3
        b = 3 * (1 - t) ** 2 * t
        c = 3 * (1 - t) * t * t
        e = t ** 3
        pts.append((a * p0[0] + b * p1[0] + c * p2[0] + e * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + e * p3[1]))
    return pts


# M5.2 5.2 h2.2  c2 0 1.2 5.6 3.4 5.6  h.2
path = [(5.2, 5.2), (7.4, 5.2)] + bez((7.4, 5.2), (9.4, 5.2), (8.6, 10.8), (10.8, 10.8))[1:] + [(11.0, 10.8)]
pts = [(x * u, y * u) for x, y in path]
w = 1.3 * u
# a dense run of round dots, so the stroke has round caps and no seams
dense = []
for (x0, y0), (x1, y1) in zip(path, path[1:]):
    steps = max(2, int(((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5 * u / 2))
    dense += [(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps) for i in range(steps + 1)]
for x, y in dense:
    d.ellipse((x * u - w / 2, y * u - w / 2, x * u + w / 2, y * u + w / 2), fill=(255, 255, 255, 255))
for cx, cy in ((4.6, 5.2), (11.4, 10.8)):
    d.ellipse(((cx - 1.5) * u, (cy - 1.5) * u, (cx + 1.5) * u, (cy + 1.5) * u), fill=(255, 255, 255, 255))
im.resize((S, S), Image.LANCZOS).save(out)
print(out)
