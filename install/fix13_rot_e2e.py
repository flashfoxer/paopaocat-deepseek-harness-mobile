# -*- coding: utf-8 -*-
"""轮换池端到端验证：第一个成员 429、第二个正常 —— 池子到底会不会换人？

前置：`python install/fix13_fake_rot.py 8891` + `adb reverse tcp:8891 tcp:8891`，
并且设备上的 models.json 已换成 install/../fix13-rot-models.json（两个厂家 + 组 cat）。

判定（三条都要看）：
  A. 假上游日志：先 /aaa 429，紧接着 /bbb 200  → 真的换人了
  B. App 日志：`cat: … 失败(429)，改用 …` + `… 成功（第 2 个成员顶上）`（这两条**无条件**打）
  C. 界面：拿到 bbb 的回答，而不是 429 报错

用法：python -X utf8 install\\fix13_rot_e2e.py
"""
import os
import re
import subprocess
import sys
import time

ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
STAGE = r"D:\dev\uiverify"
PKG = "com.dshmobile.dsh_mobile"


def adb(*a, timeout=240):
    return subprocess.run([ADB, *a], capture_output=True, timeout=timeout)


def adb_out(*a, timeout=240):
    r = adb(*a, timeout=timeout)
    return (r.stdout + r.stderr).decode("utf-8", "replace")


def runas(cmd):
    return adb_out("shell", "run-as", PKG, *cmd.split(" "))


def dump(tag):
    os.makedirs(STAGE, exist_ok=True)
    adb("shell", "uiautomator", "dump")
    local = os.path.join(STAGE, "rot-%s.xml" % tag)
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


def find_center(xml, needle):
    best = None
    for m in re.finditer(r"<node[^>]*?>", xml):
        node = m.group(0)
        texts = []
        for pat in (r'content-desc="([^"]*)"', r'text="([^"]*)"'):
            mm = re.search(pat, node)
            if mm:
                texts.append(mm.group(1))
        if not any(needle in t for t in texts):
            continue
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        if not b:
            continue
        x1, y1, x2, y2 = (int(g) for g in b.groups())
        if x2 > x1 and y2 > y1:
            best = ((x1 + x2) // 2, (y1 + y2) // 2)
    return best


def main():
    adb("shell", "logcat", "-c")
    adb("shell", "am", "force-stop", PKG)
    time.sleep(1)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    print("[1] 启动 App（会按新 models.json 重生成 overlay），等 32s", flush=True)
    time.sleep(32)

    print("[2] App 自己生成的 overlay（看 rotate 段与默认 route）", flush=True)
    ov = runas("cat files/dshhome/model.overlay.yml")
    for ln in ov.splitlines():
        if ln.strip() and not ln.strip().startswith("#"):
            print("     " + ln.rstrip(), flush=True)

    print("[3] 代理配置（看两个成员的端点）", flush=True)
    print("     " + runas("cat files/toolbox/rotate-config.json").replace("\n", "\n     "), flush=True)

    xml = dump("home")
    tip = find_center(xml, "做一份") or find_center(xml, "帮我") or find_center(xml, "进行")
    if not tip:
        print("FAIL: 首页找不到内置会话入口", flush=True)
        return 1
    adb("shell", "input", "tap", str(tip[0]), str(tip[1]))
    print("[4] 开了会话，等就绪…", flush=True)

    xml2 = ""
    for _ in range(40):
        time.sleep(6)
        xml2 = dump("ready")
        if "正在启动" not in " ".join(labels(xml2)):
            break
    print("[5] 会话页可见: " + " | ".join(labels(xml2)[:12]), flush=True)

    send = find_center(xml2, "发送")
    if not send:
        print("FAIL: 没有发送按钮", flush=True)
        return 1
    adb("shell", "input", "tap", str(send[0]), str(send[1]))
    print("[6] 点发送，等回答（池子要先吃一个 429）…", flush=True)

    for i in range(12):
        time.sleep(8)
        lab = " ".join(labels(dump("wait")))
        if "已完成" in lab or "bbb" in lab or "429" in lab or "速率" in lab:
            break
    lab = " | ".join(labels(dump("final")))
    print("[7] 最终可见: " + lab[:400], flush=True)

    lg = adb_out("logcat", "-d", "-v", "time")
    with open(r"D:\dev\build\fix13-rot-logcat.txt", "w", encoding="utf-8", errors="replace") as f:
        f.write(lg)
    print("=== [8] App 日志里的轮换相关行 ===", flush=True)
    for ln in lg.splitlines():
        if "dsh-rotate" in ln or "rotate]" in ln or "[chat] ACP session ready" in ln \
                or "运行时报" in ln or "prompt failed" in ln or "轮换" in ln:
            print("     " + ln.strip()[:240], flush=True)
    print("（结论以假上游那侧为准：见 fix13_fake_rot 的 job 输出）", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
