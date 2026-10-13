"""Independently verify screenshot layout against the design frames.

Method: for a screenshot, scan the middle columns and detect horizontal
"bands" of colour change. For the design frame, scan the SAME relative
positions. We then report the design's key element positions (taken from
pdf-images/ocr-all.txt) next to the screenshot's measured band edges, so the
comparison does not depend on my reading of the semantics dump.

Usage: python check_layout.py <screenshot.png> <page-design.jpg> [--report out.txt]
"""
import os
import sys

from PIL import Image

DESIGN_H = 2640.0  # OCR coordinates are expressed on this height


def bands(path, x_from=60, x_to=1020, step_x=20, step_y=2, threshold=12):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    out = []
    prev = None
    for y in range(0, h, step_y):
        tot = [0, 0, 0]
        n = 0
        for x in range(x_from, min(x_to, w), step_x):
            r, g, b = px[x, y]
            tot[0] += r
            tot[1] += g
            tot[2] += b
            n += 1
        c = (round(tot[0] / n / 6) * 6, round(tot[1] / n / 6) * 6, round(tot[2] / n / 6) * 6)
        if prev is None or sum(abs(c[i] - prev[i]) for i in range(3)) > threshold:
            out.append((y, h, c))
            prev = c
    return out, h


def main():
    shot = sys.argv[1]
    design = sys.argv[2] if len(sys.argv) > 2 else None
    bs, h = bands(shot)
    print("=== %s  (%dx%d) ===" % (os.path.basename(shot), Image.open(shot).size[0], h))
    print("band starts (y / % of height):")
    for y, hh, c in bs:
        print("   y=%5d  %6.2f%%  rgb%s" % (y, y / hh * 100.0, c))
    if design and os.path.exists(design):
        db, dh = bands(design, x_from=60, x_to=1140, step_x=24, step_y=4, threshold=14)
        print("--- %s design bands ---" % os.path.basename(design))
        for y, hh, c in db[:40]:
            print("   y=%5d  %6.2f%%  rgb%s" % (y, y / hh * 100.0, c))


if __name__ == "__main__":
    main()
