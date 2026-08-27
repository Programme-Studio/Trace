#!/usr/bin/env python3
"""Regenerate Assets.xcassets: app icon + menu bar template icons.

Run from the folder holding Unbox.xcodeproj:  python3 make_icons.py
Needs Pillow. Tweak the glyph functions below and re-run to redesign.
"""
import json
import os
import shutil
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "Unbox", "Assets.xcassets")
S = 1024


def glyph_outline(d, w, k, colour=255):
    """Folder with a down arrow inside. Stroke style — the menu bar default."""
    d.line([(w * 0.10, w * 0.84), (w * 0.10, w * 0.26), (w * 0.38, w * 0.26),
            (w * 0.45, w * 0.36), (w * 0.90, w * 0.36), (w * 0.90, w * 0.84),
            (w * 0.10, w * 0.84)],
           fill=colour, width=k, joint="curve")
    cx = w * 0.5
    d.line([(cx, w * 0.46), (cx, w * 0.70)], fill=colour, width=k)
    d.line([(cx - w * 0.13, w * 0.57), (cx, w * 0.72), (cx + w * 0.13, w * 0.57)],
           fill=colour, width=k, joint="curve")


def glyph_solid(d, w, k):
    """Same folder, filled, arrow knocked out. Used while a link is resolving."""
    d.polygon([(w * 0.09, w * 0.84), (w * 0.09, w * 0.24), (w * 0.38, w * 0.24),
               (w * 0.46, w * 0.35), (w * 0.91, w * 0.35), (w * 0.91, w * 0.84)],
              fill=255)
    cx = w * 0.5
    kk = int(k * 1.2)
    d.line([(cx, w * 0.44), (cx, w * 0.69)], fill=0, width=kk)
    d.line([(cx - w * 0.14, w * 0.56), (cx, w * 0.72), (cx + w * 0.14, w * 0.56)],
           fill=0, width=kk, joint="curve")


def make_template(size, solid=False):
    """White glyph with alpha — macOS recolours template images itself."""
    master = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(master)
    if solid:
        glyph_solid(d, S, int(S * 0.075))
    else:
        glyph_outline(d, S, int(S * 0.075))
    alpha = master.resize((size, size), Image.LANCZOS)
    white = Image.new("L", (size, size), 255)
    return Image.merge("RGBA", (white, white, white, alpha))


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1],
                                           radius=radius, fill=255)
    return mask


def make_app_icon(size):
    """macOS-style squircle with a vertical blue gradient and the white glyph."""
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Apple's macOS icon grid: art occupies 824 of 1024, corner radius 185.
    art = 824
    radius = 185
    inset = (S - art) // 2

    gradient = Image.new("RGBA", (art, art))
    gd = ImageDraw.Draw(gradient)
    top = (58, 140, 255)
    bottom = (10, 78, 200)
    for y in range(art):
        t = y / max(art - 1, 1)
        gd.line(
            [(0, y), (art, y)],
            fill=(
                int(top[0] + (bottom[0] - top[0]) * t),
                int(top[1] + (bottom[1] - top[1]) * t),
                int(top[2] + (bottom[2] - top[2]) * t),
                255,
            ),
        )
    gradient.putalpha(rounded_mask(art, radius))
    canvas.alpha_composite(gradient, (inset, inset))

    # glyph, sized to sit comfortably inside the squircle
    g = int(art * 0.56)
    glyph = make_template(g)
    canvas.alpha_composite(glyph, ((S - g) // 2, (S - g) // 2 + int(art * 0.01)))

    return canvas.resize((size, size), Image.LANCZOS)


def write(path, image):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path)


if os.path.isdir(OUT):
    shutil.rmtree(OUT)
os.makedirs(OUT)

write(os.path.join(OUT, "Contents.json"), None) if False else None
with open(os.path.join(OUT, "Contents.json"), "w") as f:
    json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)

# ---- AppIcon ----------------------------------------------------------------
appicon = os.path.join(OUT, "AppIcon.appiconset")
os.makedirs(appicon)
entries = [(16, "1x"), (16, "2x"), (32, "1x"), (32, "2x"),
           (128, "1x"), (128, "2x"), (256, "1x"), (256, "2x"),
           (512, "1x"), (512, "2x")]
images = []
for base, scale in entries:
    pixels = base * (2 if scale == "2x" else 1)
    name = f"icon_{base}x{base}@{scale}.png"
    write(os.path.join(appicon, name), make_app_icon(pixels))
    images.append({"idiom": "mac", "size": f"{base}x{base}",
                   "scale": scale, "filename": name})
with open(os.path.join(appicon, "Contents.json"), "w") as f:
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)

# ---- preview sheet ----------------------------------------------------------
prev = Image.new("RGBA", (900, 320), (235, 235, 238, 255))
prev.alpha_composite(make_app_icon(256), (20, 30))
prev.alpha_composite(make_app_icon(128), (300, 30))
prev.alpha_composite(make_app_icon(64), (450, 30))
prev.alpha_composite(make_app_icon(32), (530, 30))
prev.alpha_composite(make_app_icon(16), (580, 30))
# menu bar strip, light and dark
strip = Image.new("RGBA", (280, 44), (245, 245, 247, 255))
strip.alpha_composite(Image.merge("RGBA", (Image.new("L", (18, 18), 0),) * 3
                                  + (make_template(18).split()[3],)), (20, 13))
strip.alpha_composite(Image.merge("RGBA", (Image.new("L", (18, 18), 0),) * 3
                                  + (make_template(18, True).split()[3],)), (60, 13))
prev.alpha_composite(strip, (300, 200))
dark = Image.new("RGBA", (280, 44), (40, 40, 44, 255))
dark.alpha_composite(make_template(18), (20, 13))
dark.alpha_composite(make_template(18, True), (60, 13))
prev.alpha_composite(dark, (300, 250))
prev.save(os.path.join(HERE, "icon_preview.png"))

print("assets written to", OUT)
