# -*- coding: utf-8 -*-
"""验证最后一条链：会话 -> 添加附件 -> 专家中心 -> 只显示已开专家。

用法：C:\\Python314\\python.exe install\\test_expert_sheet.py
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
    xml = dump("e-home")
    c = center(xml, "开始新会话")
    if not c:
        rep.append("FAIL 没找到开始新会话")
    else:
        adb("shell", "input", "tap", str(c[0]), str(c[1]))
        time.sleep(22)
        xml = dump("e-chat")
        att = center(xml, "添加附件")
        if not att:
            rep.append("FAIL 没找到添加附件（可见：%s）" % " | ".join(labels(xml)[:8]))
        else:
            adb("shell", "input", "tap", str(att[0]), str(att[1]))
            time.sleep(3)
            xml = dump("e-menu")
            ec = center(xml, "专家中心")
            if not ec:
                rep.append("FAIL 附件菜单里没有专家中心（可见：%s）" % " | ".join(labels(xml)[:12]))
            else:
                rep.append("附件菜单里有「专家中心」@ %s" % (ec,))
                adb("shell", "input", "tap", str(ec[0]), str(ec[1]))
                time.sleep(4)
                xml = dump("e-sheet")
                labs = labels(xml)
                joined = "\n".join(labs)
                rep.append("")
                rep.append("=== 专家中心弹层可见 ===")
                rep.extend("  " + v.replace("\n", " / ")[:70] for v in labs[:14])
                rep.append("")
                rep.append("  [%s] 只显示已开专家「人类学家」" % ("OK" if "人类学家" in joined else "MISS"))
                rep.append("  [%s] 不显示未开的「地理学家」" % ("OK" if "地理学家" not in joined else "MISS"))
    out = os.path.join(LOGS, "test-expert-sheet.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    for line in rep:
        print("  " + line.encode("ascii", "replace").decode("ascii")[:90])
    return 0


if __name__ == "__main__":
    sys.exit(main())
