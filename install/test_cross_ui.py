# -*- coding: utf-8 -*-
"""UI 交叉点实测 + 复核 cwd（上次日志被我 s[:200] 截断了，要看完整行）。

三件事：
  1) 完整读最新一次 "ACP session ready" 的 cwd（不截断）
  2) 打开「资料库」→ 抓最新 [dsh-library] 日志，确认产物 sandbox_probe.txt 被扫到
  3) 打开会话 → 找「专家中心」→ 确认已开专家（人类学家）出现

用法：C:\\Python314\\python.exe install\\test_cross_ui.py
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
    r = subprocess.run([ADB, *a], capture_output=True, timeout=timeout)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


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

    # 1) 完整 cwd（不截断）
    rep.append("=== 1) 最新一次会话的完整 cwd ===")
    log = adb("logcat", "-d", timeout=240)
    ready = [l for l in log.splitlines() if "ACP session ready" in l]
    for l in ready[-2:]:
        rep.append("  " + l.strip())

    # 2) 资料库
    adb("shell", "input", "keyevent", "4")
    time.sleep(1)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(26)
    adb("shell", "input", "tap", "540", "2280")   # 底部导航第 3 项：资料库
    time.sleep(5)
    xml = dump("x-library")
    labs = labels(xml)
    rep.append("")
    rep.append("=== 2) 资料库可见文本 ===")
    rep.extend("  " + v.replace("\n", " / ")[:80] for v in labs[:20])
    rep.append("")
    # 最新一次资料库扫描日志
    lib = [l for l in log.splitlines() if "[dsh-library]" in l]
    # 上面 log 是旧快照；重新抓一次
    log2 = adb("logcat", "-d", timeout=240)
    lib2 = [l for l in log2.splitlines() if "[dsh-library]" in l]
    for l in lib2[-2:]:
        rep.append("  最新扫描日志: " + l.strip()[:220])

    # 3) 会话 -> 专家中心
    adb("shell", "input", "tap", "108", "2280")   # 回首页
    time.sleep(3)
    adb("shell", "input", "tap", "1004", "275")   # 右上角工作区入口? 不，先回首页再开始新会话
    time.sleep(2)
    adb("shell", "input", "keyevent", "4")
    time.sleep(2)
    adb("shell", "input", "tap", "108", "2280")
    time.sleep(3)
    xml = dump("x-home")
    c = center(xml, "开始新会话")
    if c:
        adb("shell", "input", "tap", str(c[0]), str(c[1]))
        time.sleep(24)
        xml = dump("x-chat")
        labs = labels(xml)
        rep.append("")
        rep.append("=== 3) 会话页可见（找专家入口）===")
        rep.extend("  " + v.replace("\n", " / ")[:70] for v in labs[:16])
        ec = center(xml, "专家") or center(xml, "专家中心")
        if ec:
            rep.append("  点「专家」入口 @ %s" % (ec,))
            adb("shell", "input", "tap", str(ec[0]), str(ec[1]))
            time.sleep(4)
            xml = dump("x-experts")
            labs = labels(xml)
            joined = "\n".join(labs)
            rep.append("")
            rep.append("=== 3b) 专家中心可见 ===")
            rep.extend("  " + v.replace("\n", " / ")[:70] for v in labs[:16])
            rep.append("")
            rep.append("  [%s] 出现已开专家「人类学家」" % ("OK" if "人类学家" in joined else "MISS"))
            rep.append("  [%s] 不该出现未开的「地理学家」" % ("OK" if "地理学家" not in joined else "MISS"))
        else:
            rep.append("  没找到「专家」入口")

    out = os.path.join(LOGS, "test-cross-ui.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    for line in rep:
        if line.strip().startswith("[") or line.strip().startswith("最新") or "OK" in line or "MISS" in line:
            print("  " + line.encode("ascii", "replace").decode("ascii")[:90])
    return 0


if __name__ == "__main__":
    sys.exit(main())
