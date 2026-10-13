#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""独立复核：更新说明入口 + 「去注册」是否真的拉起浏览器（复用 verify_010_theme 的 helper）。"""
import os
import re
import sys
import time

REPO = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile"
PKG = "com.dshmobile.dsh_mobile"
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
sys.path.insert(0, os.path.join(REPO, "install"))
import verify_010_theme as v  # noqa: E402  （复用 dump/tap/texts/shot）

out = []
note = out.append

v.adb("shell", "am", "force-stop", PKG)
time.sleep(2)
v.adb("shell", "am", "start", "-n", "%s/.MainActivity" % PKG)
time.sleep(15)
home = v.dump("rh")
v.tap(home, "设置")
time.sleep(3)

seen = []
for i in range(8):
    seen.extend(v.texts(v.dump("r%d" % i)))
    v.adb("shell", "input", "swipe", "540", "1800", "540", "1000", "600")
    time.sleep(2)
seen = list(dict.fromkeys(seen))
note("## 1. 更新说明入口（关于段）")
note("  含「更新说明」：%s" % any("更新说明" in t for t in seen))
note("  含「更新说明」的原文：%s" % ([t for t in seen if "更新说明" in t][:3] or "（没扫到）"))

# 滚回上面，找「去注册」并真的点一次
for _ in range(8):
    v.adb("shell", "input", "swipe", "540", "1000", "540", "1900", "400")
    time.sleep(1)
time.sleep(2)
xml = v.dump("top")
hit = None
for i in range(8):
    if v.tap(xml, "去注册"):
        hit = i
        break
    v.adb("shell", "input", "swipe", "540", "1800", "540", "1000", "600")
    time.sleep(2)
    xml = v.dump("s%d" % i)
note("\n## 2. 点「去注册」")
note("  找到并点了：%s（第 %s 屏）" % (hit is not None, hit))
time.sleep(3)
rc, d = v.adb("shell", "dumpsys", "window")
focus = re.search(r"mCurrentFocus=(\S+ \S+ \S+)", d)
note("  前台窗口：%s" % (focus.group(1) if focus else "?"))
note("  是不是浏览器：%s" % (bool(focus and ("chrome" in focus.group(1).lower() or "browser" in focus.group(1).lower()))))
logs = v.adb("logcat", "-d", "-v", "time")[1]
note("  openUrl 日志：%s" % ([l.strip()[-110:] for l in logs.splitlines() if "openUrl ->" in l][-2:]))

os.makedirs(os.path.join(REPO, "docs", "logs"), exist_ok=True)
txt = "\n".join(out)
with open(os.path.join(REPO, "docs", "logs", "verify-010-register.txt"), "w", encoding="utf-8") as f:
    f.write(txt)
for line in [l for l in txt.splitlines() if l.isascii()][-12:]:
    print(line)
print("-> docs/logs/verify-010-register.txt")
