# -*- coding: utf-8 -*-
"""把设置页里所有含「模型」的节点原始打印出来，看模型段到底渲染了什么。

用法：C:\\Python314\\python.exe install\\dump_model_xml.py
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


def main():
    os.makedirs(STAGE, exist_ok=True)
    rep = []
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(27)
    adb("shell", "input", "tap", "972", "2280")   # 设置
    time.sleep(5)
    adb("shell", "uiautomator", "dump")
    local = os.path.join(STAGE, "model-dump.xml")
    if os.path.exists(local):
        os.remove(local)
    adb("pull", "/sdcard/window_dump.xml", local)
    xml = open(local, encoding="utf-8", errors="replace").read()

    rep.append("=== 全部含「模型」的 text / content-desc ===")
    for pat in (r'text="([^"]*模型[^"]*)"', r'content-desc="([^"]*模型[^"]*)"'):
        for m in re.finditer(pat, xml):
            rep.append("  " + m.group(1)[:150])

    rep.append("")
    rep.append("=== 该页所有可见 text（按 XML 顺序，前 40 条）===")
    n = 0
    for m in re.finditer(r'(?:text|content-desc)="([^"]+)"', xml):
        v = m.group(1).strip()
        if not v:
            continue
        n += 1
        if n > 40:
            break
        rep.append("  %2d. %s" % (n, v.replace("\n", " / ")[:100]))

    rep.append("")
    rep.append("=== 是否出现关键文案 ===")
    for k in ["我的模型", "设为默认", "还没有添加任何模型", "该模型已就绪", "重新测试", "修改配置", "会话里的模型面板"]:
        rep.append("  [%s] %s" % ("OK" if k in xml else "MISS", k))

    out = os.path.join(LOGS, "dump-model-xml.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    for line in rep:
        if line.strip().startswith("["):
            print("  " + line.encode("ascii", "replace").decode("ascii")[:80])
    return 0


if __name__ == "__main__":
    sys.exit(main())
