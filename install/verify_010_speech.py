#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""复现"没有语音识别服务"时的表现：按一次「按住说话」，看界面会不会说出原因。

模拟器上只有 com.google.android.tts（没有语音识别服务），跟用户那台的情况类似，
所以这里能把"沉默失败"和"讲清原因"区分开。
"""
import os
import re
import sys
import time

REPO = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile"
PKG = "com.dshmobile.dsh_mobile"
sys.path.insert(0, os.path.join(REPO, "install"))
import verify_010_theme as v  # noqa: E402

out = []
note = out.append
note("# 语音：没有识别服务时，界面到底说了什么")
note("时间: %s" % time.strftime("%H:%M:%S"))

v.adb("logcat", "-c")
v.adb("shell", "am", "force-stop", PKG)
time.sleep(2)
v.adb("shell", "am", "start", "-n", "%s/.MainActivity" % PKG)
time.sleep(15)

home = v.dump("sp-home")
if not v.tap(home, "开始新会话"):
    note("!! 找不到「开始新会话」")
time.sleep(8)

chat = v.dump("sp-chat")
ct = v.texts(chat)
note("\n## 对话页可见文案（找「按住说话」）")
note("  " + "、".join(ct[:20]))
note("  含「按住说话」：%s" % any("按住说话" in t for t in ct))

# 「按住说话」= 长按，用 input swipe 原地 900ms 模拟
m = re.search(r'<node[^>]*(?:content-desc|text)="[^"]*按住说话[^"]*"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', chat)
if not m:
    note("!! 找不到「按住说话」节点")
else:
    x = (int(m.group(1)) + int(m.group(3))) // 2
    y = (int(m.group(2)) + int(m.group(4))) // 2
    note("\n## 长按「按住说话」(%d,%d)" % (x, y))
    v.adb("shell", "input", "swipe", str(x), str(y), str(x), str(y), "900")
    time.sleep(5)
    after = v.texts(v.dump("sp-after"))
    note("  按下后界面文案：")
    for t in after[:30]:
        note("    - %s" % t)
    hits = [t for t in after if ("语音" in t or "识别" in t or "麦克风" in t)]
    note("  提到语音/识别/麦克风的文案：%s" % (hits or "（没有 → 说明还是沉默失败）"))
    note("  截图: %s" % v.shot("20-语音失败提示.png"))

logs = v.adb("logcat", "-d", "-v", "time")[1]
note("\n## 日志")
for key in ["speech", "Speech", "DshLocal", "dsh-chat"]:
    hits = [l.strip()[-130:] for l in logs.splitlines() if key in l]
    note("  %s：%s" % (key, hits[-3:] if hits else "（无）"))

os.makedirs(os.path.join(REPO, "docs", "logs"), exist_ok=True)
txt = "\n".join(out)
with open(os.path.join(REPO, "docs", "logs", "verify-010-speech.txt"), "w", encoding="utf-8") as f:
    f.write(txt)
for line in [l for l in txt.splitlines() if l.isascii()][-14:]:
    print(line)
print("-> docs/logs/verify-010-speech.txt")
