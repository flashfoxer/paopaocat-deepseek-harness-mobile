# -*- coding: utf-8 -*-
"""检查设置页新增的「文件地址 / 关于」是否渲染出来（含二维码与公众号 ID）。

用法：C:\\Python314\\python.exe install\\check_settings_about.py
"""
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
STAGE = r"D:\dev\uiverify"
SHOTS = os.path.join(ROOT, "docs", "screenshots")
PKG = "com.dshmobile.dsh_mobile"


def adb(*a, timeout=180):
    return subprocess.run([ADB, *a], capture_output=True, timeout=timeout)


def dump(tag):
    adb("shell", "uiautomator", "dump")
    local = os.path.join(STAGE, "ui-%s.xml" % tag)
    if os.path.exists(local):
        os.remove(local)
    adb("pull", "/sdcard/window_dump.xml", local)
    if not os.path.exists(local):
        return ""
    return open(local, encoding="utf-8", errors="replace").read()


def labels(xml):
    out = []
    for pat in (r'content-desc="([^"]*)"', r'text="([^"]*)"'):
        for m in re.finditer(pat, xml):
            v = m.group(1).strip()
            if v and v not in out:
                out.append(v)
    return out


def main():
    os.makedirs(STAGE, exist_ok=True)
    adb("shell", "input", "keyevent", "4")
    time.sleep(1)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(26)
    adb("shell", "input", "tap", "972", "2280")   # 底部导航第 5 项：设置
    time.sleep(5)
    xml = dump("settings-about")
    labs = labels(xml)
    joined = "\n".join(labs)
    print("设置页可见文本（去重）：")
    for v in labs:
        print("  -", v.replace("\n", " / ")[:90])

    print()
    checks = {
        "「文件地址」标题": "文件地址" in joined,
        "「关于」标题": "关于" in joined,
        "路径：会话记录": "sessions" in joined,
        "路径：附件目录": "attachments" in joined,
        "求关注文案": "做这个主要是下班晚上才有时间做" in joined,
        "公众号 ID": "paopaocat888" in joined,
    }
    for k, v in checks.items():
        print("  %s %s" % ("✅" if v else "❌", k))

    # 二维码是图片，语义树里未必有节点 —— 用截图的像素判断更可靠：
    # 找画面里是否出现一块"接近纯白的方形区域"（二维码衬的白底）。
    adb("shell", "screencap", "-p", "/sdcard/s.png")
    local = os.path.join(STAGE, "settings-about.png")
    adb("pull", "/sdcard/s.png", local)
    if os.path.exists(local):
        dest = os.path.join(SHOTS, "round7_settings_about.png")
        open(dest, "wb").write(open(local, "rb").read())
        print("截图:", dest)
        try:
            from PIL import Image
            im = Image.open(local).convert("RGB")
            w, h = im.size
            px = im.load()
            # 下半屏逐行统计"接近白"的像素数，出现大面积白色就是二维码那块
            best = 0
            best_y = 0
            for y in range(h // 2, h, 6):
                n = 0
                for x in range(0, w, 6):
                    r, g, b = px[x, y]
                    if r > 235 and g > 235 and b > 235:
                        n += 1
                if n > best:
                    best, best_y = n, y
            print("下半屏最白的一行: y=%d，白像素采样数=%d（%d 说明有二维码白底）" % (best_y, best, best))
        except Exception as e:
            print("像素检查跳过:", e)
    return 0


if __name__ == "__main__":
    sys.exit(main())
