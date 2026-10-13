# -*- coding: utf-8 -*-
"""第八轮验证：首页猫图标 / 会话标题 / 设置页多模型 / 专家单选。

结论写进 docs/logs/round8-check.txt（UTF-8），控制台只打 ASCII
（cp936 下直接 print 中文或 emoji 会抛异常，前面踩过）。

用法：C:\\Python314\\python.exe install\\check_round8.py
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


def tapxy(x, y):
    adb("shell", "input", "tap", str(x), str(y))


def main():
    os.makedirs(STAGE, exist_ok=True)
    report = []

    def add(s):
        report.append(s)

    adb("shell", "input", "keyevent", "4")
    time.sleep(1)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(26)

    # ---- 1. 首页：logo 语义标签（猫图是图片，语义树里只有 label）----
    home = labels(dump("r8-home"))
    joined = "\n".join(home)
    add("=== 1. 首页 ===")
    add("[%s] 有品牌 logo（semanticLabel=泡泡猫）" % ("OK" if "泡泡猫" in joined else "MISS"))
    add("[%s] 有「开始新会话」" % ("OK" if "开始新会话" in joined else "MISS"))

    # ---- 2. 会话页标题（不该再是硬编码那串）----
    for v in home:
        pass
    m = re.search(r'content-desc="开始新会话"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', dump("r8-home2"))
    if m:
        x1, y1, x2, y2 = (int(g) for g in m.groups())
        tapxy((x1 + x2) // 2, (y1 + y2) // 2)
        time.sleep(24)
        chat = labels(dump("r8-chat"))
        cj = "\n".join(chat)
        add("=== 2. 会话页标题 ===")
        add("[%s] 标题不再是硬编码的「最近爆火的一套抽象 AI 漫剧」"
            % ("OK" if "最近爆火的一套抽象 AI 漫剧" not in cj else "MISS"))
        add("[%s] 出现「新会话」" % ("OK" if "新会话" in cj else "MISS"))
        add("  会话页可见: " + " | ".join(chat[:10]))
        adb("shell", "input", "keyevent", "4")
        time.sleep(2)

    # ---- 3. 设置页：我的模型 / 多选 ----
    tapxy(972, 2280)
    time.sleep(5)
    for _ in range(4):
        adb("shell", "input", "swipe", "540", "1700", "540", "1000", "280")
        time.sleep(1)
    st = labels(dump("r8-settings"))
    sj = "\n".join(st)
    add("=== 3. 设置页（模型段）===")
    for k in ["我的模型", "勾选", "设为默认", "默认模型会被"]:
        add("[%s] 出现「%s」" % ("OK" if k in sj else "MISS", k))
    add("  可见片段: " + " | ".join(st[:12]))

    # ---- 4. 专家页：单选提示 ----
    tapxy(324, 2280)
    time.sleep(6)
    ex = labels(dump("r8-expert"))
    ej = "\n".join(ex)
    add("=== 4. 专家页 ===")
    add("[%s] 出现单选说明「同一时间只生效一位」"
        % ("OK" if "同一时间只生效一位" in ej else "MISS"))
    add("  可见片段: " + " | ".join(ex[:10]))

    # ---- 5. 无 flutter 异常 ----
    log = adb("logcat", "-d", timeout=240).stdout.decode("utf-8", "replace")
    errs = [l for l in log.splitlines() if "dsh-flutter-error" in l]
    add("=== 5. flutter 异常 ===")
    add("[%s] [dsh-flutter-error] 命中 %d 条" % ("OK" if not errs else "MISS", len(errs)))
    for l in errs[:6]:
        add("   " + l)

    out = os.path.join(LOGS, "round8-check.txt")
    open(out, "w", encoding="utf-8").write("\n".join(report))
    print("report -> %s" % out)
    for line in report:
        if line.startswith("["):
            print("  " + line.encode("ascii", "replace").decode("ascii"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
