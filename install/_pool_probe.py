# -*- coding: utf-8 -*-
"""One-shot probe of the 设置 → 模型 page for the pool-models verification.

Usage: C:\\Python314\\python.exe install\\_pool_probe.py [top|agnes|keyframe|pool]

  top       just open 设置 and dump (scrolled to the top first)
  agnes     open 设置, expand the Agnes card, dump (and dump again with the IME up)
  keyframe  same as agnes, plus tap the API Key field and type into it
  pool      open 设置 and scroll to the 轮换池 section
"""
import os
import re
import subprocess
import sys
import time

ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
STAGE = r"D:\dev\uiverify"
PKG = "com.dshmobile.dsh_mobile"
NODE_RE = re.compile(r"<node\b[^>]*?/?>")
ATTR_RE = re.compile(r'([\w-]+)="([^"]*)"')


def adb(*a):
    return subprocess.run([ADB, *a], capture_output=True, timeout=300)


def shell(cmd):
    return subprocess.run([ADB, "shell", cmd], capture_output=True, timeout=300)


def parse_nodes(xml):
    out = []
    for m in NODE_RE.finditer(xml):
        at = dict(ATTR_RE.findall(m.group(0)))
        b = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", at.get("bounds", ""))
        if not b:
            continue
        x1, y1, x2, y2 = (int(g) for g in b.groups())
        if x2 <= x1 or y2 <= y1:
            continue
        out.append((at.get("text", ""), at.get("content-desc", ""), at.get("class", ""),
                    (x1, y1, x2, y2)))
    return out


def dump(tag):
    adb("shell", "uiautomator", "dump")
    local = os.path.join(STAGE, "probe-%s.xml" % tag)
    if os.path.exists(local):
        os.remove(local)
    adb("pull", "/sdcard/window_dump.xml", local)
    return open(local, encoding="utf-8", errors="replace").read() if os.path.exists(local) else ""


def show(xml, tag):
    print("=== nodes (%s) ===" % tag, flush=True)
    for t, d, c, b in parse_nodes(xml):
        if not t and not d:
            continue
        print("%-30s | %-52s | %-26s | %s" % (
            t.replace("\n", "\\n")[:30], d.replace("\n", "\\n")[:52],
            c.replace("android.view.", "").replace("android.widget.", ""), b), flush=True)


def center(xml, needle):
    for t, d, c, b in parse_nodes(xml):
        for v in (t, d):
            if v and needle in v:
                return ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)
    return None


def scroll_top():
    for _ in range(6):
        adb("shell", "input", "swipe", "540", "1150", "540", "1800", "250")
        time.sleep(0.6)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "top"
    adb("shell", "input", "keyevent", "111")
    time.sleep(1)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(32)
    adb("shell", "input", "tap", "972", "2280")
    time.sleep(4)
    scroll_top()
    xml = dump("p-" + mode + "-0")
    show(xml, mode + "-top")

    if mode in ("agnes", "keyframe"):
        c = center(xml, "Agnes")
        print("tap Agnes @ %s" % (c,), flush=True)
        if c:
            adb("shell", "input", "tap", str(c[0]), str(c[1]))
            time.sleep(2.5)
        xml = dump("p-" + mode + "-1")
        show(xml, mode + "-expanded")
        if mode == "keyframe":
            fld = None
            for t, d, c2, b in parse_nodes(xml):
                if "API Key" in d or "API Key" in t or c2.endswith("EditText"):
                    fld = (t, d, c2, b)
                    break
            print("field node: %s" % (fld,), flush=True)
            if fld:
                cx, cy = (fld[3][0] + fld[3][2]) // 2, (fld[3][1] + fld[3][3]) // 2
                adb("shell", "input", "tap", str(cx), str(cy))
                time.sleep(1.5)
                adb("shell", "input", "text", "sk-pool-verify-not-a-real-key")
                time.sleep(1.5)
                xml = dump("p-" + mode + "-2")
                show(xml, mode + "-ime-up")

    if mode == "pool":
        for i in range(6):
            if "轮换池" in xml:
                break
            adb("shell", "input", "swipe", "540", "1750", "540", "1150", "300")
            time.sleep(1.2)
            xml = dump("p-pool-%d" % i)
        show(xml, "pool")

    print("ime shown: %s" % ("mInputShown=true" in shell("dumpsys input_method").stdout.decode("utf-8", "replace")), flush=True)
    st = os.path.join(STAGE, "probe-%s.png" % mode)
    adb("shell", "screencap", "-p", "/sdcard/probe-%s.png" % mode)
    adb("pull", "/sdcard/probe-%s.png" % mode, st)
    print("shot -> %s (%s bytes)" % (st, os.path.getsize(st) if os.path.exists(st) else -1), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
