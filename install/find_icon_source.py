# -*- coding: utf-8 -*-
"""找出用户发来的这张图（图标）在磁盘上的出处。

视觉后端限流时用这个办法：不看图，直接做像素比对 —— 把目标图与本地所有
候选图片缩到同一尺寸后比平均色差，最接近的就是出处。
"""
import hashlib
import os
import sys

from PIL import Image

TARGET = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\.dsh-vision-router\artifacts\.runs\.vision-run-handoff\materialized\e1d45dfd6ebae4a987f2.png"

ROOTS = [
    r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile",
    r"C:\Users\25894\.dsh\profiles\web\node_modules\dsh-paopaocat-skin",
    r"D:\Programs\PaopaocatDSH\data-template\profiles\web\node_modules\dsh-client-ui-paopaocat",
]
EXTS = (".png", ".webp", ".jpg", ".jpeg", ".ico")


def signature(path, size=48):
    im = Image.open(path)
    im.load()
    im = im.convert("RGBA")
    bg = Image.new("RGBA", im.size, (128, 128, 128, 255))
    bg.alpha_composite(im)
    return bg.convert("RGB").resize((size, size), Image.LANCZOS)


def mean_diff(a, b):
    pa, pb = a.load(), b.load()
    total = 0
    for y in range(a.height):
        for x in range(a.width):
            ra, ga, ba = pa[x, y]
            rb, gb, bb = pb[x, y]
            total += abs(ra - rb) + abs(ga - gb) + abs(ba - bb)
    return total / (a.width * a.height * 3)


def main():
    tgt = Image.open(TARGET)
    tgt.load()
    print("目标图: size=%s mode=%s bytes=%d" % (tgt.size, tgt.mode, os.path.getsize(TARGET)))
    print("sha256 : %s" % hashlib.sha256(open(TARGET, "rb").read()).hexdigest())
    rgba = tgt.convert("RGBA")
    print("alpha  : %s" % (rgba.getchannel("A").getextrema(),))
    small = rgba.resize((64, 64))
    colors = small.getcolors(64 * 64) or []
    colors.sort(reverse=True)
    print("主色    : %s" % [(c, "#%02x%02x%02x" % col[:3]) for c, col in colors[:5]])
    tsig = signature(TARGET)

    cands = []
    for root in ROOTS:
        if not os.path.isdir(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for fn in filenames:
                if not fn.lower().endswith(EXTS):
                    continue
                p = os.path.join(dirpath, fn)
                try:
                    im = Image.open(p)
                    im.load()
                except Exception:
                    continue
                cands.append(p)
    print("候选图片数: %d" % len(cands))

    scored = []
    for p in cands:
        try:
            d = mean_diff(tsig, signature(p))
        except Exception:
            continue
        scored.append((d, p))
    scored.sort(key=lambda x: x[0])
    print("--- 最接近的 10 个 ---")
    for d, p in scored[:10]:
        try:
            sz = Image.open(p).size
        except Exception:
            sz = "?"
        print("  diff=%6.2f  %-12s %s" % (d, str(sz), p))


if __name__ == "__main__":
    sys.exit(main())
