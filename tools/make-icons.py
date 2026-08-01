#!/usr/bin/env python3
"""Generate the driver's icon set.

Two sources:

* The device and branding marks are drawn here -- an equalizer waveform on a
  teal-to-blue tile. Original artwork, deliberately unrelated to JRiver's own
  branding so the driver can be published freely.
* The tab and Now Playing glyphs are Feather icons (MIT, Cole Bemis), vendored
  under `vendor/feather/`. They are recoloured to the driver's palette and their
  stroke is thickened a little, because Navigator renders them as small as 70px.

Feather's SVGs use only lines, polylines, circles and paths built from move,
horizontal, vertical and quarter-circle arc commands, so they are rasterised
directly with Pillow. That avoids a native SVG library, and means the icons can
be regenerated anywhere Pillow runs.

    python3 tools/make-icons.py [output_dir]

Icons live under `www/`, which is where Composer and the `controller://` scheme
resolve driver assets from -- not the c4z root.
"""

import math
import os
import re
import sys
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw

SS = 8  # supersampling factor; the 16px and 20px renders depend on it

# Sizes the Navigator image list requests for list rows.
ROW_SIZES = (20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 300)

HERE = os.path.dirname(os.path.abspath(__file__))
FEATHER = os.path.join(HERE, "..", "vendor", "feather", "icons")

TEAL = (14, 165, 160)
BLUE = (30, 78, 140)
WHITE = (255, 255, 255, 255)
IDLE = (232, 236, 240, 255)   # tab and transport glyphs at rest
ACTIVE = (34, 197, 194, 255)  # shuffle and repeat when engaged

# Bar heights as a fraction of the glyph box, shaped like a waveform rather than
# a monotonic ramp.
BARS = (0.34, 0.62, 1.0, 0.72, 0.44)

# Driver icon name -> Feather source. Feather's stroke width is 2 in a 24 unit
# viewBox; a little more holds up better at 70px.
# Icons attached to individual list rows, so they need the full range Navigator's
# image list can ask for rather than just the 70/140 a tab uses.
ROW_GLYPHS = {
    "action_play": ("play", 2.2),
    "action_shuffle": ("shuffle", 2.2),
}

GLYPHS = {
    "tab_artists": ("user", 2.1),
    "tab_albums": ("disc", 2.1),
    "tab_playlists": ("list", 2.1),
    "tab_more": ("more-horizontal", 4.2),   # Feather draws r=1 dots; too faint as-is
    "np_shuffle": ("shuffle", 2.2),
    "np_repeat": ("repeat", 2.2),
}


# ---------------------------------------------------------------- SVG subset

def _tokenise_path(d):
    return re.findall(r"([MmLlHhVvAaZz])|(-?\d*\.?\d+(?:e-?\d+)?)", d)


def _arc_points(x1, y1, rx, ry, large_arc, sweep, x2, y2, steps=24):
    """Endpoint to centre parameterisation, for circular arcs (rx == ry)."""
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [(x2, y2)]

    dx2, dy2 = (x1 - x2) / 2.0, (y1 - y2) / 2.0
    lam = (dx2 * dx2) / (rx * rx) + (dy2 * dy2) / (ry * ry)
    if lam > 1:
        s = math.sqrt(lam)
        rx, ry = rx * s, ry * s

    num = rx * rx * ry * ry - rx * rx * dy2 * dy2 - ry * ry * dx2 * dx2
    den = rx * rx * dy2 * dy2 + ry * ry * dx2 * dx2
    coef = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large_arc == sweep:
        coef = -coef

    cxp, cyp = coef * rx * dy2 / ry, -coef * ry * dx2 / rx
    cx, cy = cxp + (x1 + x2) / 2.0, cyp + (y1 + y2) / 2.0

    def angle(ux, uy):
        return math.atan2(uy, ux)

    t1 = angle((dx2 - cxp) / rx, (dy2 - cyp) / ry)
    t2 = angle((-dx2 - cxp) / rx, (-dy2 - cyp) / ry)
    dt = t2 - t1
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi

    return [
        (cx + rx * math.cos(t1 + dt * i / steps), cy + ry * math.sin(t1 + dt * i / steps))
        for i in range(1, steps + 1)
    ]


def _path_polylines(d):
    """Returns a list of point lists. Supports M/L/H/V/A/Z, absolute and relative."""
    tokens = _tokenise_path(d)
    lines, cur = [], []
    x = y = sx = sy = 0.0
    cmd = None
    nums = []

    def flush_move():
        nonlocal cur
        if len(cur) > 1:
            lines.append(cur)
        cur = []

    i = 0
    while i < len(tokens):
        letter, number = tokens[i]
        if letter:
            cmd, nums = letter, []
            i += 1
            if cmd in "Zz":
                if cur:
                    cur.append((sx, sy))
                    flush_move()
                x, y = sx, sy
            continue

        nums.append(float(number))
        need = {"M": 2, "m": 2, "L": 2, "l": 2, "H": 1, "h": 1, "V": 1, "v": 1, "A": 7, "a": 7}[cmd]
        if len(nums) < need:
            i += 1
            continue

        if cmd in "Mm":
            flush_move()
            x, y = (nums[0], nums[1]) if cmd == "M" else (x + nums[0], y + nums[1])
            sx, sy = x, y
            cur = [(x, y)]
            cmd = "L" if cmd == "M" else "l"     # subsequent pairs are implicit lineto
        elif cmd in "Ll":
            x, y = (nums[0], nums[1]) if cmd == "L" else (x + nums[0], y + nums[1])
            cur.append((x, y))
        elif cmd in "Hh":
            x = nums[0] if cmd == "H" else x + nums[0]
            cur.append((x, y))
        elif cmd in "Vv":
            y = nums[0] if cmd == "V" else y + nums[0]
            cur.append((x, y))
        elif cmd in "Aa":
            rx, ry, _rot, laf, sf, ex, ey = nums
            if cmd == "a":
                ex, ey = x + ex, y + ey
            cur.extend(_arc_points(x, y, abs(rx), abs(ry), int(laf), int(sf), ex, ey))
            x, y = ex, ey

        nums = []
        i += 1

    flush_move()
    return lines


