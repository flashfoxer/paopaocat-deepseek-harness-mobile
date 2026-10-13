# -*- coding: utf-8 -*-
"""诊断：① DSH 的权限请求里到底带了什么；② 设置页「关于」是否渲染。

为什么单独写：控制台是 cp936，直接 print 中文/emoji 会抛 UnicodeEncodeError
（上一个脚本就是这么崩的）。所以**结论一律写进 UTF-8 文件**，控制台只打 ASCII。

用法：C:\\Python314\\python.exe install\\diag_perm_and_settings.py
"""
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
STAGE = r"D:\dev\uiverify"
LOGS = os.path.join(ROOT, "docs", "logs")
PKG = "com.dshmobile.dsh_mobile"


def adb(*a, timeout=240):
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
    os.makedirs(LOGS, exist_ok=True)
    report = []

    # ---- ① 权限请求的原始日志 ----
    log = adb("logcat", "-d").stdout.decode("utf-8", "replace")
    perm = [l for l in log.splitlines() if "权限请求" in l or "permission" in l.lower()]
    report.append("=== 权限请求相关日志（%d 条）===" % len(perm))
    report.extend(perm[-12:] if perm else ["(没有)"])

    # 当前屏幕上如果是权限弹层，把它完整 dump 出来
    xml = dump("perm-now")
    labs = labels(xml)
    if any("Agent 请求执行操作" in v for v in labs):
        report.append("")
        report.append("=== 权限弹层当前可见文本（完整）===")
        report.extend(labs)
    else:
        report.append("")
        report.append("=== 当前不在权限弹层（可见：%s）===" % " | ".join(labs[:8]))

    # ---- ② 设置页「关于」 ----
    adb("shell", "input", "keyevent", "4")   # 关掉弹层（拒绝/关闭都不会崩）
    time.sleep(2)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(26)
    adb("shell", "input", "tap", "972", "2280")
    time.sleep(5)
    # 设置页比较长，向下滚一段把「关于」露出来
    for _ in range(3):
        adb("shell", "input", "swipe", "540", "1800", "540", "900", "300")
        time.sleep(1)
    xml2 = dump("settings-about2")
    labs2 = labels(xml2)
    joined = "\n".join(labs2)
    report.append("")
    report.append("=== 设置页可见文本（滚动后，完整）===")
    report.extend(labs2)
    report.append("")
    report.append("=== 检查项 ===")
    for k, ok in [
        ("有「文件地址」", "文件地址" in joined),
        ("有「关于」", "关于" in joined),
        ("有求关注文案", "做这个主要是下班晚上才有时间做" in joined),
        ("有「公众号 ID：paopaocat888」", "paopaocat888" in joined),
        ("路径含 sessions", "sessions" in joined),
        ("路径含 attachments", "attachments" in joined),
    ]:
        report.append("  [%s] %s" % ("OK" if ok else "MISS", k))

    # 二维码是图片：用像素找白底方块
    adb("shell", "screencap", "-p", "/sdcard/s.png")
    local = os.path.join(STAGE, "settings-about2.png")
    adb("pull", "/sdcard/s.png", local)
    if os.path.exists(local):
        open(os.path.join(ROOT, "docs", "screenshots", "round7_settings_about.png"), "wb").write(
            open(local, "rb").read())
        try:
            from PIL import Image
            im = Image.open(local).convert("RGB")
            w, h = im.size
            px = im.load()
            best, best_y = 0, 0
            for y in range(h // 3, h, 4):
                n = 0
                for x in range(0, w, 4):
                    r, g, b = px[x, y]
                    if r > 235 and g > 235 and b > 235:
                        n += 1
                if n > best:
                    best, best_y = n, y
            report.append("")
            report.append("=== 二维码白底检测 ===")
            report.append("下半屏最白的一行 y=%d，白像素采样数=%d（数值大说明有白色方块=二维码）"
                          % (best_y, best))
        except Exception as e:
            report.append("像素检查跳过: %s" % e)

    out = os.path.join(LOGS, "diag-perm-settings.txt")
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(report))
    print("report written -> %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
