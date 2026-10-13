#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
0.10 主题验证（我自己跑，不采信子代理的报告）。

子代理声称"7 张截图已复制到 theme-screenshots/"，但磁盘上根本不存在 —— 所以这里
**自己上模拟器重拍并读取语义树**，把证据落地：
  1. 进「设置」→ 找到主题三个按钮，断言「浅色 / 深色 / 自定义」都在；
  2. 点「浅色」→ 截图 + 读语义树里的 `dsh_theme_skin=light`；
  3. 点「深色」→ 截图 + 读到 `=dark`；
  4. 断言插件栏目新文案（不含"按你的要求"），模型区新分节（当前模型 / 我的模型 / 轮换组 / 添加模型 / Agnes）；
  5. 截图与结论都落到 <proj>\\theme-screenshots\\ 与 docs\\logs\\verify-010-theme.txt。
"""
import os
import re
import subprocess
import sys
import time

REPO = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile"
PKG = "com.dshmobile.dsh_mobile"
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
STAGE = r"D:\dev\uiverify\v010"
SHOTS = os.path.join(REPO, "theme-screenshots")
LOG_OUT = os.path.join(REPO, "docs", "logs", "verify-010-theme.txt")


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


def shot(name):
    os.makedirs(SHOTS, exist_ok=True)
    remote = "/sdcard/shot.png"
    adb("shell", "screencap", "-p", remote)
    dst = os.path.join(SHOTS, name)
    adb("pull", remote, dst)
    return os.path.exists(dst) and os.path.getsize(dst) > 10000


def main():
    out = []
    note = out.append
    note("# 0.10 主题 / 模型区 / 插件文案 —— 我自己在模拟器上的验证")
    note("时间: %s" % time.strftime("%Y-%m-%d %H:%M:%S"))

    rc, v = adb("shell", "dumpsys", "package", PKG)
    m = re.search(r"versionName=(\S+)", v)
    note("\n## 0. 设备上装的版本\nversionName=%s" % (m.group(1) if m else "?"))

    adb("logcat", "-c")
    adb("shell", "am", "force-stop", PKG)
    time.sleep(2)
    adb("shell", "am", "start", "-n", "%s/.MainActivity" % PKG)
    time.sleep(15)

    home = dump("home")
    note("\n## 1. 首页\n可见：%s" % "、".join(texts(home)[:14]))
    note("首页截图: %s" % shot("10-首页.png"))
    # 顺手记一下首页浅/深色像素（后面切完主题再取一次）
    if not tap(home, "设置"):
        note("!! 找不到「设置」")
    time.sleep(3)

    st = dump("settings")
    stt = texts(st)
    note("\n## 2. 设置页（外观）")
    for k in ["浅色", "深色", "自定义", "字号", "dsh_theme_skin"]:
        note("  含「%s」：%s" % (k, any(k in t for t in stt)))
    note("  含 dsh_theme_skin 的那行：%s"
         % ([t for t in stt if "dsh_theme_skin" in t][:2] or "（没读到）"))

    # ---- 切浅色 ----
    note("\n## 3. 点「浅色」")
    if tap(st, "浅色"):
        time.sleep(3)
        st2 = dump("light")
        t2 = texts(st2)
        note("  语义树里的落盘值：%s" % ([t for t in t2 if "dsh_theme_skin" in t][:2] or "（没读到）"))
        note("  截图: %s" % shot("01-设置-浅色.png"))
        note("  模型区关键词：%s"
             % "、".join([t for t in t2 if t in ("当前模型", "我的模型", "轮换组", "添加模型")]))
        note("  插件文案行：%s" % ([t for t in t2 if "插件" in t and len(t) > 12][:3] or "（未在首屏）"))
        note("  还含「按你的要求」：%s" % any("按你的要求" in t for t in t2))
        # 首页也拍一张（证明全树切换）
        if tap(st2, "首页"):
            time.sleep(3)
            note("  首页（浅色）截图: %s" % shot("03-首页-浅色.png"))
            tap(dump("back-to-settings"), "设置")
            time.sleep(3)
    else:
        note("  !! 找不到「浅色」按钮")

    # ---- 切深色 ----
    note("\n## 4. 点「深色」")
    st3 = dump("settings2")
    if tap(st3, "深色"):
        time.sleep(3)
        st4 = dump("dark")
        t4 = texts(st4)
        note("  语义树里的落盘值：%s" % ([t for t in t4 if "dsh_theme_skin" in t][:2] or "（没读到）"))
        note("  截图: %s" % shot("02-设置-深色.png"))
    else:
        note("  !! 找不到「深色」按钮")

    # ---- 点自定义：必须只说明、不切状态 ----
    # 注意：这一步会弹说明层，**会挡住后面的滑动**（第一版就跑出这个假结论：
    # 模型区五个分节标题一条没扫到）。所以要单独验模型区时用 SKIP_CUSTOM=1。
    if os.environ.get("SKIP_CUSTOM") == "1":
        note("\n## 5. 点「自定义（占位）」—— 本轮跳过（SKIP_CUSTOM=1，专验模型区）")
    else:
        note("\n## 5. 点「自定义（占位）」")
        st5 = dump("settings3")
        before = [t for t in texts(st5) if "dsh_theme_skin" in t]
        if tap(st5, "自定义"):
            time.sleep(2)
            st6 = dump("custom")
            t6 = texts(st6)
            note("  是否出现「还没做」之类如实说明：%s"
                 % any(("还没做" in t) or ("不会切主题" in t) or ("占位" in t) for t in t6))
            note("  落盘值（应仍是 dark）：%s" % ([t for t in t6 if "dsh_theme_skin" in t][:2] or before))
            # 把说明层关掉，别挡住后面的滑动
            for dismiss in ("知道了", "确定", "好的", "关闭"):
                if tap(st6, dismiss):
                    note("  已点「%s」关掉说明层" % dismiss)
                    break
            time.sleep(1)
        else:
            note("  !! 找不到「自定义」按钮")
        note("  截图: %s" % shot("04-自定义-占位.png"))

    # ---- 模型区：再往下滑看分节 ----
    note("\n## 6. 模型区分节（滚动采集）")
    seen = list(dict.fromkeys(texts(dump("m0"))))
    for i in range(6):
        adb("shell", "input", "swipe", "540", "1800", "540", "900", "600")
        time.sleep(2)
        seen.extend(texts(dump("m%d" % (i + 1))))
    seen = list(dict.fromkeys(seen))
    for k in ["当前模型", "我的模型", "轮换组", "添加模型", "Agnes"]:
        note("  含「%s」：%s" % (k, any(k in t for t in seen)))
    note("  含「按你的要求」：%s" % any("按你的要求" in t for t in seen))
    note("  插件相关文案：%s" % ([t for t in seen if "插件" in t][:5]))
    note("  截图: %s" % shot("05-模型区-收起态.png"))

    # ---- 逐屏截图：给"5 个分节的顺序 + 收起态"留可视证据 ----
    # 为什么一定要截图：这两个分节标题**在语义树里读不到**（缺语义，子代理正在补），
    # 所以顺序只能靠人/视觉模型看图核对。
    if os.environ.get("SCROLL_SHOTS") == "1":
        note("\n## 6b. 逐屏截图（滚动把模型区整段拍下来）")
        # 先回到页面顶部
        for _ in range(8):
            adb("shell", "input", "swipe", "540", "900", "540", "1900", "400")
            time.sleep(1)
        time.sleep(2)
        for i in range(7):
            name = "06-模型区滚动-%d.png" % (i + 1)
            note("  %s -> %s" % (name, shot(name)))
            adb("shell", "input", "swipe", "540", "1800", "540", "1100", "700")
            time.sleep(2)

    logs = adb("logcat", "-d", "-v", "time")[1]
    note("\n## 7. 运行期日志")
    note("- flutter 异常：%s" % ("有" if "[dsh-flutter-error]" in logs else "无"))
    note("- RenderFlex overflow：%s" % ("有" if "overflowed" in logs else "无"))

    os.makedirs(os.path.dirname(LOG_OUT), exist_ok=True)
    txt = "\n".join(out)
    with open(LOG_OUT, "w", encoding="utf-8") as f:
        f.write(txt)
    for line in [l for l in txt.splitlines() if l.isascii()][-20:]:
        print(line)
    print("\n[verify-010-theme] -> %s" % LOG_OUT.replace("\\", "/"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
