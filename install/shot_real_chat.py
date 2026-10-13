# -*- coding: utf-8 -*-
"""抓一张"真实中文对话"截图作为文章主图。

技巧：首页中部那 4 条功能提示（`进行数据分析及可视化` 等）点一下会
**把中文预填进输入框**再打开会话页 —— 这样不用给 adb 输入中文
（`adb shell input text` 对非 ASCII 支持很差），又能拿到真正的中文对话。

用法：C:\\Python314\\python.exe install\\shot_real_chat.py
"""
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
STAGE = r"D:\dev\uiverify"
SHOTS = os.path.join(ROOT, "docs", "screenshots")
PKG = "com.dshmobile.dsh_mobile"


def adb(*a, timeout=180):
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


def find_center(xml, needle, prefer_lower=True):
    best = None
    for m in re.finditer(r"<node[^>]*>", node_str := xml):
        pass
    for m in re.finditer(r'<node[^>]*?content-desc="[^"]*' + re.escape(needle) + r'[^"]*"[^>]*?>', xml):
        node = m.group(0)
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        if not b:
            continue
        x1, y1, x2, y2 = (int(g) for g in b.groups())
        if x2 > x1 and y2 > y1:
            best = ((x1 + x2) // 2, (y1 + y2) // 2)
    return best


def snap(tag):
    adb("shell", "screencap", "-p", "/sdcard/s.png")
    local = os.path.join(STAGE, tag + ".png")
    adb("pull", "/sdcard/s.png", local)
    if os.path.exists(local):
        dest = os.path.join(SHOTS, tag + ".png")
        open(dest, "wb").write(open(local, "rb").read())
        print("截图:", dest)
        return True
    return False


def main():
    os.makedirs(STAGE, exist_ok=True)
    adb("shell", "input", "keyevent", "4")
    time.sleep(1)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(26)

    xml = dump("chat-home")
    print("首页可见:", " | ".join(labels(xml)[:14]))
    tip = find_center(xml, "进行文档处理") or find_center(xml, "进行数据分析及可视化")
    if not tip:
        print("FAIL: 没找到功能提示（它会把中文预填进输入框）")
        return 1
    print("点功能提示 @", tip)
    adb("shell", "input", "tap", str(tip[0]), str(tip[1]))
    print("等待 ACP 起来…")
    time.sleep(24)

    xml2 = dump("chat-open")
    print("会话页可见:", " | ".join(labels(xml2)[:14]))
    send = find_center(xml2, "发送")
    if not send:
        print("FAIL: 没找到发送按钮")
        return 1
    print("点发送 @", send)
    adb("shell", "input", "tap", str(send[0]), str(send[1]))

    # 等模型回复（真实调用，几十秒很正常）
    for i in range(12):
        time.sleep(10)
        xml3 = dump("chat-wait")
        txt = " ".join(labels(xml3))
        if "已完成" in txt or "停止" in txt:
            print("检测到回复完成（第 %d 次轮询）" % (i + 1))
            break
        print("  …等待回复", (i + 1) * 10, "s")
    snap("round7_chat_real")
    print("最终可见:", " | ".join(labels(dump("chat-final"))[:18]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
