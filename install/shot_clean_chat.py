# -*- coding: utf-8 -*-
"""抓一张"干净的对话"截图作为发布主图。

上一版主图里模型连着调 `bash`/`glob` 都失败（Android 沙箱限制），
发布文章里不体面。这里改成问一句纯聊天的问题：不触发工具，只拿一段中文回复。

中文没法用 `adb shell input text` 输入，所以提示词用英文、并要求它用中文回。

用法：C:\\Python314\\python.exe install\\shot_clean_chat.py
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

# adb input text 里空格要写 %s；非 ASCII 会丢，所以用英文提问 + 要求中文回答
PROMPT = "Please%ssay%shello%sto%susers%sof%sPaopaocat%sDSH%sin%sChinese,%stwo%sshort%ssentences."


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


def center_edittext(xml):
    """按 class=EditText 找输入框 —— 别用「按住说话」定位。

    那一串既是输入框的 hint、又是右侧麦克风按钮的语义标签，
    点到麦克风上就白点了（文本根本没进输入框，实测踩过）。
    """
    for m in re.finditer(r'<node[^>]*class="android\.widget\.EditText"[^>]*?>', xml):
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', m.group(0))
        if b:
            x1, y1, x2, y2 = (int(g) for g in b.groups())
            if x2 > x1 and y2 > y1:
                return ((x1 + x2) // 2, (y1 + y2) // 2)
    return None


def main():
    os.makedirs(STAGE, exist_ok=True)
    adb("shell", "input", "keyevent", "4")
    time.sleep(1)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(26)

    # 首页 -> 开始新会话
    xml = dump("clean-home")
    c = center(xml, "开始新会话")
    if not c:
        print("FAIL: 没找到「开始新会话」")
        return 1
    adb("shell", "input", "tap", str(c[0]), str(c[1]))
    time.sleep(24)

    # 点输入框，输入英文提示
    xml2 = dump("clean-chat")
    box = center_edittext(xml2)
    if not box:
        print("FAIL: 没找到输入框（EditText）")
        return 1
    print("输入框 @", box)
    adb("shell", "input", "tap", str(box[0]), str(box[1]))
    time.sleep(2)
    adb("shell", "input", "text", PROMPT)
    time.sleep(2)
    # 确认文本真的进去了（没进去就别往下走，免得拍一张空对话）
    if "Please" not in " ".join(labels(dump("clean-check"))):
        print("FAIL: 输入的文字没有进入输入框")
        return 1

    xml3 = dump("clean-typed")
    send = center(xml3, "发送")
    if not send:
        # 软键盘弹出来会挡住/覆盖界面（模拟器上 Gboard 还弹过 "Network not connected"，dump 拍到的是键盘）。
        # 按一次返回键收起键盘 —— 只按一次：连按两次会直接退出会话页。
        # 只在"确实找不到发送按钮"时才按，避免误退。
        adb("shell", "input", "keyevent", "4")
        time.sleep(3)
        xml3 = dump("clean-typed2")
        send = center(xml3, "发送")
    if not send:
        print("FAIL: 输入后没有出现发送按钮（可见：%s）" % " | ".join(labels(xml3)[:10]))
        return 1
    adb("shell", "input", "tap", str(send[0]), str(send[1]))

    for i in range(12):
        time.sleep(10)
        txt = " ".join(labels(dump("clean-wait")))
        if "已完成" in txt:
            print("回复完成（第 %d 次轮询）" % (i + 1))
            break
        print("  …等待", (i + 1) * 10, "s")

    adb("shell", "screencap", "-p", "/sdcard/s.png")
    local = os.path.join(STAGE, "round7_chat_clean.png")
    adb("pull", "/sdcard/s.png", local)
    if os.path.exists(local):
        open(os.path.join(SHOTS, "round7_chat_clean.png"), "wb").write(open(local, "rb").read())
        print("截图:", os.path.join(SHOTS, "round7_chat_clean.png"))
    report = os.path.join(ROOT, "docs", "logs", "clean-chat.txt")
    with open(report, "w", encoding="utf-8") as f:
        f.write("\n".join(labels(dump("clean-final"))))
    print("最终可见文本 -> %s" % report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
