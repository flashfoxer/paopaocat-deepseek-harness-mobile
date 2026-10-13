# -*- coding: utf-8 -*-
"""只验证设置页模型段：收起态下是否显示「我的模型」整份清单。

上一版脚本按了两次 BACK 把 App 退回桌面，导致误报，这里重做：
冷启动 → 直接点「设置」→ 轻划一次 → dump 检查。

用法：C:\\Python314\\python.exe install\\check_models_visible.py
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
    return open(local, encoding="utf-8", errors="replace").read() if os.path.exists(local) else ""


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
    rep = []
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(27)
    # 冷启动后直接点「设置」（底部第 5 个）
    adb("shell", "input", "tap", "972", "2280")
    time.sleep(5)
    xml = dump("m1")
    rep.append("=== 设置页首屏 ===")
    rep.extend("  " + v.replace("\n", " / ")[:80] for v in labels(xml)[:12])
    if "我的模型" not in "\n".join(labels(xml)):
        adb("shell", "input", "swipe", "540", "1700", "540", "1150", "300")
        time.sleep(2)
        xml = dump("m2")
        rep.append("=== 轻划一次后 ===")
        rep.extend("  " + v.replace("\n", " / ")[:80] for v in labels(xml)[:18])
    j = "\n".join(labels(xml))
    rep.append("")
    rep.append("=== 检查项 ===")
    for k in ["我的模型", "设为默认", "默认", "该模型已就绪", "模型已配置", "重新测试", "修改配置", "deepseek"]:
        rep.append("  [%s] 出现「%s」" % ("OK" if k in j else "MISS", k))
    out = os.path.join(LOGS, "check-models-visible.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    for line in rep:
        if line.strip().startswith("["):
            print("  " + line.encode("ascii", "replace").decode("ascii")[:90])
    return 0


if __name__ == "__main__":
    sys.exit(main())
