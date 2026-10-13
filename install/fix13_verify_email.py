# -*- coding: utf-8 -*-
"""验证「分享运行日志」弹窗里出现了开发者邮箱（用户 2026-10-04 的要求）。

用法：python -X utf8 install\\fix13_verify_email.py
"""
import os
import re
import subprocess
import sys
import time

ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
STAGE = r"D:\dev\uiverify"
PKG = "com.dshmobile.dsh_mobile"
EMAIL = "25894126@qq.com"


def adb(*a, timeout=180):
    return subprocess.run([ADB, *a], capture_output=True, timeout=timeout)


def dump(tag):
    os.makedirs(STAGE, exist_ok=True)
    adb("shell", "uiautomator", "dump")
    local = os.path.join(STAGE, "fix13-%s.xml" % tag)
    if os.path.exists(local):
        os.remove(local)
    adb("pull", "/sdcard/window_dump.xml", local)
    return open(local, encoding="utf-8", errors="replace").read() if os.path.exists(local) else ""


def labels(xml):
    out = []
    for pat in (r'content-desc="([^"]*)"', r'text="([^"]*)"'):
        for m in re.finditer(pat, xml):
            v = m.group(1).strip()
            if v and v not in out:
                out.append(v)
    return out


def find_center(xml, needle):
    best = None
    for m in re.finditer(r"<node[^>]*?>", xml):
        node = m.group(0)
        texts = []
        for pat in (r'content-desc="([^"]*)"', r'text="([^"]*)"'):
            mm = re.search(pat, node)
            if mm:
                texts.append(mm.group(1))
        if not any(needle in t for t in texts):
            continue
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        if not b:
            continue
        x1, y1, x2, y2 = (int(g) for g in b.groups())
        if x2 > x1 and y2 > y1:
            best = ((x1 + x2) // 2, (y1 + y2) // 2)
    return best


def main():
    adb("shell", "am", "force-stop", PKG)
    time.sleep(1)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(28)

    print("[1] 点底部「设置」", flush=True)
    adb("shell", "input", "tap", "972", "2265")
    time.sleep(3)

    xml = dump("settings")
    print("[2] 设置页可见: " + " | ".join(labels(xml)[:14]), flush=True)

    target = None
    for attempt in range(6):
        target = find_center(xml, "分享运行日志")
        if target:
            break
        print("     没看到「分享运行日志」，向上滑一屏（第 %d 次）" % (attempt + 1), flush=True)
        adb("shell", "input", "swipe", "540", "1700", "540", "900", "300")
        time.sleep(1.5)
        xml = dump("settings-%d" % attempt)
    if not target:
        # ⚠️ 循环里最后那一屏是在 break 之前 dump 的，别再漏掉它（第一版就栽在这）。
        target = find_center(xml, "分享运行日志")

    if not target:
        print("FAIL: 设置页里找不到「分享运行日志」入口", flush=True)
        print("   可见: " + " | ".join(labels(xml)[:30]), flush=True)
        return 1

    print("[3] 点「分享运行日志」@ %s" % (target,), flush=True)
    adb("shell", "input", "tap", str(target[0]), str(target[1]))
    time.sleep(2.5)

    xml2 = dump("log-dialog")
    lab = labels(xml2)
    print("[4] 弹窗可见:", flush=True)
    for v in lab:
        print("     - " + v[:300], flush=True)

    hit = any(EMAIL in v for v in lab)
    print("[5] 弹窗里出现 %s = %s" % (EMAIL, hit), flush=True)
    if not hit:
        print("FAIL: 弹窗里没有邮箱", flush=True)
        return 1
    print("PASS: 弹窗里能看到开发者邮箱", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
