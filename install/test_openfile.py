# -*- coding: utf-8 -*-
"""验证三件事：
  1) 切换底部按钮 = 刷新（切回资料库会重新扫描）
  2) 设置页模型段收起态也显示「我的模型」清单
  3) 原生"打开文件"通道通（用工作区里的 .pdf 走 other 分支 → 用其它应用打开）

用法：C:\\Python314\\python.exe install\\test_openfile.py
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
WS = "files/workspaces/moni-ws"


def adb(*a, timeout=240):
    r = subprocess.run([ADB, *a], capture_output=True, timeout=timeout)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def runas(*a):
    return adb("shell", "run-as", PKG, *a)


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


def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))


def lib_logs():
    log = adb("logcat", "-d", timeout=240)
    return [l for l in log.splitlines() if "[dsh-library] 工作区=" in l]


def main():
    os.makedirs(STAGE, exist_ok=True)
    rep = []

    # 造一个 .pdf 走 other 分支（touch 不需要重定向，避开 run-as 引号陷阱）
    rep.append("创建 probe.pdf: " + runas("touch", WS + "/probe.pdf").strip())
    rep.append("工作区内容: " + runas("ls", WS).replace("\n", " "))

    adb("shell", "input", "keyevent", "4")
    time.sleep(1)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(27)

    # ---- 1) 切到资料库：应该触发一次新扫描 ----
    n0 = len(lib_logs())
    tap(540, 2280)  # 资料库（下标 2）
    time.sleep(5)
    n1 = len(lib_logs())
    rep.append("")
    rep.append("=== 1) 切换即刷新 ===")
    rep.append("  [%s] 切到资料库后新增扫描日志 %d 条" % ("OK" if n1 > n0 else "MISS", n1 - n0))
    for l in lib_logs()[-1:]:
        rep.append("  最新: " + l.strip()[-110:])

    # 在资料库里找 probe.pdf 并打开
    xml = dump("lib")
    labs = labels(xml)
    rep.append("  资料库可见: " + " | ".join(v.replace("\n", " ")[:40] for v in labs[:8]))
    pdf = center(xml, "probe.pdf")
    rep.append("")
    rep.append("=== 3) 原生打开通道 ===")
    if not pdf:
        rep.append("  [MISS] 资料库里没找到 probe.pdf")
    else:
        rep.append("  点 probe.pdf @ %s" % (pdf,))
        tap(pdf[0], pdf[1])
        time.sleep(4)
        xml2 = dump("preview")
        labs2 = labels(xml2)
        rep.append("  预览页可见: " + " | ".join(v.replace("\n", " ")[:40] for v in labs2[:8]))
        btn = center(xml2, "用其它应用打开")
        if not btn:
            rep.append("  [MISS] 没找到「用其它应用打开」按钮")
        else:
            rep.append("  [OK] 有「用其它应用打开」按钮 @ %s" % (btn,))
            tap(btn[0], btn[1])
            time.sleep(5)
            log = adb("logcat", "-d", timeout=240)
            native = [l for l in log.splitlines() if "openFile" in l or "DshLocal" in l and "open" in l.lower()]
            dart = [l for l in log.splitlines() if "[dsh-library] 外部打开" in l]
            rep.append("")
            rep.append("  原生日志:")
            for l in (native[-4:] or ["  (无)"]):
                rep.append("    " + l.strip()[:150])
            rep.append("  Dart 日志:")
            for l in (dart[-2:] or ["  (无)"]):
                rep.append("    " + l.strip()[:150])
            ok = bool(dart) or bool(native)
            rep.append("  [%s] 打开了原生通道（有日志）" % ("OK" if ok else "MISS"))

    # ---- 2) 设置页模型段：收起态也要有「我的模型」 ----
    adb("shell", "input", "keyevent", "4")
    time.sleep(1)
    adb("shell", "input", "keyevent", "4")
    time.sleep(1)
    tap(972, 2280)  # 设置
    time.sleep(5)
    adb("shell", "input", "swipe", "540", "1700", "540", "1100", "280")
    time.sleep(2)
    xml3 = dump("settings")
    j = "\n".join(labels(xml3))
    rep.append("")
    rep.append("=== 2) 设置页模型段（收起态）===")
    rep.append("  [%s] 有「我的模型」" % ("OK" if "我的模型" in j else "MISS"))
    rep.append("  [%s] 有「该模型已就绪」或「模型已配置」" % ("OK" if ("已就绪" in j or "模型已配置" in j) else "MISS"))
    for v in labels(xml3):
        if "我的模型" in v or "模型已" in v or "deepseek" in v:
            rep.append("  可见: " + v.replace("\n", " / ")[:90])

    out = os.path.join(LOGS, "test-openfile.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    for line in rep:
        if line.strip().startswith("[") or line.strip().startswith("==="):
            print("  " + line.encode("ascii", "replace").decode("ascii")[:90])
    return 0


if __name__ == "__main__":
    sys.exit(main())
