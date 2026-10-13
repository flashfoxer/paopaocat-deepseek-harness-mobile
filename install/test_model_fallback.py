# -*- coding: utf-8 -*-
"""验证"未配置模型"兜底修复：删掉 models.json，看 App 能否自动恢复模型。

用户场景：models.json 丢了/没有，但模型其实配置过（对话能用）——
之前会显示"未配置模型"。修复后应从安全存储或 overlay 里兜底。

用法：C:\\Python314\\python.exe install\\test_model_fallback.py
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


def main():
    os.makedirs(STAGE, exist_ok=True)
    rep = []

    # 先记录 overlay 里的 model id（用和代码相同的正则）
    ov = runas("cat", "files/dshhome/model.overlay.yml")
    ids = re.findall(r'^\s*model:\s*(\S+)\s*$', ov, re.MULTILINE)
    ids = [i for i in ids if i and '$' not in i]
    rep.append("overlay 里的 model id: %s" % ids)

    # 模拟老用户：删掉 models.json
    rep.append("删除 models.json...")
    rep.append(runas("rm", "files/models.json"))
    rep.append("删除后 models.json 存在? " + ("是" if "models.json" in runas("ls", "files") else "否"))

    # 重启 App
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(28)

    # 打开会话
    xml = dump("f-home")
    c = center(xml, "开始新会话")
    if not c:
        rep.append("FAIL 没找到开始新会话")
    else:
        adb("shell", "input", "tap", str(c[0]), str(c[1]))
        time.sleep(24)
        labs = labels(dump("f-chat"))
        joined = "\n".join(labs)
        rep.append("")
        rep.append("=== 会话页模型区 ===")
        for v in labs:
            if "模型" in v or "deepseek" in v or "com" in v:
                rep.append("  " + v.replace("\n", " / ")[:80])
        rep.append("")
        has_model = any("deepseek" in v or "commandcode" in v or "moni" in v for v in labs)
        show_unconfigured = "未配置模型" in joined
        rep.append("  [%s] 显示的是模型名（不是未配置模型）" % ("OK" if not show_unconfigured else "MISS"))
        rep.append("  [%s] 模型区不再出现「未配置模型」" % ("OK" if "未配置模型" not in joined else "MISS"))

    # 关键日志
    rep.append("")
    rep.append("=== 兜底日志 ===")
    log = adb("logcat", "-d", timeout=240)
    for l in log.splitlines():
        if "[dsh-model]" in l or "自愈" in l:
            rep.append("  " + l.strip()[:200])

    # models.json 是否被自动补回
    rep.append("")
    rep.append("=== 重启后 models.json ===")
    rep.append(runas("cat", "files/models.json"))

    out = os.path.join(LOGS, "test-model-fallback.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    for line in rep:
        if line.strip().startswith("[") or "overlay" in line:
            print("  " + line.encode("ascii", "replace").decode("ascii")[:90])
    return 0


if __name__ == "__main__":
    sys.exit(main())
