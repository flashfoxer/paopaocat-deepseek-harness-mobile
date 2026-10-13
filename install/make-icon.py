# -*- coding: utf-8 -*-
"""Paopaocat launcher icon generator.

## 两个去处，分别用不同的图（用户 2026-10-03 明确要求）

| 去处 | 用哪张图 |
|---|---|
| **桌面/启动器图标** + 自适应图标 | `design/launcher-icon-source.png`（来自 `paopaocat.ico`，256×256 圆角徽章） |
| **App 内首页 logo** | **小白猫**（`mascot-cat.webp` 的抠图）→ `app/assets/images/paopaocat_mascot.png` |

> 用户原话：「首页欢迎来到泡泡猫的 DSH 上边的图标还是换回小白猫，
> **就这一个地方换就可以了**」—— 所以桌面图标不动，只有 App 内那一处换回猫。
>
> 更早的历史：猫曾经同时当桌面图标；后来用户指定桌面图标换成 `paopaocat.ico` 那张；
> 现在又把 App 内的换回猫。**以本表为准**，别凭印象改。

## 产出

1. 自适应图标前景：`res/drawable-<dpi>/ic_launcher_foreground.png`
   （108dp 画布，图案放在中央安全区，其余透明）
2. 传统方形 / 圆形：`res/mipmap-<dpi>/ic_launcher(.round).png`（48/72/96/144/192）
   —— 新图是**不透明整图**，所以这里用**满幅 cover + 居中裁切**（不是贴到渐变底上）
3. 自适应图标背景：`res/drawable/ic_launcher_background.xml` + `res/values/colors.xml`
   （写成与新图同色系的深蓝渐变 —— 脚本是唯一真源，不要再手改那两个文件）
4. App 内品牌 logo：`app/assets/images/paopaocat_logo.png`（同一张图 + 圆角）
5. 预览：`install/icon-preview.png`、`install/icon-preview-48px-zoom.png`

⚠️ **分辨率**：源图来自 `paopaocat.ico` 的 256×256 帧，够用（xxxhdpi 传统图标
192、自适应前景 432）。极小的 mdpi(48px) 会做一次轻度锐化。有更大原图更好，
换掉 `design/launcher-icon-source.png` 再跑一次即可，脚本不用改。

Run:  C:\\Python314\\python.exe install\\make-icon.py
"""
import os

from PIL import Image, ImageDraw, ImageFilter

# ---- 来源 ----------------------------------------------------------------
PROJECT = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile"
SRC_LAUNCHER = os.path.join(PROJECT, "design", "launcher-icon-source.png")
# App 内首页 logo 用的那只小白猫（用户要求换回来）
SRC_MASCOT_REMOTE = r"D:\Programs\PaopaocatDSH\data-template\profiles\web\node_modules\dsh-client-ui-paopaocat\assets\mascot-cat.webp"
SRC_MASCOT_PINNED = os.path.join(PROJECT, "design", "mascot-cat-source.webp")

APP = os.path.join(PROJECT, "app")
RES = os.path.join(APP, "android", "app", "src", "main", "res")
APP_IMAGES = os.path.join(APP, "assets", "images")
INSTALL = os.path.join(PROJECT, "install")

# ---- 参数 ----------------------------------------------------------------
DENSITIES = [("mdpi", 1.0), ("hdpi", 1.5), ("xhdpi", 2.0), ("xxhdpi", 3.0), ("xxxhdpi", 4.0)]
SS = 4                 # 超采样倍数：小尺寸下边缘更干净
LEGACY_FILL = 0.92     # 传统图标里图案占画布比例（源图是圆角徽章，铺到 92% 刚好不留白边）
ADAPTIVE_FILL = 0.80   # 自适应图标里图案占 108dp 画布的比例
# 说明：源图的圆角是**深蓝**，与背景同色，所以即使被启动器的圆形遮罩切到角也看不出来；
# 调大 FILL 能让主体更大更清楚，这是刻意的（而不是"把整枚徽章缩到安全区里"）。
SHARPEN_BELOW = 97     # 小于这个像素尺寸时做一次轻度锐化
# 自适应图标的背景色：取自新图标的主色（深蓝 #16203F）
BG_TOP = (27, 39, 80)      # #1B2750
BG_BOTTOM = (22, 32, 63)   # #16203F
BG_FLAT = (22, 32, 63)     # values/colors.xml 里的纯色回退


def cover(art, w, h):
    """等比放大到铺满 w x h，再居中裁切（满幅）。"""
    r = max(w / art.width, h / art.height)
    resized = art.resize(
        (max(1, round(art.width * r)), max(1, round(art.height * r))),
        Image.LANCZOS,
    )
    left = (resized.width - w) // 2
    top = (resized.height - h) // 2
    return resized.crop((left, top, left + w, top + h))


