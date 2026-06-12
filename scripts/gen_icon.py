#!/usr/bin/env python3
"""Generate the IG Downloader app icon set source PNGs.

Produces three 1024x1024 assets under assets/icon/ that flutter_launcher_icons
consumes:

  ic_full.png  - gradient background + white download glyph (iOS + legacy Android)
  ic_bg.png    - gradient only            (Android adaptive background layer)
  ic_fg.png    - white download glyph on transparent, inset into the adaptive
                 safe zone (Android adaptive foreground layer)

Design: Instagram-style diagonal gradient (blue -> purple -> magenta -> orange ->
yellow) with a clean white "download to tray" glyph (down arrow + baseline).

Rendered at 4x supersampling then downscaled for smooth edges.
"""
from PIL import Image, ImageDraw
import os

S = 1024          # final size
SS = 4            # supersample factor
N = S * SS        # working canvas size

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "assets", "icon")
os.makedirs(OUT_DIR, exist_ok=True)

# Instagram brand gradient stops (diagonal, bottom-left -> top-right).
STOPS = [
    (0.00, (0x40, 0x5D, 0xE6)),   # blue-violet
    (0.25, (0x83, 0x34, 0xAF)),   # purple
    (0.50, (0xDD, 0x2A, 0x7B)),   # magenta
    (0.75, (0xF5, 0x85, 0x29)),   # orange
    (1.00, (0xFE, 0xDA, 0x77)),   # warm yellow
]


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def grad_color(t):
    t = max(0.0, min(1.0, t))
    for i in range(len(STOPS) - 1):
        t0, c0 = STOPS[i]
        t1, c1 = STOPS[i + 1]
        if t0 <= t <= t1:
            return lerp(c0, c1, (t - t0) / (t1 - t0))
    return STOPS[-1][1]


def make_gradient(size):
    """Diagonal gradient image (corner-to-corner)."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    maxd = (size - 1) * 2.0
    for y in range(size):
        for x in range(size):
            # bottom-left (0) -> top-right (1)
            d = (x + (size - 1 - y)) / maxd
            px[x, y] = grad_color(d)
    return img


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def draw_download_glyph(draw, cx, cy, scale, color=(255, 255, 255, 255)):
    """A clean 'download to line' glyph centred on (cx, cy).

    scale = half-height of the glyph block in px.
    """
    # Proportions (relative to scale)
    stem_w = scale * 0.34
    stem_top = cy - scale * 0.95
    stem_bot = cy + scale * 0.18
    # Vertical stem
    draw.rounded_rectangle(
        [cx - stem_w / 2, stem_top, cx + stem_w / 2, stem_bot],
        radius=stem_w / 2,
        fill=color,
    )
    # Arrow head (downward triangle)
    head_w = scale * 0.92
    head_top = cy - scale * 0.10
    head_tip = cy + scale * 0.62
    draw.polygon(
        [
            (cx - head_w, head_top),
            (cx + head_w, head_top),
            (cx, head_tip),
        ],
        fill=color,
    )
    # Baseline tray (rounded horizontal bar)
    bar_w = scale * 1.30
    bar_h = scale * 0.30
    bar_y = cy + scale * 0.92
    draw.rounded_rectangle(
        [cx - bar_w, bar_y, cx + bar_w, bar_y + bar_h],
        radius=bar_h / 2,
        fill=color,
    )


def render_full():
    base = make_gradient(N).convert("RGBA")
    glyph = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glyph)
    draw_download_glyph(gd, N / 2, N / 2 - N * 0.02, scale=N * 0.26)
    base.alpha_composite(glyph)
    # iOS has no rounded mask requirement (system masks), but rounding the
    # legacy/full icon looks better on Android pre-adaptive launchers.
    mask = rounded_mask(N, radius=int(N * 0.235))
    out = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    out.paste(base, (0, 0), mask)
    out.resize((S, S), Image.LANCZOS).save(os.path.join(OUT_DIR, "ic_full.png"))


def render_bg():
    base = make_gradient(N).convert("RGBA")
    base.resize((S, S), Image.LANCZOS).save(os.path.join(OUT_DIR, "ic_bg.png"))


def render_fg():
    glyph = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glyph)
    # Adaptive foreground: the inner 66% is the safe zone. Keep the glyph
    # smaller so it isn't clipped by aggressive launcher masks.
    draw_download_glyph(gd, N / 2, N / 2 - N * 0.01, scale=N * 0.20)
    glyph.resize((S, S), Image.LANCZOS).save(os.path.join(OUT_DIR, "ic_fg.png"))


if __name__ == "__main__":
    render_full()
    render_bg()
    render_fg()
    print("Wrote ic_full.png, ic_bg.png, ic_fg.png to", os.path.abspath(OUT_DIR))
