# -*- coding: utf-8 -*-
"""验证"模型清单不一致"修复：
  1) 启动后 models.json 是否被自愈补回（磁盘状态一致）
  2) 设置页「我的模型」是否显示已配置的模型（不再说"还没有添加任何模型"）

用法：C:\\Python314\\python.exe install\\verify_models_fix.py
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
    r = subprocess.run([ADB, *a], capture_output=True, timeout=timeout)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def runas(*a):
    return adb("shell", "run-as", PKG, *a)


def main():
    os.makedirs(STAGE, exist_ok=True)
    rep = []

    rep.append("=== 修复前 ===")
    rep.append("  models.json: " + ("存在" if "models.json" in runas("ls", "files") else "不存在"))

    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(28)

    rep.append("")
    rep.append("=== 启动后 models.json（自愈应补回）===")
    js = runas("cat", "files/models.json")
    rep.append("  " + js.strip()[:300])
    healed = '"models"' in js and 'deepseek' in js
    rep.append("  [%s] models.json 已被自愈补回并含模型" % ("OK" if healed else "MISS"))

    # 设置页
    adb("shell", "input", "tap", "972", "2280")
    time.sleep(6)
    adb("shell", "uiautomator", "dump")
    local = os.path.join(STAGE, "models-fix.xml")
    if os.path.exists(local):
        os.remove(local)
    adb("pull", "/sdcard/window_dump.xml", local)
    xml = open(local, encoding="utf-8", errors="replace").read()
    rep.append("")
    rep.append("=== 设置页模型段 ===")
    rep.append("  [%s] 有「我的模型」" % ("OK" if "我的模型" in xml else "MISS"))
    rep.append("  [%s] **不再**说「还没有添加任何模型」" % ("OK" if "还没有添加任何模型" not in xml else "MISS"))
    rep.append("  [%s] 出现「默认」按钮（说明清单里有一行且它是默认）" % ("OK" if "默认" in xml else "MISS"))
    for m in re.finditer(r'(?:text|content-desc)="([^"]*模型[^"]*)"', xml):
        rep.append("   · " + m.group(1)[:110])

    out = os.path.join(LOGS, "verify-models-fix.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    for line in rep:
        if line.strip().startswith("["):
            print("  " + line.encode("ascii", "replace").decode("ascii")[:88])
    return 0


if __name__ == "__main__":
    sys.exit(main())