def _stroke(draw, pts, colour, width):
    """Polyline with round caps and joins, which PIL does not do natively."""
    r = width / 2.0
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        draw.line([x0, y0, x1, y1], fill=colour, width=int(round(width)))
    for x, y in pts:
        draw.ellipse([x - r, y - r, x + r, y + r], fill=colour)


def render_feather(name, size, colour, stroke_width, margin=0.14):
    """Rasterise a vendored Feather icon at `size`, in `colour`."""
    tree = ET.parse(os.path.join(FEATHER, name + ".svg"))
    root = tree.getroot()
    vb = [float(v) for v in root.get("viewBox", "0 0 24 24").split()]
    vw, vh = vb[2], vb[3]

    n = size * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    scale = n * (1 - margin * 2) / max(vw, vh)
    ox = oy = n * margin
    sw = stroke_width * scale

    def T(px, py):
        return (ox + (px - vb[0]) * scale, oy + (py - vb[1]) * scale)

    for el in root.iter():
        tag = el.tag.split("}")[-1]
        if tag == "line":
            pts = [T(float(el.get("x1")), float(el.get("y1"))),
                   T(float(el.get("x2")), float(el.get("y2")))]
            _stroke(draw, pts, colour, sw)
        elif tag in ("polyline", "polygon"):
            raw = [float(v) for v in re.split(r"[ ,]+", el.get("points").strip())]
            pts = [T(raw[i], raw[i + 1]) for i in range(0, len(raw) - 1, 2)]
            if tag == "polygon":
                pts.append(pts[0])
            _stroke(draw, pts, colour, sw)
        elif tag == "circle":
            cx, cy, r = float(el.get("cx")), float(el.get("cy")), float(el.get("r"))
            tcx, tcy = T(cx, cy)
            tr = r * scale
            if tr * 2 <= sw:          # tiny circles are dots, not rings
                draw.ellipse([tcx - sw / 2, tcy - sw / 2, tcx + sw / 2, tcy + sw / 2], fill=colour)
            else:
                draw.ellipse([tcx - tr, tcy - tr, tcx + tr, tcy + tr],
                             outline=colour, width=max(1, int(round(sw))))
        elif tag == "path":
            for line in _path_polylines(el.get("d")):
                _stroke(draw, [T(px, py) for px, py in line], colour, sw)

    return img.resize((size, size), Image.LANCZOS)


# --------------------------------------------------------- device / branding

def gradient_tile(size):
    n = size * SS
    grad = Image.new("RGBA", (n, n))
    px = grad.load()
    for y in range(n):
        for x in range(0, n, 4):
            t = (x / n * 0.45) + (y / n * 0.55)
            c = (int(TEAL[0] + (BLUE[0] - TEAL[0]) * t),
                 int(TEAL[1] + (BLUE[1] - TEAL[1]) * t),
                 int(TEAL[2] + (BLUE[2] - TEAL[2]) * t), 255)
            for dx in range(4):
                if x + dx < n:
                    px[x + dx, y] = c

    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, n - 1, n - 1], radius=int(n * 0.22), fill=255)
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    return out


def device_icon(size, inset=0.26):
    img = gradient_tile(size)
    draw, n = ImageDraw.Draw(img), size * SS
    left, right = n * inset, n * (1 - inset)
    bar_w = (right - left) / (len(BARS) * 2 - 1)
    max_h = n * (1 - inset * 2) * 1.05
    for i, h in enumerate(BARS):
        x0 = left + i * bar_w * 2
        height = max_h * h
        y0 = n / 2 - height / 2
        draw.rounded_rectangle([x0, y0, x0 + bar_w, y0 + height], bar_w / 2, fill=WHITE)
    return img.resize((size, size), Image.LANCZOS)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "www", "icons")
    out = os.path.abspath(out)
    os.makedirs(out, exist_ok=True)

    def save(img, name):
        img.save(os.path.join(out, name + ".png"))

    for s in [16, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 300, 32]:
        save(device_icon(s), f"device_{s}")
    save(device_icon(16), "device_sm")
    save(device_icon(32), "device_lg")
    for s in (70, 140, 300):
        save(device_icon(s), f"branding_{s}")

    for s in ROW_SIZES:
        for name, (source, sw) in ROW_GLYPHS.items():
            save(render_feather(source, s, IDLE, sw), f"{name}_{s}")

    for s in (70, 140):
        for name, (source, sw) in GLYPHS.items():
            save(render_feather(source, s, IDLE, sw), f"{name}_{s}")
        save(render_feather("shuffle", s, ACTIVE, GLYPHS["np_shuffle"][1]), f"np_shuffle_active_{s}")
        save(render_feather("repeat", s, ACTIVE, GLYPHS["np_repeat"][1]), f"np_repeat_active_{s}")

    print(f"wrote {len(os.listdir(out))} icons to {out}")


if __name__ == "__main__":
    main()
