# -*- coding: utf-8 -*-
"""精确验证设置页的模型段：只划一次 + 点开「修改配置」，再看多模型 UI。

上一版脚本连划 4 次直接滚过了模型段，才误报 MISS —— 这里修掉那个方法学问题。

用法：C:\\Python314\\python.exe install\\check_settings_models.py
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


def adb(*a, timeout=180):
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


def center(xml, needle):
    for m in re.finditer(r'<node[^>]*content-desc="[^"]*' + re.escape(needle) + r'[^"]*"[^>]*?>', xml):
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', m.group(0))
        if b:
            x1, y1, x2, y2 = (int(g) for g in b.groups())
            if x2 > x1 and y2 > y1:
                return ((x1 + x2) // 2, (y1 + y2) // 2)
    return None


def main():
    os.makedirs(STAGE, exist_ok=True)
    rep = []

    adb("shell", "input", "keyevent", "4")
    time.sleep(1)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(26)
    adb("shell", "input", "tap", "972", "2280")   # 设置
    time.sleep(5)

    # 只划一次，把「模型」段带进视野（划太多会直接滚到底）
    adb("shell", "input", "swipe", "540", "1700", "540", "1100", "280")
    time.sleep(2)
    xml = dump("models-1")
    labs = labels(xml)
    rep.append("=== 划一次后的可见文本 ===")
    rep.extend(labs[:16])

    collapsed = "修改配置" in "\n".join(labs)
    rep.append("")
    rep.append("[%s] 模型段处于收起态（有「修改配置」）" % ("OK" if collapsed else "NO"))
    if collapsed:
        c = center(xml, "修改配置")
        rep.append("点「修改配置」@ %s" % (c,))
        if c:
            adb("shell", "input", "tap", str(c[0]), str(c[1]))
            time.sleep(3)
            for _ in range(3):
                adb("shell", "input", "swipe", "540", "1700", "540", "1200", "280")
                time.sleep(1)
            xml = dump("models-2")
            labs = labels(xml)

    joined = "\n".join(labs)
    rep.append("")
    rep.append("=== 检查项（模型段）===")
    for k in ["我的模型", "设为默认", "获取模型", "测试并保存", "可以多选", "自定义模型"]:
        rep.append("  [%s] 出现「%s」" % ("OK" if k in joined else "MISS", k))
    rep.append("")
    rep.append("=== 展开后的可见文本 ===")
    rep.extend(labs[:22])

    out = os.path.join(LOGS, "round8-settings-models.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    for line in rep:
        if line.strip().startswith("["):
            print("  " + line.encode("ascii", "replace").decode("ascii"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
