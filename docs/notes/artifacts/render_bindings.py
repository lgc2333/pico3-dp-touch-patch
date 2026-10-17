"""Overlay an OpenVR input profile's binding_image_point dots on the art it references.

SteamVR draws the "test controller" highlight boxes at those coordinates, so this is how
you check whether a driver's preset actually lines up with its own binding UI image
(see docs/notes/04_a-driver-inputs.md, "输入声明层").

Usage:
    uv run --with svglib --with reportlab --with rlPyCairo --with pycairo \
        python render_bindings.py <profile.json> <art.svg> [out.png]
"""

import json
import re
import sys

from reportlab.graphics import renderPM
from reportlab.graphics.shapes import Circle, String
from svglib.svglib import svg2rlg

DOT = (1, 0.85, 0.2)  # 美术图是白色描边，点用暖黄
BG = 0x1E1E1E


def svg_px_size(svg_path):
    """Original width/height in px: svglib converts to points (x0.75) otherwise."""
    with open(svg_path, encoding="utf-8", errors="replace") as handle:
        head = handle.read(400)
    w = re.search(r'width="([\d.]+)"', head)
    h = re.search(r'height="([\d.]+)"', head)
    if not w or not h:
        return None
    return float(w.group(1)), float(h.group(1))


def main(profile_path, svg_path, out_path):
    drawing = svg2rlg(svg_path)
    if drawing is None:
        raise SystemExit(f"[X] svg2rlg cannot read {svg_path}")
    size = svg_px_size(svg_path)
    if size:
        drawing.width, drawing.height = size
    height = drawing.height

    with open(profile_path, encoding="utf-8") as handle:
        profile = json.load(handle)
    count = 0
    for key, source in profile.get("input_source", {}).items():
        point = source.get("binding_image_point")
        if not point:
            continue
        x, y = point[0], point[1]
        # SVG y grows downwards, reportlab upwards
        drawing.add(
            Circle(x, height - y, 3, fillColor=None, strokeColor=DOT, strokeWidth=1)
        )
        drawing.add(
            String(
                x + 5,
                height - y - 3,
                key.replace("/input/", ""),
                fontSize=9,
                fillColor=DOT,
            )
        )
        count += 1

    renderPM.drawToFile(drawing, out_path, fmt="PNG", dpi=72, bg=BG)
    print(
        f"[+] {svg_path}: {drawing.width:.0f}x{height:.0f}, {count} points -> {out_path}"
    )


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    out = sys.argv[3] if len(sys.argv) > 3 else "bindings_points.png"
    main(sys.argv[1], sys.argv[2], out)
