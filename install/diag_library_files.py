# -*- coding: utf-8 -*-
"""诊断：AI 生成的文件到底落在哪，资料库又在扫哪。

用户反馈「让生成一个 ppt，结果没在资料库看见」——两种可能：
  ① 文件写成功了，但资料库扫的目录 ≠ 会话的 cwd；
  ② Android 沙箱下模型根本没写成功（之前实测 bash/glob 都失败，只有 read 能用）。

⚠️ 实现细节：`run-as pkg sh -c '复杂命令'` 里的**单引号会被外层 adb shell 吃掉**，
于是重定向/管道/`find` 的参数会错位（本轮已经踩过一次）。
所以这里一律用 `adb shell run-as <pkg> <cmd> <arg> ...` 的直呼形式，不套 sh -c。

结论写 docs/logs/diag-library-files.txt（UTF-8），控制台只打 ASCII。

用法：C:\\Python314\\python.exe install\\diag_library_files.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
LOGS = os.path.join(ROOT, "docs", "logs")
PKG = "com.dshmobile.dsh_mobile"


def adb(*a, timeout=180):
    r = subprocess.run([ADB, *a], capture_output=True, timeout=timeout)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def runas(*a):
    """直呼 run-as，不套 sh -c（避免引号被外层 shell 吃掉）。"""
    return adb("shell", "run-as", PKG, *a)


def main():
    os.makedirs(LOGS, exist_ok=True)
    rep = []

    rep.append("=== 1) logcat：会话 cwd / 工作区 / 会话就绪 ===")
    log = adb("logcat", "-d", timeout=240)
    for line in log.splitlines():
        s = line.strip()
        if any(k in s for k in ["[chat]", "[dsh-nav]", "[dsh-ws]", "[ws-index]", "[dsh-library]"]):
            if any(k in s for k in ["cwd", "workspace", "ready", "resumed", "工作区", "扫描"]):
                rep.append("  " + s[:220])
    rep.append("")

    for label, args in [
        ("2) files/ 顶层", ("ls", "-la", "files/")),
        ("3) workspaces.json（工作区登记表）", ("cat", "files/workspaces.json")),
        ("4) files/workspaces 递归（前 60 行）", ("ls", "-laR", "files/workspaces")),
        ("5) files/workspace（单数，默认工作区）", ("ls", "-la", "files/workspace")),
        ("6) 找 pptx/ppt", ("find", "files", "-name", "*.pptx", "-o", "-name", "*.ppt")),
        ("7) 找常见产物（md/txt/html/docx/xlsx）", ("find", "files", "-name", "*.md", "-o", "-name",
                                                     "*.txt", "-o", "-name", "*.html", "-o", "-name",
                                                     "*.docx", "-o", "-name", "*.xlsx")),
    ]:
        rep.append("=== %s ===" % label)
        out = runas(*args)
        lines = out.splitlines()
        # dshhome 里是运行时自带的东西，噪音很大，折叠掉
        noisy = [l for l in lines if "node_modules" in l or "/dsh/lib/" in l]
        clean = [l for l in lines if "node_modules" not in l and "/dsh/lib/" not in l]
        rep.extend(clean[:60])
        if noisy:
            rep.append("  …（另有 %d 行落在运行时目录里，已折叠）" % len(noisy))
        rep.append("")

    rep.append("=== 8) 写盘失败痕迹（沙箱/权限）===")
    hits = []
    for line in log.splitlines():
        low = line.lower()
        if any(k in low for k in ["permission denied", "read-only file system", "eacces",
                                  "sandbox", "isn't usable", "not usable"]):
            hits.append("  " + line.strip()[:220])
    rep.extend(hits[-25:] if hits else ["  (无)"])
    rep.append("")

    rep.append("=== 9) 模型提到 ppt / 文件名的地方 ===")
    for line in log.splitlines():
        low = line.lower()
        if ("pptx" in low or "ppt" in low or "幻灯片" in line or "slide" in low) and "[chat]" in line:
            rep.append("  " + line.strip()[:220])

    out = os.path.join(LOGS, "diag-library-files.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
