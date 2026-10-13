#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
0.09 验证：轮换组是否真的出现在**模型列表**里（用户第 6 条原话：
「模型轮换，取一个名字，可以显示在模型列表」）。

路径：冷启动 → 首页点「开始新会话」进对话页 → 点输入区那个模型按钮 → 弹模型面板
      → 断言面板里有 `cat` 且带「轮换组」标记 → 点它 → 再 dump 确认没崩、选中项还在。
结论写 <repo>/docs/logs/verify-009-modelsheet.txt（UTF-8）。
"""
import os
import re
import subprocess
import sys
import time

REPO = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile"
PKG = "com.dshmobile.dsh_mobile"
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
LOG_OUT = os.path.join(REPO, "docs", "logs", "verify-009-modelsheet.txt")
STAGE = r"D:\dev\uiverify\v009\sheet"


def run(args, timeout=300):
    p = subprocess.run(args, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")


def adb(*a, **k):
    return run([ADB, *a], **k)


def dump(tag, attempts=8):
    os.makedirs(STAGE, exist_ok=True)
    local = os.path.join(STAGE, "d-%s.xml" % tag)
    for _ in range(attempts):
        adb("shell", "uiautomator", "dump", "/sdcard/wd.xml")
        if os.path.exists(local):
            try:
                os.remove(local)
            except OSError:
                pass
        adb("pull", "/sdcard/wd.xml", local)
        try:
            with open(local, "r", encoding="utf-8", errors="replace") as f:
                t = f.read()
            if re.search(r'text="[^"]+"|content-desc="[^"]+"', t):
                return t
        except Exception:
            pass
        time.sleep(2)
    return ""


def texts(xml):
    raw = re.findall(r'content-desc="([^"]*)"', xml) + re.findall(r'text="([^"]*)"', xml)
    out = []
    for it in raw:
        for p in re.split(r"&#10;|\n", it):
            p = p.strip()
            if p and p not in out:
                out.append(p)
    return out


def tap(xml, needle):
    for m in re.finditer(
        r'<node[^>]*?(?:content-desc|text)="[^"]*%s[^"]*"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"' % re.escape(needle),
        xml,
    ):
        seg = xml[m.start():m.end()]
        if 'clickable="true"' in seg:
            x1, y1, x2, y2 = (int(m.group(i)) for i in range(1, 5))
            adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
            return True
    return False


def main():
    out = []
    note = out.append
    note("# 0.09 验证：轮换组出现在模型列表里")
    note("时间: %s" % time.strftime("%Y-%m-%d %H:%M:%S"))

    adb("logcat", "-c")
    adb("shell", "am", "force-stop", PKG)
    time.sleep(2)
    adb("shell", "am", "start", "-n", "%s/.MainActivity" % PKG)
    time.sleep(15)

    home = dump("home")
    note("\n## 1. 首页 → 点「开始新会话」")
    note("首页可见文案（前 12 条）：%s" % "、".join(texts(home)[:12]))
    if not tap(home, "开始新会话"):
        note("!! 没找到「开始新会话」")
    time.sleep(8)

    chat = dump("chat")
    ct = texts(chat)
    note("\n## 2. 对话页")
    note("可见文案：\n" + "\n".join("  - %s" % t for t in ct[:25]))
    # 输入区的模型按钮：文案含当前模型名（这里是轮换组名 cat）
    target = None
    for cand in ("当前模型 cat", "cat", "rotate/cat", "选择模型", "未配置模型"):
        if any(cand in t for t in ct):
            target = cand
            break
    note("准备点开的模型按钮文案：%s" % target)

    if target and tap(chat, target):
        time.sleep(3)
        sheet = dump("sheet")
        st = texts(sheet)
        note("\n## 3. 模型面板")
        note("可见文案：\n" + "\n".join("  - %s" % t for t in st[:35]))
        note("面板里有「cat」：%s" % any("cat" in t for t in st))
        note("面板里有「轮换组」标记：%s" % any("轮换组" in t for t in st))
        # 点一下组，确认不崩
        if tap(sheet, "cat"):
            time.sleep(3)
            after = texts(dump("after-select"))
            logs = adb("logcat", "-d", "-v", "time")[1]
            note("\n## 4. 点选之后")
            note("可见文案：%s" % "、".join(after[:15]))
            note("有 flutter 异常：%s" % ("是" if "[dsh-flutter-error]" in logs else "否"))
            note("模型切换日志：%s"
                 % ([l.strip()[-120:] for l in logs.splitlines() if "dsh-model] overlay" in l][-1:] or "（无）"))
    else:
        note("!! 对话页里没找到可点的模型按钮")

    logs = adb("logcat", "-d", "-v", "time")[1]
    note("\n## 5. 关键日志")
    for key in ["dsh-model] 清单载入", "dsh-rotate] 代理已就绪", "dsh-flutter-error"]:
        hits = [l.strip() for l in logs.splitlines() if key in l]
        note("- %s：%s" % (key, hits[-1][:150] if hits else "（无）"))

    os.makedirs(os.path.dirname(LOG_OUT), exist_ok=True)
    text = "\n".join(out)
    with open(LOG_OUT, "w", encoding="utf-8") as f:
        f.write(text)
    for l in [x for x in text.splitlines() if x.isascii()][-20:]:
        print(l)
    print("\n[verify-modelsheet] full log -> %s" % LOG_OUT.replace("\\", "/"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
