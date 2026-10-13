#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Generate the "cute cat head" launcher icon and the matching adaptive icon.

Offline only (Pillow, no network). Re-runnable:
    C:\\Python314\\python.exe install\\make-icon.py

Outputs (all under app/android/app/src/main/res):
    mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png       48/72/96/144/192
    mipmap-{...}dpi/ic_launcher_round.png             same sizes, circular bg
    mipmap-anydpi-v26/ic_launcher.xml                 adaptive icon
    mipmap-anydpi-v26/ic_launcher_round.xml           adaptive icon (round)
    drawable/ic_launcher_foreground.xml               vector foreground (108dp)
    drawable/ic_launcher_background.xml               vector background (gradient)
    values/colors.xml                                 ic_launcher_background base colour
    install/icon-preview.png                          512px preview for review
    install/icon-preview-48px-zoom.png                48px render, 4x nearest zoom

--- What changed in this revision (and why) -----------------------------------
1. WHISKERS WERE DRAWN BUT INVISIBLE.
   Geometry was always there, but the whiskers stick out of the face onto the
   background and were painted in the same near-black as that background
   (#0E1A18 on #131719) -> they vanished. They are now painted in a light mint
   (WHISKER) so they read against the dark background, and they are thicker.
   NOTE: whiskers are drawn *before* the face, so their inner ends are covered
   by the face; only the part outside the cheek is ever visible. That is why a
   light colour on top of a cyan face cannot clash.

2. BACKGROUND WAS PURE-NEAR-BLACK -> the icon outline disappeared on a dark
   wallpaper. The background is now a gentle vertical gradient in the brand
   deep-teal family (#182828), top #284542 -> bottom #121D1C.
   Reason for these two stops: #182828 is the design-document's main colour, so
   the icon stays in brand; lifting the top stop to #284542 makes the silhouette
   clearly visible against a black wallpaper (relative luminance ~7x that of the
   old #131719), while the bottom stop keeps the icon from looking washed out.
   The gradient is deliberately subtle (one hue, small delta) -- it exists to
   give the shape an edge and a little volume, not to be a decorative gradient.

3. 48dp WAS MUDDY. Eye highlights (r=0.034) and the nose (0.076 x 0.041) shrink
   to ~1 px at 48dp, which LANCZOS smears into a grey smudge. Sizes <= 72 px now
   render a COMPACT variant: no blush, no mouth, bigger eyes, bigger highlight,
   a bigger/wider nose, and a minimum 2 px whisker stroke. 96 px and up keep the
   full detail set.

Safe zone: the adaptive-icon foreground is drawn on a 108x108 viewport and the
art is confined to the central 66x66 box. Because launchers may apply a CIRCLE
mask, the script checks every geometry point (plus the whisker stroke radius)
against the inscribed circle of radius 33 around (54,54) and fails loudly if
anything pokes out.
"""

import math
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "..", "app", "android", "app", "src", "main", "res")
RES = os.path.normpath(RES)

# ---------------------------------------------------------------- colours
# Background: brand deep teal, very gentle vertical gradient (see docstring #2).
BG_TOP = (0x28, 0x45, 0x42)
BG_BOTTOM = (0x12, 0x1D, 0x1C)
# The base colour kept in values/colors.xml (also the flat colour behind text).
BG_BASE = (0x18, 0x28, 0x28)

HEAD = (0x3F, 0xE0, 0xC8)
INNER_EAR = (0xA8, 0xF3, 0xE6)
DARK = (0x0E, 0x1A, 0x18)
HIGHLIGHT = (0xE8, 0xEF, 0xEC)
BLUSH = (0x23, 0xA7, 0x96)
# Light mint: whiskers must read against the dark background (docstring #1).
# Pushed brighter than the inner-ear tint so a ~2 px stroke still survives the
# LANCZOS downscale to 48 px instead of blending away into the teal.
WHISKER = (0xE0, 0xFB, 0xF2)


def rgb(c):
    return "#%02X%02X%02X" % c


# ------------------------------------------------- one geometry, normalized
# All coordinates are normalized inside the "art box" (0..1, y grows downward).
FACE = (0.500, 0.585, 0.345, 0.325)          # cx, cy, rx, ry
EAR_L = [(0.165, 0.350), (0.345, 0.055), (0.470, 0.260)]
EAR_L_IN = [(0.235, 0.315), (0.345, 0.155), (0.425, 0.265)]
EYE_L = (0.372, 0.545)
EYE_R = (0.628, 0.545)
EYE_RAD = 0.098
HL_L = (0.337, 0.505)
HL_R = (0.593, 0.505)
HL_RAD = 0.034
NOSE = [(0.462, 0.632), (0.538, 0.632), (0.500, 0.673)]
MOUTH_L = ((0.500, 0.673), (0.446, 0.712), (0.428, 0.685))   # p0, p1, control
MOUTH_R = ((0.500, 0.673), (0.554, 0.712), (0.572, 0.685))
WHISKERS_L = [
    [(0.044, 0.482), (0.268, 0.534)],
    [(0.034, 0.575), (0.268, 0.575)],
    [(0.048, 0.664), (0.268, 0.616)],
]
WHISKER_W = 0.036                             # stroke width, in art units
BLUSH_L = (0.255, 0.655, 0.062, 0.045)        # cx, cy, rx, ry

# --- compact variant (sizes <= COMPACT_MAX_PX), see docstring #3 ---------------
COMPACT_MAX_PX = 72
C_EYE_RAD = 0.118
C_HL_RAD = 0.052
C_HL_L = (0.340, 0.508)
C_HL_R = (0.596, 0.508)
C_NOSE = [(0.440, 0.622), (0.560, 0.622), (0.500, 0.694)]
C_WHISKER_W = 0.062
C_WHISKER_MIN_PX = 2

# adaptive-icon canvas: 108dp viewport, art confined to the central 66dp box
VIEWPORT = 108.0
SAFE = 66.0
SAFE_OFFSET = (VIEWPORT - SAFE) / 2.0         # 21.0
SAFE_CIRCLE_R = SAFE / 2.0                    # 33.0

# legacy launcher PNGs have no mask, so the art gets a little more room
LEGACY_ART_RATIO = 0.68


def mirror(pts):
    return [(1.0 - x, y) for (x, y) in pts]


def flip_circle(c):
    """Mirror a circle/ellipse tuple across x=0.5 (keeps rx/ry untouched)."""
    return (1.0 - c[0],) + tuple(c[1:])


def all_geometry_points():
    """Every point that must stay inside the adaptive-icon safe circle."""
    pts = list(EAR_L) + list(EAR_L_IN) + mirror(EAR_L) + mirror(EAR_L_IN)
    pts += [EYE_L, EYE_R, HL_L, HL_R, C_HL_L, C_HL_R]
    pts += [(EYE_L[0] - C_EYE_RAD, EYE_L[1]), (EYE_L[0] + C_EYE_RAD, EYE_L[1])]
    pts += [(EYE_R[0] - C_EYE_RAD, EYE_R[1]), (EYE_R[0] + C_EYE_RAD, EYE_R[1])]
    pts += NOSE + C_NOSE
    pts += [MOUTH_L[1], MOUTH_R[1]]
    margin = max(WHISKER_W, C_WHISKER_W) / 2.0
    for w in WHISKERS_L + [mirror(w) for w in WHISKERS_L]:
        for (x, y) in w:
            pts += [(x, y - margin), (x, y + margin)]
    pts += [(FACE[0] - FACE[2], FACE[1]), (FACE[0] + FACE[2], FACE[1]),
            (FACE[0], FACE[1] - FACE[3]), (FACE[0], FACE[1] + FACE[3])]
    pts += [(BLUSH_L[0] - BLUSH_L[2], BLUSH_L[1]), (BLUSH_L[0], BLUSH_L[1] + BLUSH_L[3])]
    br = flip_circle(BLUSH_L)
    pts += [(br[0] + br[2], br[1]), (br[0], br[1] + br[3])]
    return pts


def check_safe_zone():
    """Farthest geometry point from the viewport centre, in 108dp units."""
    worst = 0.0
    worst_pt = None
    for (x, y) in all_geometry_points():
        vx = SAFE_OFFSET + x * SAFE
        vy = SAFE_OFFSET + y * SAFE
        r = math.hypot(vx - VIEWPORT / 2.0, vy - VIEWPORT / 2.0)
        if r > worst:
            worst, worst_pt = r, (round(vx, 2), round(vy, 2))
    return worst, worst_pt


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


# ------------------------------------------------------------- PNG renderer
def render_png(size, round_bg=False, compact=False):
    ss = 8
    s = size * ss
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img, "RGBA")

    # background: vertical brand-teal gradient, clipped to a rounded square
    # (or a full circle for the round icon). Drawn as per-row lines so the same
    # code path produces both shapes; then the outside is punched out.
    grad = Image.new("RGB", (1, s))
    gd = ImageDraw.Draw(grad)
    for y in range(s):
        gd.point((0, y), fill=lerp(BG_TOP, BG_BOTTOM, y / max(1, s - 1)))
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, s - 1, s - 1], radius=0.24 * s, fill=255)
    if round_bg:
        mask = Image.new("L", (s, s), 0)
        ImageDraw.Draw(mask).ellipse([0, 0, s - 1, s - 1], fill=255)
    img.paste(grad.resize((s, s), Image.NEAREST), (0, 0), mask)

    art = LEGACY_ART_RATIO * s
    off = (s - art) / 2.0

    eye_rad = C_EYE_RAD if compact else EYE_RAD
    hl_rad = C_HL_RAD if compact else HL_RAD
    hl_pts = (C_HL_L, C_HL_R) if compact else (HL_L, HL_R)
    nose = C_NOSE if compact else NOSE
    whisker_w = C_WHISKER_W if compact else WHISKER_W

    def P(pt):
        return (off + pt[0] * art, off + pt[1] * art)

    def poly(pts, fill):
        d.polygon([P(p) for p in pts], fill=fill)

    # 1. whiskers first: the face then covers their inner ends, so they read
    #    as growing out from behind the cheeks.
    w = max(1, int(round(whisker_w * art)))
    if compact:
        w = max(C_WHISKER_MIN_PX, w)
    for wk in WHISKERS_L + [mirror(x) for x in WHISKERS_L]:
        d.line([P(wk[0]), P(wk[1])], fill=WHISKER, width=w, joint="curve")
        # rounded caps
        for p in (wk[0], wk[1]):
            x, y = P(p)
            d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=WHISKER)

    # 2. ears (outer then lighter inner)
    for ear in (EAR_L, mirror(EAR_L)):
        poly(ear, HEAD)
    for ear in (EAR_L_IN, mirror(EAR_L_IN)):
        poly(ear, INNER_EAR)

    # 3. face
    cx, cy, rx, ry = FACE
    d.ellipse([off + (cx - rx) * art, off + (cy - ry) * art,
               off + (cx + rx) * art, off + (cy + ry) * art], fill=HEAD)

    # 4. blush (soft, under the eyes). Skipped when compact: at 48dp it is a
    #    grey smear on the cheeks rather than blush.
    if not compact:
        for b in (BLUSH_L, flip_circle(BLUSH_L)):
            bx, by, brx, bry = b
            d.ellipse([off + (bx - brx) * art, off + (by - bry) * art,
                       off + (bx + brx) * art, off + (by + bry) * art],
                      fill=BLUSH + (140,))

    # 5. eyes + highlights
    r = eye_rad * art
    for e in (EYE_L, EYE_R):
        ex, ey = P(e)
        d.ellipse([ex - r, ey - r, ex + r, ey + r], fill=DARK)
    hr = hl_rad * art
    for h in hl_pts:
        hx, hy = P(h)
        d.ellipse([hx - hr, hy - hr, hx + hr, hy + hr], fill=HIGHLIGHT)

    # 6. nose (+ mouth only on the detailed sizes)
    poly(nose, DARK)
    if not compact:
        mw = max(1, int(round(WHISKER_W * 0.72 * art)))
        for (p0, p1, ctrl) in (MOUTH_L, MOUTH_R):
            # sample the quadratic as a polyline (Pillow has no bezier)
            pts = []
            for i in range(13):
                t = i / 12.0
                x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * ctrl[0] + t * t * p1[0]
                y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * ctrl[1] + t * t * p1[1]
                pts.append(P((x, y)))
            d.line(pts, fill=DARK, width=mw, joint="curve")

    return img.resize((size, size), Image.LANCZOS)


# ------------------------------------------------------- SVG path emitters
def vp(pt):
    """art-box point -> 108dp viewport point."""
    return (SAFE_OFFSET + pt[0] * SAFE, SAFE_OFFSET + pt[1] * SAFE)


def f(v):
    return ("%.3f" % v).rstrip("0").rstrip(".")


def path_poly(pts):
    head = "M%s,%s" % (f(vp(pts[0])[0]), f(vp(pts[0])[1]))
    body = "".join(" L%s,%s" % (f(vp(p)[0]), f(vp(p)[1])) for p in pts[1:])
    return head + body + " Z"


def path_ellipse(cx, cy, rx, ry):
    x0, y0 = vp((cx - rx, cy))
    x1, y1 = vp((cx + rx, cy))
    return ("M%s,%s A%s,%s 0 1 0 %s,%s A%s,%s 0 1 0 %s,%s Z"
            % (f(x0), f(y0), f(rx * SAFE), f(ry * SAFE), f(x1), f(y1),
               f(rx * SAFE), f(ry * SAFE), f(x0), f(y0)))


def path_circle(c, r):
    return path_ellipse(c[0], c[1], r, r)


def path_line(a, b):
    return "M%s,%s L%s,%s" % (f(vp(a)[0]), f(vp(a)[1]), f(vp(b)[0]), f(vp(b)[1]))


def path_quad(p0, p1, ctrl):
    return "M%s,%s Q%s,%s %s,%s" % (
        f(vp(p0)[0]), f(vp(p0)[1]),
        f(vp(ctrl)[0]), f(vp(ctrl)[1]),
        f(vp(p1)[0]), f(vp(p1)[1]))


def vector_foreground_xml():
    stroke = f(WHISKER_W * SAFE)
    parts = []
    parts.append('    <!-- whiskers: light mint so they read on the dark background;')
    parts.append('         drawn first, so the face covers their inner ends -->')
    for wk in WHISKERS_L + [mirror(x) for x in WHISKERS_L]:
        parts.append('    <path android:strokeColor="#FF%s" android:strokeWidth="%s"'
                     ' android:strokeLineCap="round" android:pathData="%s"/>'
                     % (rgb(WHISKER)[1:], stroke, path_line(wk[0], wk[1])))
    parts.append('    <!-- ears: outer head colour, lighter inner ear -->')
    for ear in (EAR_L, mirror(EAR_L)):
        parts.append('    <path android:fillColor="#FF%s" android:pathData="%s"/>'
                     % (rgb(HEAD)[1:], path_poly(ear)))
    for ear in (EAR_L_IN, mirror(EAR_L_IN)):
        parts.append('    <path android:fillColor="#FF%s" android:pathData="%s"/>'
                     % (rgb(INNER_EAR)[1:], path_poly(ear)))
    parts.append('    <!-- face -->')
    parts.append('    <path android:fillColor="#FF%s" android:pathData="%s"/>'
                 % (rgb(HEAD)[1:], path_ellipse(*FACE)))
    parts.append('    <!-- blush (optional, same hue pushed darker) -->')
    for b in (BLUSH_L, flip_circle(BLUSH_L)):
        parts.append('    <path android:fillColor="#8C%s" android:pathData="%s"/>'
                     % (rgb(BLUSH)[1:], path_ellipse(*b)))
    parts.append('    <!-- eyes + highlights -->')
    for e in (EYE_L, EYE_R):
        parts.append('    <path android:fillColor="#FF%s" android:pathData="%s"/>'
                     % (rgb(DARK)[1:], path_circle(e, EYE_RAD)))
    for h in (HL_L, HL_R):
        parts.append('    <path android:fillColor="#FF%s" android:pathData="%s"/>'
                     % (rgb(HIGHLIGHT)[1:], path_circle(h, HL_RAD)))
    parts.append('    <!-- nose + mouth -->')
    parts.append('    <path android:fillColor="#FF%s" android:pathData="%s"/>'
                 % (rgb(DARK)[1:], path_poly(NOSE)))
    for (p0, p1, ctrl) in (MOUTH_L, MOUTH_R):
        parts.append('    <path android:strokeColor="#FF%s" android:strokeWidth="%s"'
                     ' android:strokeLineCap="round" android:pathData="%s"/>'
                     % (rgb(DARK)[1:], f(WHISKER_W * 0.72 * SAFE), path_quad(p0, p1, ctrl)))

    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<!-- Generated by install/make-icon.py. Do not edit by hand. -->\n'
            '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            '    android:width="108dp"\n'
            '    android:height="108dp"\n'
            '    android:viewportWidth="108"\n'
            '    android:viewportHeight="108">\n'
            + "\n".join(parts) + "\n</vector>\n")


# The adaptive background is a gradient drawable (not a flat colour) so the icon
# keeps a visible silhouette on a pure-black wallpaper. Android gradient angle
# 270 == top-to-bottom.
BACKGROUND_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by install/make-icon.py. Do not edit by hand.
     Brand deep-teal vertical gradient: top #284542 to bottom #121D1C.
     A flat near-black background made the icon outline vanish on dark wallpapers. -->
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <gradient
        android:angle="270"
        android:startColor="#FF%(top)s"
        android:endColor="#FF%(bottom)s"
        android:type="linear"/>
</shape>
""" % {"top": rgb(BG_TOP)[1:], "bottom": rgb(BG_BOTTOM)[1:]}

ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by install/make-icon.py. Do not edit by hand. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
</adaptive-icon>
"""

COLORS_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by install/make-icon.py. Brand deep-teal base colour for the
     adaptive launcher icon. The drawn background is drawable/ic_launcher_background
     (a gradient of this colour); this value is the flat fallback and the value the
     launcher theme can read.
     NOTE: XML comments must never contain a double hyphen. -->
<resources>
    <color name="ic_launcher_background">#FF%(base)s</color>
</resources>
""" % {"base": rgb(BG_BASE)[1:]}

DENSITIES = [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]


def write(path, text, encoding="utf-8"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding=encoding, newline="\n") as fh:
        fh.write(text)
    print("  wrote %s" % os.path.relpath(path, RES).replace("\\", "/"))


def audit_small_render(img, label):
    """Cheap, vision-free sanity check on a rendered icon.

    Classifies every opaque pixel by its nearest reference colour (rather than a
    per-channel tolerance, which is unreliable here: BG_TOP sits only ~26 levels
    from DARK, so a loose tolerance would mis-classify the eyes as background).

    Verifies the three things this revision was about:
      * the background is the new teal family (not near-black),
      * the light-mint whisker colour actually survives the downscale,
      * the dark eye/nose colour still exists (features did not wash out).
    """
    px = img.convert("RGBA").load()
    size = img.size[0]
    refs = {
        "bg": (BG_TOP, BG_BOTTOM, BG_BASE),
        "head": (HEAD,),
        "whisker": (WHISKER,),
        "dark": (DARK,),
        "highlight": (HIGHLIGHT,),
        "inner_ear": (INNER_EAR,),
    }
    counts = {k: 0 for k in refs}

    def dist2(a, b):
        return sum((a[i] - b[i]) ** 2 for i in range(3))

    for y in range(size):
        for x in range(size):
            c = px[x, y]
            if c[3] < 200:
                continue
            best_k = None
            best_d = 1 << 30
            for k, palette in refs.items():
                for ref in palette:
                    d = dist2(c, ref)
                    if d < best_d:
                        best_d, best_k = d, k
            if best_d <= 45 * 45:
                counts[best_k] += 1

    total = size * size
    lum = 0.2126 * BG_TOP[0] + 0.7152 * BG_TOP[1] + 0.0722 * BG_TOP[2]
    old_lum = 0.2126 * 0x13 + 0.7152 * 0x17 + 0.0722 * 0x19
    print("  [audit %s %dpx] bg=%d (%.0f%%) head=%d whisker=%d dark=%d hl=%d ear=%d"
          % (label, size, counts["bg"], 100.0 * counts["bg"] / total,
             counts["head"], counts["whisker"], counts["dark"],
             counts["highlight"], counts["inner_ear"]))
    print("                 lum(icon bg top)=%.1f vs old near-black %.1f (%.1fx)"
          % (lum, old_lum, lum / old_lum))
    assert counts["bg"] > total * 0.15, "%s: background colour missing" % label
    assert counts["head"] > 0, "%s: cat head colour missing" % label
    assert counts["whisker"] > 0, "%s: no whisker pixels survived" % label
    assert counts["dark"] > 0, "%s: eyes/nose washed out" % label


def main():
    print("[icon] res dir: %s" % RES)
    r, pt = check_safe_zone()
    print("[icon] farthest art point from centre: %.2f dp at %s (safe circle radius %.1f)"
          % (r, pt, SAFE_CIRCLE_R))
    if r > SAFE_CIRCLE_R:
        raise SystemExit("[icon] FAIL: art pokes outside the adaptive-icon safe circle "
                         "(would be clipped by a round mask)")

    for name, px in DENSITIES:
        compact = px <= COMPACT_MAX_PX
        d = os.path.join(RES, "mipmap-%s" % name)
        render_png(px, compact=compact).save(os.path.join(d, "ic_launcher.png"))
        print("  wrote mipmap-%s/ic_launcher.png (%dpx%s)"
              % (name, px, ", compact" if compact else ""))
        render_png(px, round_bg=True, compact=compact).save(
            os.path.join(d, "ic_launcher_round.png"))
        print("  wrote mipmap-%s/ic_launcher_round.png (%dpx)" % (name, px))

    anydpi = os.path.join(RES, "mipmap-anydpi-v26")
    write(os.path.join(anydpi, "ic_launcher.xml"), ADAPTIVE_XML)
    write(os.path.join(anydpi, "ic_launcher_round.xml"), ADAPTIVE_XML)
    write(os.path.join(RES, "drawable", "ic_launcher_foreground.xml"), vector_foreground_xml())
    write(os.path.join(RES, "drawable", "ic_launcher_background.xml"), BACKGROUND_XML)
    write(os.path.join(RES, "values", "colors.xml"), COLORS_XML)

    preview = os.path.join(HERE, "icon-preview.png")
    render_png(512).save(preview)
    print("  wrote install/icon-preview.png (512px)")

    # 48px audit + 4x nearest zoom (nearest, not smooth, so the review image shows
    # the real pixels the launcher would show).
    img48 = render_png(48, compact=True)
    audit_small_render(img48, "launcher")
    img48.resize((192, 192), Image.NEAREST).save(
        os.path.join(HERE, "icon-preview-48px-zoom.png"))
    print("  wrote install/icon-preview-48px-zoom.png (48px @4x nearest)")

    # A second audit on the round variant, because it has less background area.
    audit_small_render(render_png(48, round_bg=True, compact=True), "round")
    print("[icon] done")


if __name__ == "__main__":
    main()
