# -*- coding: utf-8 -*-
"""端到端验证沙箱修复：让模型写一个文件，再在磁盘上找它。

之前"让生成 PPT 资料库看不到"的根因是模型写不出文件；修成 danger-full-access 后
应该能写。这里用一个最小提示词触发写文件，然后 run-as find 验证。

用法：C:\\Python314\\python.exe install\\verify_write.py
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
TARGET = "sandbox_probe.txt"


def adb(*a, timeout=240):
    return subprocess.run([ADB, *a], capture_output=True, timeout=timeout)


def runas(*a):
    return adb("shell", "run-as", PKG, *a).stdout.decode("utf-8", "replace")


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
    for m in re.finditer(r'<node[^>]*class="android\.widget\.EditText"[^>]*?>', xml):
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

    # 开始新会话
    xml = dump("w-home")
    c = center(xml, "开始新会话")
    if not c:
        rep.append("FAIL: 没找到「开始新会话」")
        rep.extend(labels(xml)[:8])
    else:
        adb("shell", "input", "tap", str(c[0]), str(c[1]))
        time.sleep(24)
        xml = dump("w-chat")
        box = center_edittext(xml)
        if not box:
            rep.append("FAIL: 没找到输入框")
        else:
            adb("shell", "input", "tap", str(box[0]), str(box[1]))
            time.sleep(2)
            prompt = ("Create%sfile%s" + TARGET + "%swith%stext%s'hello'%sin%sthe%s"
                      "current%sworking%sdirectory,%sthen%ssay%sdone.")
            adb("shell", "input", "text", prompt)
            time.sleep(2)
            # 找不到发送就按一次返回收键盘
            xml = dump("w-typed")
            send = center(xml, "发送")
            if not send:
                adb("shell", "input", "keyevent", "4")
                time.sleep(3)
                xml = dump("w-typed2")
                send = center(xml, "发送")
            if not send:
                rep.append("FAIL: 没找到发送按钮（可见：%s）" % " | ".join(labels(xml)[:8]))
            else:
                adb("shell", "input", "tap", str(send[0]), str(send[1]))
                for i in range(12):
                    time.sleep(10)
                    txt = " ".join(labels(dump("w-wait")))
                    if "已完成" in txt:
                        rep.append("回复完成（第 %d 次轮询）" % (i + 1))
                        break
                    if i == 11:
                        rep.append("超时：120s 内没等到完成")

    # 找文件
    rep.append("")
    rep.append("=== 磁盘上找 %s ===" % TARGET)
    out = runas("find", "files", "-name", TARGET)
    if TARGET in out:
        rep.append("✅ 找到了文件：")
        rep.append(out)
        rep.append("--- 内容 ---")
        rep.append(runas("cat", "files/workspaces/moni-ws/" + TARGET))
    else:
        rep.append("❌ 没找到文件。全盘再找一次（含所有 .txt）：")
        rep.append(runas("find", "files", "-name", "*.txt", "-mmin", "-30"))

    out = os.path.join(LOGS, "verify-write.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    for line in rep:
        print("  " + line.encode("ascii", "replace").decode("ascii")[:100])
    return 0


if __name__ == "__main__":
    sys.exit(main())
