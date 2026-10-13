# -*- coding: utf-8 -*-
"""补验：工作区页默认收缩（用户新要求）。

App 已装在模拟器上，这里只做一次交互：从首页右上角打开工作区页，
dump 语义树，确认「点击展开会话」出现、且**收起状态下不出现「N 个会话」**。

用 Python 的理由同 verify_round6.py：要按中文 content-desc 处理，
而 PowerShell 5.1 读无 BOM 的 UTF-8 脚本会乱码。
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


def adb(*a, timeout=120):
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


def center_of(xml, needle):
    for m in re.finditer(r"<node[^>]*>", xml):
        node = m.group(0)
        if needle not in node:
            continue
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        if not b:
            continue
        x1, y1, x2, y2 = (int(g) for g in b.groups())
        if x2 > x1 and y2 > y1:
            return ((x1 + x2) // 2, (y1 + y2) // 2)
    return None


def main():
    os.makedirs(STAGE, exist_ok=True)
    lines = []

    def log(m):
        print(m.encode("ascii", "replace").decode("ascii"))
        lines.append(m)

    log("device: " + adb("shell", "getprop", "ro.product.cpu.abi").stdout.decode().strip())
    # 上一轮冒烟最后点开了系统文件选择器，它属于**另一个 App**，
    # force-stop 我们的包不会把它收掉 —— 先按一次返回键把它关掉，
    # 否则 dump 拍到的是 DocumentsUI，找不到工作区入口。
    adb("shell", "input", "keyevent", "4")
    time.sleep(2)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(26)

    xml = dump("ws-home")
    labels_home = labels(xml)
    log("首页可见: " + " | ".join(labels_home[:12]))
    c = center_of(xml, "工作区")
    if not c:
        # 兜底：首页右上角那个工作区入口的实测坐标（HANDOFF §11.6）
        c = (1004, 275)
        log("没从语义树找到工作区入口，改用实测坐标兜底 %s" % (c,))
    log("工作区入口坐标: %s" % (c,))
    if not c:
        log("FAIL: 没找到工作区入口")
    else:
        adb("shell", "input", "tap", str(c[0]), str(c[1]))
        time.sleep(8)
        xml2 = dump("ws-page")
        labs = labels(xml2)
        joined = " ".join(labs)
        log("工作区页可见: " + " | ".join(labs[:14]))
        expanded_note = "点击展开会话" in joined
        count_visible = bool(re.search(r"\d+\s*个会话", joined))
        log("出现「点击展开会话」= %s" % expanded_note)
        log("收起状态下是否仍显示「N 个会话」= %s（应为 False）" % count_visible)
        adb("shell", "screencap", "-p", "/sdcard/s.png")
        local = os.path.join(STAGE, "round6_workspace.png")
        adb("pull", "/sdcard/s.png", local)
        if os.path.exists(local):
            open(os.path.join(ROOT, "docs", "screenshots", "round6_workspace.png"), "wb").write(
                open(local, "rb").read())
            log("shot: round6_workspace")
        # 点一下第一个工作区，确认展开后出现会话数
        c2 = center_of(xml2, "点击展开会话")
        if c2:
            adb("shell", "input", "tap", str(c2[0]), str(c2[1]))
            time.sleep(4)
            xml3 = dump("ws-expanded")
            j3 = " ".join(labels(xml3))
            log("展开后出现「N 个会话」= %s" % bool(re.search(r"\d+\s*个会话", j3)))
        else:
            log("没找到可点击的收起项（可能只有一个工作区且结构不同）")

    open(os.path.join(LOGS, "round6-workspace.txt"), "w", encoding="utf-8").write("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