def fit(art, box_w, box_h):
    """等比缩放到完全放进 box 内（不裁切）。"""
    r = min(box_w / art.width, box_h / art.height)
    return art.resize(
        (max(1, round(art.width * r)), max(1, round(art.height * r))),
        Image.LANCZOS,
    )


def gradient(size):
    w, h = size
    strip = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        strip.putpixel(
            (0, y),
            tuple(round(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3)),
        )
    return strip.resize((w, h))


def load_launcher_art():
    if not os.path.exists(SRC_LAUNCHER):
        raise SystemExit("缺少启动器图标源：%s" % SRC_LAUNCHER)
    im = Image.open(SRC_LAUNCHER).convert("RGBA")
    im.load()
    # 裁成正方形（新图 83x86，差 3px）
    side = min(im.width, im.height)
    left = (im.width - side) // 2
    top = (im.height - side) // 2
    art = im.crop((left, top, left + side, top + side))
    print("launcher src: %s  size=%sx%s" % (SRC_LAUNCHER, im.width, im.height))
    print("launcher art: %sx%s（居中裁成正方形）" % (art.width, art.height))
    return art


def load_mascot():
    """App 内首页 logo：那只白色的卧猫（抠图，带透明通道）。"""
    src = SRC_MASCOT_REMOTE if os.path.exists(SRC_MASCOT_REMOTE) else SRC_MASCOT_PINNED
    im = Image.open(src).convert("RGBA")
    im.load()
    bbox = im.getchannel("A").getbbox()
    cat = im.crop(bbox) if bbox else im
    print("mascot src  : %s  size=%sx%s alpha bbox=%s" % (src, im.width, im.height, bbox))
    print("mascot art  : %sx%s（抠出的本体）" % (cat.width, cat.height))
    return cat


def rounded_logo(art, size=256, radius_ratio=0.18):
    """App 内品牌 logo：整图缩到 size 后加圆角。

    为什么加圆角：这张图是**不透明整图**，直接放在深色首页上会像"贴了一张方图"；
    加圆角后它读起来是一个 App 图标，和桌面上的样子也更一致。
    """
    img = cover(art, size, size)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=round(size * radius_ratio), fill=255
    )
    img.putalpha(mask)
    return img


