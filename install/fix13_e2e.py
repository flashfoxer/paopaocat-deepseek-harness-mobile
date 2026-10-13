# -*- coding: utf-8 -*-
"""0.13 端到端验证（会自己等会话就绪）：

  A. 会话里到底能不能跑命令 —— 假模型（install/fix13_fake_model.py）第一轮直接发
     3 个 `bash` 工具调用，第二轮把工具结果念回来。设备上看到的输出就是证据。
  B. 切模型是不是**一次**就生效 —— 点模型面板换个已注册模型，看是否只点一次就切过去
     （logcat 里应有「会话内切换模型成功」且**没有**新的「ACP session ready」）。

用法：python -X utf8 install\\fix13_e2e.py
"""
import os
import re
import subprocess
import sys
import time

ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
STAGE = r"D:\dev\uiverify"
PKG = "com.dshmobile.dsh_mobile"
REPORT = r"D:\dev\build\fix13-report.txt"

REPORT_LINES = []


def say(msg):
    print(msg, flush=True)
    REPORT_LINES.append(msg)


def adb(*a, timeout=240):
    return subprocess.run([ADB, *a], capture_output=True, timeout=timeout)


def adb_out(*a, timeout=240):
    r = adb(*a, timeout=timeout)
    return (r.stdout + r.stderr).decode("utf-8", "replace")


def dump(tag):
    os.makedirs(STAGE, exist_ok=True)
    adb("shell", "uiautomator", "dump")
    local = os.path.join(STAGE, "fix13-%s.xml" % tag)
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


def find_center(xml, needle, exact=False):
    best = None
    for m in re.finditer(r"<node[^>]*?>", xml):
        node = m.group(0)
        texts = []
        for pat in (r'content-desc="([^"]*)"', r'text="([^"]*)"'):
            mm = re.search(pat, node)
            if mm:
                texts.append(mm.group(1))
        if not texts:
            continue
        if not any((t.strip() == needle) if exact else (needle in t) for t in texts):
            continue
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        if not b:
            continue
        x1, y1, x2, y2 = (int(g) for g in b.groups())
        if x2 > x1 and y2 > y1:
            best = ((x1 + x2) // 2, (y1 + y2) // 2)
    return best


def tap(pt):
    adb("shell", "input", "tap", str(pt[0]), str(pt[1]))


def logcat_dump(tag):
    txt = adb_out("logcat", "-d", "-v", "time")
    with open(r"D:\dev\build\fix13-logcat-%s.txt" % tag, "w", encoding="utf-8", errors="replace") as f:
        f.write(txt)
    return txt


def chat_lines(txt):
    return [
        ln.strip()[:260]
        for ln in txt.splitlines()
        if "[chat]" in ln or "[acp" in ln or "exec-shim" in ln or "android-fs-shim" in ln
    ]


def wait_ready(tag, timeout=300):
    """等「正在启动 DSH 会话…」消失（模拟器上 ACP 初始化实测要 35s 以上）。"""
    t0 = time.time()
    last = ""
    while time.time() - t0 < timeout:
        xml = dump(tag)
        lab = " ".join(labels(xml))
        last = lab
        if "正在启动" not in lab and "准备" not in lab:
            return xml, True
        time.sleep(6)
    return dump(tag + "-timeout"), False


def main():
    adb("shell", "logcat", "-c")
    adb("shell", "am", "force-stop", PKG)
    time.sleep(1)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    say("[1] 已启动 App，等 30s…")
    time.sleep(30)

    xml = dump("home")
    say("[2] 首页可见: " + " | ".join(labels(xml)[:12]))
    tip = find_center(xml, "做一份") or find_center(xml, "帮我") or find_center(xml, "进行")
    if not tip:
        say("FAIL: 首页找不到内置会话入口")
        return 1
    tap(tip)
    say("[3] 点了内置会话入口 @ %s，等会话就绪…" % (tip,))

    xml, ok = wait_ready("ready")
    say("[4] 会话就绪=%s；可见: %s" % (ok, " | ".join(labels(xml)[:14])))

    print("=== A) ACP 进程环境（这是「修没修」的硬证据）===", flush=True)
    ps = adb_out("shell", "ps", "-A")
    for ln in ps.splitlines():
        if "libnode" in ln:
            pid = [p for p in ln.split() if p.isdigit()][:1]
            if not pid:
                continue
            raw = adb_out("shell", "cat /proc/%s/environ" % pid[0])
            env = dict(kv.split("=", 1) for kv in raw.split("\x00") if "=" in kv)
            say("[5] ACP pid=%s" % pid[0])
            for k in (
                "DSH_ANDROID_EXEC_SHIM",
                "DSH_ANDROID_TOOLBOX",
                "DSH_ANDROID_TMPDIR",
                "AGNES_API_KEY",
            ):
                v = env.get(k)
                if k == "AGNES_API_KEY" and v:
                    v = v[:4] + "***"
                say("      %-24s %s" % (k, v or "<缺失>"))

    send = find_center(xml, "发送")
    if not send:
        say("FAIL: 没找到发送按钮")
        return 1
    tap(send)
    say("[6] 已点发送 @ %s，等模型+工具跑完…" % (send,))

    got = False
    for i in range(24):
        time.sleep(10)
        xmlw = dump("wait")
        lab = " ".join(labels(xmlw))
        say("      +%ds: %s" % ((i + 1) * 10, lab[:200]))
        if "DSH_SHIM_OK" in lab or "NODE_OK" in lab or "工具箱" in lab or "已完成" in lab:
            got = True
            break
    say("[7] 看到工具输出=%s" % got)

    xmlf = dump("final")
    say("=== A-2) 会话页最终可见 ===")
    for v in labels(xmlf):
        say("   - " + v[:400])

    lg = logcat_dump("A")
    say("=== A-3) logcat（app 侧 [chat]/[acp]）===")
    for ln in chat_lines(lg):
        say("   " + ln)

    # ───────────────────────────── B) 切模型：一次就生效？
    say("=== B) 切模型测试 ===")
    chip = find_center(xmlf, "当前模型")
    if not chip:
        say("WARN: 找不到模型入口，跳过 B")
    else:
        tap(chip)
        time.sleep(2.5)
        xmls = dump("sheet")
        say("[B1] 模型面板可见: " + " | ".join(labels(xmls)[:16]))
        grp = find_center(xmls, "agnes，")
        if not grp:
            grp = find_center(xmls, "agnes")
        if grp:
            tap(grp)
            time.sleep(2)
            xmls2 = dump("sheet-open")
            say("[B2] 展开后可见: " + " | ".join(labels(xmls2)[:20]))
            row = find_center(xmls2, "agnes-m2")
            if row:
                t_before = time.time()
                tap(row)
                say("[B3] 点了 agnes-m2 @ %s" % (row,))
                time.sleep(3)
                xmlr = dump("after-switch")
                say("[B4] 切换后可见: " + " | ".join(labels(xmlr)[:16]))
                lg2 = logcat_dump("B")
                say("=== B-5) 切换相关日志（本次点击 %.0fs 后）===" % (time.time() - t_before))
                for ln in chat_lines(lg2):
                    say("   " + ln)
            else:
                say("WARN: 展开后没看到 agnes-m2 行")
        else:
            say("WARN: 面板里没找到 agnes 分组")

    with open(REPORT, "w", encoding="utf-8") as f:
        f.write("\n".join(REPORT_LINES))
    say("报告已写入 " + REPORT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
