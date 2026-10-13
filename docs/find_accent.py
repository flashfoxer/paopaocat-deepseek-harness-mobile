"""Locate a coloured element in a screenshot by hue, and report its y band.

Motivated by: the design's cyan brand colour (~ rgb(0,192,160)) only appears on
the input capsule's model button, the selected chip, and the logo. Scoring
"how cyan is this row" turns out to be a robust, model-free way to locate those
elements in a screenshot, independent of the semantics dump.
"""
import os
import sys

from PIL import Image


def cyan_profile(path, min_score=18):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    rows = []
    for y in range(h):
        score = 0
        for x in range(0, w, 3):
            r, g, b = px[x, y]
            # cyan-ish: green and blue both clearly above red
            if g > 90 and b > 70 and (g - r) > 30 and (b - r) > 15:
                score += 1
        rows.append(score)
    # group contiguous rows above threshold
    groups = []
    start = None
    for y, s in enumerate(rows):
        if s >= min_score and start is None:
            start = y
        elif s < min_score and start is not None:
            if y - start >= 3:
                groups.append((start, y - 1, max(rows[start:y])))
            start = None
    if start is not None:
        groups.append((start, h - 1, max(rows[start:])))
    return groups, w, h


def main():
    for p in sys.argv[1:]:
        if not os.path.exists(p):
            print("missing", p)
            continue
        groups, w, h = cyan_profile(p)
        print("=== %s (%dx%d) ===" % (os.path.basename(p), w, h))
        for a, b, mx in groups:
            print("   cyan y=%4d..%4d  (%5.2f%%..%5.2f%%)  peak=%d" %
                  (a, b, a / h * 100, b / h * 100, mx))


if __name__ == "__main__":
    main()