def legacy_icon(size, art, round_icon=False):
    """传统方形/圆形图标：深蓝渐变底 + 居中的徽章主体。

    为什么不是"满幅铺满"：源图是一枚**四角透明**的圆角徽章，
    直接铺满会让 Android 9 之前的老启动器把它当成形状怪异的图标。
    铺到 LEGACY_FILL 后四边有同色系底，任何启动器上都是一个完整的方形图标。
    """
    s = size * SS
    canvas = gradient((s, s)).convert("RGBA")
    a = fit(art, s * LEGACY_FILL, s * LEGACY_FILL)
    canvas.alpha_composite(a, ((s - a.width) // 2, (s - a.height) // 2))
    if round_icon:
        mask = Image.new("L", (s, s), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, s - 1, s - 1), fill=255)
        canvas.putalpha(mask)
    out = canvas.resize((size, size), Image.LANCZOS)
    if size < SHARPEN_BELOW:
        out = out.filter(ImageFilter.UnsharpMask(radius=1.1, percent=70, threshold=3))
    return out


def adaptive_foreground(density, art):
    """108dp 画布，图案居中放进安全区，其余透明（背景由 XML 提供）。"""
    s = int(round(108 * density))
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    a = fit(art, s * ADAPTIVE_FILL, s * ADAPTIVE_FILL)
    canvas.alpha_composite(a, ((s - a.width) // 2, (s - a.height) // 2))
    return canvas


def write_background_resources():
    """把自适应背景写进 res（脚本是唯一真源，所以每次都重写）。"""
    drawable = os.path.join(RES, "drawable", "ic_launcher_background.xml")
    colors = os.path.join(RES, "values", "colors.xml")
    os.makedirs(os.path.dirname(drawable), exist_ok=True)
    os.makedirs(os.path.dirname(colors), exist_ok=True)
    with open(drawable, "w", encoding="utf-8") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<!-- Generated by install/make-icon.py. Do not edit by hand.\n'
            '     Deep-blue gradient matching the launcher artwork background.\n'
            '     NOTE: XML comments must never contain a double hyphen. -->\n'
            '<shape xmlns:android="http://schemas.android.com/apk/res/android"\n'
            '    android:shape="rectangle">\n'
            '    <gradient\n'
            '        android:angle="270"\n'
            '        android:startColor="#FF%02X%02X%02X"\n'
            '        android:endColor="#FF%02X%02X%02X"\n'
            '        android:type="linear"/>\n'
            '</shape>\n'
            % (BG_TOP[0], BG_TOP[1], BG_TOP[2], BG_BOTTOM[0], BG_BOTTOM[1], BG_BOTTOM[2])
        )
    with open(colors, "w", encoding="utf-8") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<!-- Generated by install/make-icon.py. -->\n'
            '<resources>\n'
            '    <color name="ic_launcher_background">#FF%02X%02X%02X</color>\n'
            '</resources>\n'
            % (BG_FLAT[0], BG_FLAT[1], BG_FLAT[2])
        )
    print("background  : drawable/ic_launcher_background.xml + values/colors.xml 已重写（深蓝 #%02X%02X%02X）"
          % BG_FLAT)


def main():
    art = load_launcher_art()

    # 旧的手绘矢量前景必须删掉，否则会盖住位图前景
    stale = os.path.join(RES, "drawable", "ic_launcher_foreground.xml")
    if os.path.exists(stale):
        os.remove(stale)
        print("removed     : drawable/ic_launcher_foreground.xml（旧手绘矢量猫）")

    write_background_resources()

    # 1. 自适应前景
    for dname, d in DENSITIES:
        outdir = os.path.join(RES, "drawable-" + dname)
        os.makedirs(outdir, exist_ok=True)
        fg = adaptive_foreground(d, art)
        fg.save(os.path.join(outdir, "ic_launcher_foreground.png"))
        print("foreground  : drawable-%-8s %sx%s" % (dname, fg.width, fg.height))

    # 2. 传统方形 + 圆形
    for dname, d in DENSITIES:
        size = int(round(48 * d))
        outdir = os.path.join(RES, "mipmap-" + dname)
        os.makedirs(outdir, exist_ok=True)
        legacy_icon(size, art, round_icon=False).save(os.path.join(outdir, "ic_launcher.png"))
        legacy_icon(size, art, round_icon=True).save(os.path.join(outdir, "ic_launcher_round.png"))
        print("legacy      : mipmap-%-9s %dpx 方形+圆形" % (dname, size))

    # 3. App 内首页 logo：**小白猫**（用户明确要求只换这一处回来）
    os.makedirs(APP_IMAGES, exist_ok=True)
    cat = load_mascot()
    cat.save(os.path.join(APP_IMAGES, "paopaocat_mascot.png"))
    print("app asset   : assets/images/paopaocat_mascot.png %sx%s（首页 logo：小白猫）"
          % (cat.width, cat.height))
    # 上一版给 App 内 logo 生成过的新图标资源已经没用了，顺手清掉避免混淆
    stale_logo = os.path.join(APP_IMAGES, "paopaocat_logo.png")
    if os.path.exists(stale_logo):
        os.remove(stale_logo)
        print("removed     : assets/images/paopaocat_logo.png（App 内 logo 已换回小白猫）")

    # 4. 预览
    big = legacy_icon(192, art)
    adapt = gradient((192, 192)).convert("RGBA")
    fg192 = fit(art, 192 * ADAPTIVE_FILL, 192 * ADAPTIVE_FILL)
    adapt.alpha_composite(fg192, ((192 - fg192.width) // 2, (192 - fg192.height) // 2))
    tiny = legacy_icon(48, art)
    zoom = tiny.resize((48 * 6, 48 * 6), Image.NEAREST)

    pad = 20
    sheet = Image.new("RGB", (192 * 3 + pad * 4, 192 + 60), (18, 24, 28))
    d = ImageDraw.Draw(sheet)
    for i, (img, label) in enumerate([
        (big, "legacy 192"),
        (adapt.convert("RGB"), "adaptive 192"),
        (tiny.resize((192, 192), Image.LANCZOS), "mdpi 48 upscaled"),
    ]):
        x = pad + i * (192 + pad)
        sheet.paste(img.convert("RGB"), (x, pad))
        d.text((x + 2, pad + 192 + 8), label, fill=(215, 235, 235))
    sheet.save(os.path.join(INSTALL, "icon-preview.png"))
    zoom.save(os.path.join(INSTALL, "icon-preview-48px-zoom.png"))
    print("preview     : install/icon-preview.png %s" % (sheet.size,))
    print("preview     : install/icon-preview-48px-zoom.png %s" % (zoom.size,))
    print("提醒        : 源图只有 %dx%d，放大到 192/432px 会糊；有原图请替换后重跑。"
          % (art.width, art.height))


if __name__ == "__main__":
    main()
