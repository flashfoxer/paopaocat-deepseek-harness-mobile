# -*- coding: utf-8 -*-
"""把泡泡猫皮肤包里的吉祥物/图标转成 PNG，并合成深色底预览。
来源：dsh-paopaocat-skin（MIT, author paopaocat）—— 用户自有皮肤包。
用法：C:\\Python314\\python.exe install\\mascot-prep.py
"""
import os
from PIL import Image

SRC = r"C:\Users\25894\.dsh\profiles\web\node_modules\dsh-paopaocat-skin\assets"
OUT = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\design"

DARK = (24, 40, 40, 255)  # 品牌深青 #182828


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in ("mascot.webp", "icon.png"):
        p = os.path.join(SRC, name)
        if not os.path.exists(p):
            print("MISSING:", p)
            continue
        im = Image.open(p)
        print("%s: size=%s mode=%s format=%s" % (name, im.size, im.mode, im.format))
        if im.mode != "RGBA":
            im = im.convert("RGBA")
        alpha = im.getchannel("A")
        print("  alpha extrema = %s" % (alpha.getextrema(),))
        # 非透明像素的包围盒（判断主体实际占比、有没有多余留白）
        bbox = alpha.getbbox()
        print("  alpha bbox   = %s" % (bbox,))
        base = os.path.splitext(name)[0]
        im.save(os.path.join(OUT, base + ".png"))
        for size in (512, 192, 48):
            canvas = Image.new("RGBA", (size, size), DARK)
            r = im.copy()
            r.thumbnail((size, size), Image.LANCZOS)
            canvas.alpha_composite(r, ((size - r.width) // 2, (size - r.height) // 2))
            canvas.save(os.path.join(OUT, "%s-on-dark-%d.png" % (base, size)))
        print("  -> %s\\%s.png + on-dark previews" % (OUT, base))
    print("OUT =", OUT)


if __name__ == "__main__":
    main()
