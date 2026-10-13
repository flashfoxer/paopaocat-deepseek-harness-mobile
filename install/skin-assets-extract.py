# -*- coding: utf-8 -*-
"""从泡泡猫皮肤 dsh-paopaocat-skin/lib/client.js 里解出所有内嵌图片，
拼成一张带标号的对照图，便于用户指认。
用法：C:\\Python314\\python.exe install\\skin-assets-extract.py
"""
import base64
import hashlib
import io
import os
import re

SRC = r"C:\Users\25894\.dsh\profiles\web\node_modules\dsh-paopaocat-skin\lib\client.js"
SKIN_ASSETS = r"C:\Users\25894\.dsh\profiles\web\node_modules\dsh-paopaocat-skin\assets"
OUT = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\design\skin-assets"

DATA_RE = re.compile(r"data:image/(webp|png|jpeg|jpg);base64,([A-Za-z0-9+/=]+)")
# 往前找线索：--ppc-xxx / id="xxx" / 变量名
HINT_RE = re.compile(r"(--ppc-[A-Za-z0-9_-]+)|setProperty\(\s*'([^']+)'|(\w+)\s*\.\s*(?:src|href)\s*=|id\s*=\s*['\"]([^'\"]+)['\"]")


def hint_for(text, pos):
    window = text[max(0, pos - 600):pos]
    hints = []
    for m in HINT_RE.finditer(window):
        for g in m.groups():
            if g:
                hints.append(g)
    return hints[-1] if hints else "unknown"


def main():
    os.makedirs(OUT, exist_ok=True)
    text = open(SRC, "r", encoding="utf-8", errors="replace").read()
    print("client.js 长度 =", len(text))

    seen = {}
    items = []
    for m in DATA_RE.finditer(text):
        fmt, b64 = m.group(1), m.group(2)
        try:
            raw = base64.b64decode(b64 + "=" * (-len(b64) % 4))
        except Exception as e:
            print("  decode fail:", e)
            continue
        digest = hashlib.sha256(raw).hexdigest()[:12]
        if digest in seen:
            continue
        seen[digest] = True
        try:
            from PIL import Image
            im = Image.open(io.BytesIO(raw))
            im.load()
        except Exception as e:
            print("  not an image (%s, %d bytes): %s" % (fmt, len(raw), e))
            continue
        hint = hint_for(text, m.start())
        idx = len(items) + 1
        items.append((idx, hint, im, digest, fmt, len(raw)))
        print("  [%d] %-22s %-6s %sx%s mode=%s %d bytes sha=%s"
              % (idx, hint, fmt, im.size[0], im.size[1], im.mode, len(raw), digest))

    # 另加磁盘上的 assets
    for name in ("mascot.webp", "icon.png"):
        p = os.path.join(SKIN_ASSETS, name)
        if not os.path.exists(p):
            continue
        from PIL import Image
        im = Image.open(p)
        im.load()
        idx = len(items) + 1
        items.append((idx, "assets/" + name, im, "", name, os.path.getsize(p)))
        print("  [%d] %-22s %-6s %sx%s mode=%s %d bytes"
              % (idx, "assets/" + name, im.format, im.size[0], im.size[1], im.mode, os.path.getsize(p)))

    # 保存单张
    for idx, hint, im, digest, fmt, nbytes in items:
        safe = re.sub(r"[^A-Za-z0-9_.-]", "_", hint)
        im.convert("RGBA").save(os.path.join(OUT, "%02d-%s.png" % (idx, safe)))

    # 拼对照图
    from PIL import Image, ImageDraw
    CELL, PAD, COLS = 300, 14, 4
    rows = (len(items) + COLS - 1) // COLS
    W = COLS * CELL + (COLS + 1) * PAD
    H = rows * (CELL + 34) + PAD
    sheet = Image.new("RGB", (W, H), (18, 24, 28))
    d = ImageDraw.Draw(sheet)
    for i, (idx, hint, im, digest, fmt, nbytes) in enumerate(items):
        r, c = divmod(i, COLS)
        x = PAD + c * (CELL + PAD)
        y = PAD + r * (CELL + 34)
        cell = Image.new("RGBA", (CELL, CELL), (36, 48, 52, 255))
        t = im.convert("RGBA").copy()
        t.thumbnail((CELL - 12, CELL - 12), Image.LANCZOS)
        cell.alpha_composite(t, ((CELL - t.width) // 2, (CELL - t.height) // 2))
        sheet.paste(cell.convert("RGB"), (x, y))
        label = "#%d  %s  %sx%s" % (idx, hint, im.size[0], im.size[1])
        d.text((x + 2, y + CELL + 4), label[:52], fill=(210, 230, 230))
    out = os.path.join(OUT, "contact-sheet.png")
    sheet.save(out)
    print("对照图 =", out, sheet.size)
    print("单独文件目录 =", OUT)


if __name__ == "__main__":
    main()
