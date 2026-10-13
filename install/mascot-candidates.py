# -*- coding: utf-8 -*-
"""把 dsh-client-ui-paopaocat（泡泡猫 UI 插件源码）里的吉祥物候选图拼成对照图。
用法：C:\\Python314\\python.exe install\\mascot-candidates.py
输出：design\\mascot-candidates\\contact-sheet.png
"""
import os
from PIL import Image, ImageDraw

PKG = r"D:\Programs\PaopaocatDSH\data-template\profiles\web\node_modules\dsh-client-ui-paopaocat"
OUT = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\design\mascot-candidates"

CANDIDATES = [
    ("assets/mascot-cat.webp", "吉祥物 mascot-cat.webp"),
    ("assets/mascot-cat.jpg", "吉祥物 mascot-cat.jpg"),
    ("assets/mascot-samples/A-photoreal.png", "样张A 写实"),
    ("assets/mascot-samples/B-3d-render.png", "样张B 3D渲染"),
    ("assets/mascot-samples/C-watercolor.png", "样张C 水彩"),
    ("assets/mascot-samples/D-anime.png", "样张D 动漫"),
    ("assets/default-wallpaper.jpg", "默认壁纸"),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    items = []
    for rel, label in CANDIDATES:
        p = os.path.join(PKG, rel.replace("/", os.sep))
        if not os.path.exists(p):
            print("MISSING:", p)
            continue
        im = Image.open(p)
        im.load()
        print("%-38s %sx%s mode=%s %.1fKB" % (rel, im.size[0], im.size[1], im.mode,
                                              os.path.getsize(p) / 1024))
        items.append((label, im))
        im.convert("RGBA").save(os.path.join(OUT, os.path.basename(rel) + ".png"))

    print("\n--- 标号 ---")
    for i, (label, im) in enumerate(items, 1):
        print("  #%d  %s  (%sx%s)" % (i, label, im.size[0], im.size[1]))

    CELL, PAD, COLS = 320, 14, 4
    rows = (len(items) + COLS - 1) // COLS
    W = COLS * CELL + (COLS + 1) * PAD
    H = rows * (CELL + 36) + PAD
    sheet = Image.new("RGB", (W, H), (18, 24, 28))
    d = ImageDraw.Draw(sheet)
    for i, (label, im) in enumerate(items):
        r, c = divmod(i, COLS)
        x = PAD + c * (CELL + PAD)
        y = PAD + r * (CELL + 36)
        cell = Image.new("RGBA", (CELL, CELL), (34, 46, 50, 255))
        t = im.convert("RGBA").copy()
        t.thumbnail((CELL - 12, CELL - 12), Image.LANCZOS)
        cell.alpha_composite(t, ((CELL - t.width) // 2, (CELL - t.height) // 2))
        sheet.paste(cell.convert("RGB"), (x, y))
        d.text((x + 2, y + CELL + 6), "#%d %s" % (i + 1, label), fill=(215, 235, 235))
    out = os.path.join(OUT, "contact-sheet.png")
    sheet.save(out)
    print("\n对照图 =", out, sheet.size)


if __name__ == "__main__":
    main()
