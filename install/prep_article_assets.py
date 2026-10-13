# -*- coding: utf-8 -*-
"""为公众号文章准备素材：
1) 抓一张"定时任务跑过之后"的界面截图（比空态有说服力）
2) 生成公众号封面图（900x383，微信大图比例约 2.35:1）

用法：C:\\Python314\\python.exe install\\prep_article_assets.py
"""
import os
import re
import subprocess
import time

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
STAGE = r"D:\dev\uiverify"
SHOTS = os.path.join(ROOT, "docs", "screenshots")
OUT = os.path.join(ROOT, "docs", "article-assets")
PKG = "com.dshmobile.dsh_mobile"
ICON = os.path.join(ROOT, "design", "launcher-icon-source.png")

NAVY_TOP = (27, 39, 80)
NAVY_BOTTOM = (16, 23, 48)
GOLD = (232, 201, 122)
WHITE = (240, 244, 252)
DIM = (150, 165, 200)


def adb(*a, timeout=120):
    return subprocess.run([ADB, *a], capture_output=True, timeout=timeout)


def snap(tag):
    adb("shell", "screencap", "-p", "/sdcard/s.png")
    local = os.path.join(STAGE, tag + ".png")
    adb("pull", "/sdcard/s.png", local)
    if os.path.exists(local):
        dest = os.path.join(SHOTS, tag + ".png")
        open(dest, "wb").write(open(local, "rb").read())
        print("截图:", dest)
        return dest
    print("截图失败:", tag)
    return None


def font(size, bold=False):
    for name in (("msyhbd.ttc", "msyh.ttc") if bold else ("msyh.ttc",)):
        p = os.path.join(r"C:\Windows\Fonts", name)
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def cover():
    W, H = 900, 383
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)],
               fill=tuple(round(NAVY_TOP[i] + (NAVY_BOTTOM[i] - NAVY_TOP[i]) * t) for i in range(3)))
    # 左侧图标
    ic = Image.open(ICON).convert("RGBA")
    ic = ic.resize((230, 230), Image.LANCZOS)
    img.paste(ic, (52, (H - 230) // 2), ic)
    # 右侧文案
    x = 320
    d.text((x, 74), "重大发布", font=font(30, bold=True), fill=GOLD)
    d.text((x, 122), "手机版的智能体", font=font(42, bold=True), fill=WHITE)
    d.text((x, 182), "泡泡猫 DSH 预览版", font=font(42, bold=True), fill=WHITE)
    d.text((x, 258), "一个完全跑在手机里的 AI 助手", font=font(20), fill=DIM)
    d.text((x, 292), "除模型接口外，不依赖任何服务器", font=font(20), fill=DIM)
    out = os.path.join(OUT, "cover-900x383.png")
    img.save(out)
    print("封面:", out, img.size)

    # 再出一张方形社交分享图（部分场景用得上）
    S = 500
    sq = Image.new("RGB", (S, S))
    d2 = ImageDraw.Draw(sq)
    for y in range(S):
        t = y / (S - 1)
        d2.line([(0, y), (S, y)],
                fill=tuple(round(NAVY_TOP[i] + (NAVY_BOTTOM[i] - NAVY_TOP[i]) * t) for i in range(3)))
    ic2 = Image.open(ICON).convert("RGBA").resize((240, 240), Image.LANCZOS)
    sq.paste(ic2, ((S - 240) // 2, 56), ic2)
    t1 = "泡泡猫 DSH"
    w1 = d2.textlength(t1, font=font(44, bold=True))
    d2.text(((S - w1) / 2, 322), t1, font=font(44, bold=True), fill=WHITE)
    t2 = "手机版智能体 · 预览版"
    w2 = d2.textlength(t2, font=font(22))
    d2.text(((S - w2) / 2, 386), t2, font=font(22), fill=DIM)
    out2 = os.path.join(OUT, "square-500.png")
    sq.save(out2)
    print("方图:", out2, sq.size)


def main():
    os.makedirs(STAGE, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)

    # 1) 定时任务界面（有任务 + 运行历史）
    adb("shell", "input", "keyevent", "4")
    time.sleep(1)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(24)
    adb("shell", "input", "tap", "756", "2280")   # 底部导航第 4 项：定时任务
    time.sleep(4)
    snap("round7_scheduled")

    # 2) 工作区页（默认收起；点开一个看会话）
    adb("shell", "input", "tap", "108", "2280")   # 回首页
    time.sleep(3)
    adb("shell", "input", "tap", "1004", "275")   # 右上角工作区入口
    time.sleep(6)
    adb("shell", "uiautomator", "dump")
    local = os.path.join(STAGE, "ui-art.xml")
    if os.path.exists(local):
        os.remove(local)
    adb("pull", "/sdcard/window_dump.xml", local)
    if os.path.exists(local):
        xml = open(local, encoding="utf-8", errors="replace").read()
        m = re.search(r'<node[^>]*content-desc="[^"]*点击展开会话[^"]*"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml)
        if not m:
            m = re.search(r'content-desc="[^"]*点击展开会话[^"]*"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml)
        if m:
            x1, y1, x2, y2 = (int(g) for g in m.groups())
            adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
            time.sleep(4)
            print("已点开一个工作区")
        else:
            print("没找到可点开的收起项")
        snap("round7_workspace_expanded")

    cover()


if __name__ == "__main__":
    main()
