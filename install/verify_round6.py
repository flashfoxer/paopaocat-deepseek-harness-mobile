# -*- coding: utf-8 -*-
"""第六轮冒烟：构建 x86_64 debug -> 装机 -> 按语义树点击验证新界面。

为什么用 Python 而不是 PowerShell：本机 PowerShell 5.1 会把无 BOM 的 UTF-8
脚本按 ANSI 读，脚本里出现中文就会解析错乱（本轮已踩两次）。而要按中文
content-desc 找控件，脚本里必然有中文。Python 3 源码默认 UTF-8，没有这个问题。

用法：C:\\Python314\\python.exe install\\verify_round6.py
报告写到 docs\\logs\\round6-smoke.txt（UTF-8），控制台只打 ASCII 状态行。
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
SHOTS = os.path.join(ROOT, "docs", "screenshots")
PKG = "com.dshmobile.dsh_mobile"

report_lines = []


def log(msg):
    print(msg.encode("ascii", "replace").decode("ascii"))
    report_lines.append(msg)


def run(args, timeout=600):
    return subprocess.run(args, capture_output=True, timeout=timeout)


def adb(*args, timeout=60):
    return run([ADB, *args], timeout=timeout)


def dump_texts(tag):
    """uiautomator dump -> pull 到纯 ASCII 目录 -> 抽 content-desc / text。"""
    adb("shell", "uiautomator", "dump")
    remote = "/sdcard/window_dump.xml"
    local = os.path.join(STAGE, "ui-%s.xml" % tag)
    if os.path.exists(local):
        os.remove(local)
    adb("pull", remote, local)
    if not os.path.exists(local):
        log("  (%s) PULL FAILED" % tag)
        return None, []
    xml = open(local, encoding="utf-8", errors="replace").read()
    vals = []
    for m in re.finditer(r'content-desc="([^"]*)"', xml):
        v = m.group(1).strip()
        if v:
            vals.append(v)
    for m in re.finditer(r'text="([^"]*)"', xml):
        v = m.group(1).strip()
        if v:
            vals.append(v)
    uniq = []
    for v in vals:
        if v not in uniq:
            uniq.append(v)
    return xml, uniq


def find_center(xml, needle):
    """找 content-desc 或 text 含 needle 的节点中心（返回 (x, y) 或 None）。"""
    best = None
    for m in re.finditer(r'<node[^>]*>', xml):
        node = m.group(0)
        if needle not in node:
            continue
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        if not b:
            continue
        x1, y1, x2, y2 = (int(g) for g in b.groups())
        if x2 <= x1 or y2 <= y1:
            continue
        best = ((x1 + x2) // 2, (y1 + y2) // 2)
        if best[1] > 200:  # 偏向屏幕下半部分（避开顶部状态栏噪声）
            break
    return best


def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))


def snap(name):
    adb("shell", "screencap", "-p", "/sdcard/s.png")
    local = os.path.join(STAGE, name + ".png")
    adb("pull", "/sdcard/s.png", local)
    if os.path.exists(local):
        dest = os.path.join(SHOTS, name + ".png")
        open(dest, "wb").write(open(local, "rb").read())
        log("  shot: %s" % name)


def main():
    os.makedirs(STAGE, exist_ok=True)
    os.makedirs(LOGS, exist_ok=True)
    os.makedirs(SHOTS, exist_ok=True)

    no_build = "--no-build" in sys.argv
    # 先确认有设备：没设备时 adb 的每个调用都会挂到超时（本轮踩过：
    # DSH 重启时把模拟器当子进程一起杀了，adb devices 是空的）。
    devs = adb("devices", timeout=60).stdout.decode("utf-8", "replace")
    log("adb devices:\n" + devs.strip())
    if "device\n" not in devs and not any("\tdevice" in l for l in devs.splitlines()):
        log("FAIL: 没有可用设备（模拟器没起来或没连上）—— 先解决设备问题再跑")
        out = os.path.join(LOGS, "round6-smoke.txt")
        open(out, "w", encoding="utf-8").write("\n".join(report_lines))
        return 2

    if no_build:
        log("[1] 跳过构建（--no-build）：用 dist 里已有的 x86_64 debug 包")
    else:
        log("[1] build x86_64 debug (also compiles the new Kotlin)")
        r = run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                 "-File", os.path.join(ROOT, "install", "build-local-apk.ps1"),
                 "-Abi", "x86_64", "-Mode", "debug"], timeout=1800)
        tail = (r.stdout + r.stderr).decode("utf-8", "replace").splitlines()[-4:]
        for line in tail:
            log("    " + line)

    apk = os.path.join(ROOT, "dist", "dsh-local-x86_64-app-debug.apk")
    if not os.path.exists(apk):
        log("FAIL: apk not produced")
        return 1
    log("    apk bytes=%d" % os.path.getsize(apk))

    log("[2] install + launch")
    log("    " + adb("install", "-r", apk, timeout=600).stdout.decode("utf-8", "replace").strip())
    adb("logcat", "-c")
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(26)

    log("[3] home page")
    xml, texts = dump_texts("home6")
    log("    texts: " + " | ".join(texts[:16]))
    log("    有「开始新会话」= %s" % ("开始新会话" in " ".join(texts)))
    log("    旧输入框「发消息或按住说话」还在吗 = %s" % ("发消息或按住说话" in " ".join(texts)))
    snap("round6_home")

    log("[4] settings tab")
    tap(972, 2280)
    time.sleep(5)
    xml, texts = dump_texts("settings6")
    log("    texts: " + " | ".join(texts[:14]))
    log("    有「测试并保存」= %s" % ("测试并保存" in " ".join(texts)))
    log("    已就绪/已配置卡片 = %s" % ("已就绪" in " ".join(texts) or "配置已存在" in " ".join(texts)))
    snap("round6_settings")

    log("[5] library tab (确认 最近/我的资料 两个 Tab)")
    tap(540, 2280)
    time.sleep(6)
    _, texts = dump_texts("library6")
    joined = " ".join(texts)
    log("    有「最近」= %s  有「我的资料」= %s  残留「团队空间」= %s"
        % ("最近" in joined, "我的资料" in joined, "团队空间" in joined))

    log("[6] scheduled tab")
    tap(756, 2280)
    time.sleep(4)
    _, texts = dump_texts("sched6")
    log("    texts: " + " | ".join(texts[:10]))

    log("[7] home -> 开始新会话 -> 会话页")
    tap(108, 2280)
    time.sleep(3)
    xml, _ = dump_texts("home6b")
    center = find_center(xml, "开始新会话") if xml else None
    if center is None:
        log("    没找到「开始新会话」按钮，跳过")
    else:
        log("    tap 开始新会话 @ %s" % (center,))
        tap(*center)
        time.sleep(22)  # 等 ACP 起来
        xml, texts = dump_texts("chat6")
        log("    texts: " + " | ".join(texts[:14]))
        snap("round6_chat")
        # 找附件入口（+ 按钮），点开附件菜单，再点「添加文件」
        for needle in ("添加附件", "附件", "添加"):
            c = find_center(xml, needle) if xml else None
            if c:
                log("    tap 附件入口(%s) @ %s" % (needle, c))
                tap(*c)
                time.sleep(4)
                xml2, texts2 = dump_texts("attach6")
                log("    菜单 texts: " + " | ".join(texts2[:12]))
                snap("round6_attach")
                c2 = find_center(xml2, "添加文件") if xml2 else None
                if c2:
                    log("    tap 添加文件 @ %s（会拉起系统文件选择器）" % (c2,))
                    tap(*c2)
                    time.sleep(6)
                    snap("round6_picker")
                break

    log("[8] logcat: flutter errors / Kotlin exceptions")
    logcat = adb("logcat", "-d", timeout=240).stdout.decode("utf-8", "replace")
    bad = [l for l in logcat.splitlines()
           if ("dsh-flutter-error" in l or "AndroidRuntime" in l and "FATAL" in l
               or "ActivityNotFoundException" in l or "FileProvider" in l)]
    if bad:
        for line in bad[:20]:
            log("    " + line)
    else:
        log("    0 hits（没有 flutter 异常 / FATAL / ActivityNotFound / FileProvider 报错）")

    out = os.path.join(LOGS, "round6-smoke.txt")
    open(out, "w", encoding="utf-8").write("\n".join(report_lines))
    print("report -> " + out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
