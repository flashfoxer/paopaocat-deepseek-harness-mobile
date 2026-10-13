# -*- coding: utf-8 -*-
"""设置页模型段：小步慢滑，逐步 dump，找出「我的模型」到底渲染没渲染。

上一版用一次快速滑动（fling），Flutter 的懒加载列表会**跳过中间内容**
（没被构建自然也不在语义树里），导致误判。这里改成多次 200px 慢拖。

用法：C:\\Python314\\python.exe install\\check_models_visible2.py
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
    adb("shell", "input", "tap", "972", "2280")   # 设置
    time.sleep(5)

    found = False
    for step in range(7):
        if step > 0:
            # 200px / 900ms = 慢拖，不是 fling（不会跳过内容）
            adb("shell", "input", "swipe", "540", "1500", "540", "1300", "900")
            time.sleep(2)
        xml = dump("s%d" % step)
        labs = labels(xml)
        j = "\n".join(labs)
        hit_models = "我的模型" in j
        rep.append("--- 第 %d 步（我的模型=%s）---" % (step, "有" if hit_models else "无"))
        rep.extend("   " + v.replace("\n", " / ")[:72] for v in labs[:10])
        if hit_models:
            found = True
            rep.append("")
            rep.append(">>> 第 %d 步找到了「我的模型」，完整可见文本：" % step)
            rep.extend("   " + v.replace("\n", " / ")[:90] for v in labs)
            break

    rep.append("")
    rep.append("=== 结论 ===")
    rep.append("  [%s] 设置页能显示「我的模型」" % ("OK" if found else "MISS"))

    out = os.path.join(LOGS, "check-models-visible2.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    for line in rep:
        if line.strip().startswith("[") or line.strip().startswith("---") or line.strip().startswith(">>>"):
            print("  " + line.encode("ascii", "replace").decode("ascii")[:80])
    return 0


if __name__ == "__main__":
    sys.exit(main())
