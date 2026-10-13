#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
0.09 界面侧验证（真机/模拟器，通过 adb + uiautomator）。

这一版界面上新增/改动的东西，用 uiautomator 的语义树 + adb logcat 来验：
  1. 首页内置会话：从 4 条变 12 条池子、一次显示 6 条；点「换一换」应换**一批不同的**
     （老实现是 (i+1)%4，同样的 4 条换顺序 —— 这里就是要验它不再是那样）。
  2. 设置页：多厂家分组（「我的模型」）+「轮换组」区块存在（用户第 5、6 条）。
  3. logcat 里的关键自证日志（内置技能安装数、工具栏落盘、轮换代理就绪等）。

用法：
  python verify_009_ui.py            # 只做界面与日志检查（不调模型、不花 token）
结论写 <repo>/docs/logs/verify-009-ui.txt（UTF-8）；控制台只打 ASCII 摘要。
"""
import argparse
import os
import re
import subprocess
import sys
import time

REPO = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile"
PKG = "com.dshmobile.dsh_mobile"
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
LOG_OUT = os.path.join(REPO, "docs", "logs", "verify-009-ui.txt")

# ⚠️ adb pull/push 的**中文路径会失败**（本项目的老坑）：所以 dump 的 XML 先落到
# 这个纯 ASCII 目录，再从那里读。
PULL_DIR = r"D:\dev\uiverify\v009"

# 首页 12 条内置会话的标题（与 lib/data/builtin_starters.dart 一致）
STARTER_TITLES = [
    "做一份幻灯片", "生成一张图片", "生成一段视频", "数据分析与可视化",
    "文档处理", "长文速读提炼", "表格整理", "代码小工具",
    "文件整理归档", "中英互译润色", "生成学习卡片", "汇总一份周报",
]

# logcat 里应当出现的关键日志（tag 前缀 → 说明）
EXPECTED_LOGS = {
    "[dsh-toolbox] 已落盘": "随包工具箱落盘",
    "[dsh-skills] 内置技能": "内置技能安装统计",
    "[dsh-expert] AGENTS.md": "AGENTS.md 受管区块（执行环境说明）",
}


def run(args, timeout=180):
    p = subprocess.run(args, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")


def adb(*args, **kw):
    return run([ADB, *args], **kw)


def dump_ui(tag="ui", attempts=8):
    """把当前界面 dump 到本地（ASCII 暂存目录）并返回 XML 文本（失败返回空串）。

    ⚠️ 两个真实坑：
      * `adb pull/push` 不认中文路径 → XML 先落到 [PULL_DIR]；
      * 刚启动的窗口会返回 `null root node returned by UiTestAutomationBridge`
        （界面还没建好）→ 必须重试，不能一次失败就下结论。
    """
    os.makedirs(PULL_DIR, exist_ok=True)
    local = os.path.join(PULL_DIR, "v009-%s.xml" % tag)
    last = ""
    for i in range(attempts):
        adb("shell", "uiautomator", "dump", "/sdcard/window_dump.xml")
        if os.path.exists(local):
            try:
                os.remove(local)
            except OSError:
                pass
        rc, pull_out = adb("pull", "/sdcard/window_dump.xml", local)
        try:
            with open(local, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
            # ⚠️ 只看"文件非空"是不够的：冷启动那几秒 Flutter 只画出一个空壳，
            # 语义树里全是 text="" 的 View 节点。必须等到**真的有文字**才算 dump 成功，
            # 否则会拿一份空树去下结论（我第一版就踩了这个）。
            if text.strip() and re.search(r'text="[^"]+"|content-desc="[^"]+"', text):
                return text
        except Exception as e:
            last = str(e)
        time.sleep(2)
    print("  !! dump 失败（重试 %d 次）: %s | pull=%s" % (attempts, last, pull_out.strip()[:80]))
    return ""


def texts_in(xml):
    """取出 dump 里所有可见文案。

    ⚠️ Flutter 的语义树把文字放在 **content-desc** 里（`text=` 全是空的），
    而且会把一条节点的多个标签用换行拼在一起（dump 里写作 `&#10;`）——
    所以这里两个属性都收，并按换行拆开。
    """
    raw = []
    raw += re.findall(r'content-desc="([^"]*)"', xml)
    raw += re.findall(r'text="([^"]*)"', xml)
    out = []
    for item in raw:
        for piece in re.split(r'&#10;|\n', item):
            piece = piece.strip()
            if piece and piece not in out:
                out.append(piece)
    return out


def bounds_of(xml, needle):
    """按文案**子串**找可点节点的中心，返回 (cx, cy) 或 None。

    优先返回 clickable=true 的那个（Flutter 里外层容器也常带同一份 label）。
    """
    pat = re.escape(needle)
    best = None
    for m in re.finditer(
        r'<node[^>]*?(?:content-desc|text)="[^"]*%s[^"]*"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"[^>]*?>' % pat,
        xml,
    ):
        seg_start = xml.rfind('<node', 0, m.start() + 1)
        seg = xml[m.start():m.end()]
        clickable = 'clickable="true"' in seg
        x1, y1, x2, y2 = (int(m.group(i)) for i in range(1, 5))
        cand = ((x1 + x2) // 2, (y1 + y2) // 2)
        if clickable:
            return cand
        best = best or cand
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-launch", action="store_true")
    args = ap.parse_args()

    out = []
    def note(line=""):
        out.append(line)

    note("# 0.09 界面侧验证")
    note("时间: %s" % time.strftime("%Y-%m-%d %H:%M:%S"))

    rc, devices = adb("devices")
    note("\n## 设备\n%s" % devices.strip())

    # 冷启动（先清 logcat，方便只看这一轮的日志）
    adb("logcat", "-c")
    if not args.skip_launch:
        adb("shell", "am", "force-stop", PKG)
        time.sleep(1)
        adb("shell", "am", "start", "-n", "%s/.MainActivity" % PKG)
        time.sleep(6)

    # ---- 1. 首页内置会话 ----
    xml = dump_ui("home")
    visible = texts_in(xml)
    found = [t for t in STARTER_TITLES if t in visible]
    note("\n## 1. 首页内置会话")
    note("界面可见的文案（前 40 条）：\n%s" % "\n".join("  - %s" % v for v in visible[:40]))
    note("命中的内置会话标题（%d 条）：%s" % (len(found), "、".join(found)))
    note("有「换一换」按钮：%s" % ("换一换" in visible))
    note("小结：一次显示 %d 条（期望 6 条左右，且不应只有老的 4 条）" % len(found))

    # 点「换一换」→ 期望换一批（不是同样 4 条换顺序）
    shuffle = bounds_of(xml, "换一换")
    note("「换一换」坐标：%s" % (shuffle,))
    if shuffle:
        found2 = []
        for attempt in range(3):
            adb("shell", "input", "tap", str(shuffle[0]), str(shuffle[1]))
            time.sleep(2.5)
            found2 = [t for t in STARTER_TITLES if t in texts_in(dump_ui("home-after-shuffle%d" % attempt))]
            if set(found2) != set(found):
                note("第 %d 次点击生效" % (attempt + 1))
                break
            note("（第 %d 次点击没变化，重试 —— 大概率是点击被动画吃掉）" % (attempt + 1))
        same = set(found) == set(found2)
        note("换一换之后的标题（%d 条）：%s" % (len(found2), "、".join(found2)))
        changed = len(set(found) - set(found2))
        note("换一换前后是同一批吗：%s（期望 False）；这次换掉 %d 条（契约要求 ≥4）"
             % (same, changed))
    else:
        note("!! 找不到「换一换」按钮（可能软键盘挡住或界面没起来）")

    # ---- 2. 设置页：多厂家 + 轮换组 + Agnes 预设 ----
    # 设置页是长列表，「轮换组」「Agnes」在下面，所以要**分几次慢滑**再 dump，
    # 最后把几屏的文案并起来判断（不这么干会误判成"这些区块不存在"）。
    if "设置" in visible:
        b = bounds_of(xml, "设置")
        entered = False
        if b:
            # 点一次不一定进得去（上一次点击的动画/涟漪会吃掉这一下）——所以
            # **确认到达**再往下走，宁可重试也不要拿首页的文案当设置页结论
            # （我第一版就把首页副标题里的「Agnes…免费」误判成了设置页有 Agnes 卡）。
            for attempt in range(3):
                adb("shell", "input", "tap", str(b[0]), str(b[1]))
                time.sleep(3)
                probe = texts_in(dump_ui("settings-probe%d" % attempt))
                if any(k in probe for k in ("外观", "字号", "主题")):
                    entered = True
                    break
                note("（第 %d 次点「设置」没进去，重试）" % (attempt + 1))
        if entered:
            settings_texts = []
            # 8 次慢滑（每次 900px）：模型区很长（每个厂家一张卡 + 轮换组 + Agnes 预设），
            # 少滑几次会漏掉下半部分的区块，误判成"没做"。
            for step in range(8):
                v = texts_in(dump_ui("settings%d" % step))
                settings_texts.extend(v)
                adb("shell", "input", "swipe", "540", "1800", "540", "900", "600")
                time.sleep(2)
            keys = ["我的模型", "轮换组", "添加厂家", "添加模型", "Agnes", "免费", "platform.agnes-ai.cn"]
            note("\n## 2. 设置页（多厂家 / 轮换组 / Agnes 预设）")
            for key in keys:
                note("  含「%s」：%s" % (key, any(key in t for t in settings_texts)))
            note("设置页各屏可见文案（去重后，前 60 条）：\n%s"
                 % "\n".join("  - %s" % v for v in list(dict.fromkeys(settings_texts))[:60]))
    else:
        note("\n## 2. 设置页\n!! 首页里找不到「设置」Tab（底部导航文案变了？）")

    # ---- 4. HTML 产物：预览页是"渲染"还是"源码"（用户第 2 条）----
    # 做法：往工作区放一个自包含 HTML，然后进「资料库」点开它，看预览页工具栏里
    # 有没有「查看源码 / 浏览器打开」——那两个按钮只在 **HTML 渲染预览** 那条路上
    # （源码视图没有它们）。顺带确认 AppBar 上的「分享」（用户第 1 条）。
    note("\n## 4. HTML 产物的预览路径（渲染 vs 源码）")
    html_local = os.path.join(PULL_DIR, "demo.html")
    html_body = (
        "<!doctype html><html><head><meta charset='utf-8'>"
        "<title>0.09 HTML 预览验证</title></head><body>"
        "<h1>这是渲染出来的页面，不是源码</h1>"
        "<p style='color:#0a0'>如果你看到的是绿色文字，说明 WebView 真的渲染了。</p>"
        "<ul><li>要点一</li><li>要点二</li></ul></body></html>"
    )
    with open(html_local, "w", encoding="utf-8") as f:
        f.write(html_body)
    adb("push", html_local, "/data/local/tmp/demo.html")
    adb("shell", "run-as", PKG, "cp", "/data/local/tmp/demo.html", "files/workspaces/moni-ws/demo.html")
    note("已把自包含 HTML 放进工作区（files/workspaces/moni-ws/demo.html）")

    lib = bounds_of(xml, "资料库")
    if lib:
        for attempt in range(3):
            adb("shell", "input", "tap", str(lib[0]), str(lib[1]))
            time.sleep(3)
            lib_xml = dump_ui("library%d" % attempt)
            lib_texts = texts_in(lib_xml)
            if any("最近" in t or "资料" in t for t in lib_texts):
                break
        note("资料库可见文案：%s" % "、".join(lib_texts[:25]))
        if "demo.html" in lib_texts or any("demo" in t for t in lib_texts):
            hit = bounds_of(lib_xml, "demo")
            if hit:
                adb("shell", "input", "tap", str(hit[0]), str(hit[1]))
                time.sleep(4)
                prev = texts_in(dump_ui("preview"))
                note("预览页可见文案：%s" % "、".join(prev[:25]))
                note("  含「查看源码」（= 走的是 HTML 渲染预览）：%s"
                     % any("查看源码" in t for t in prev))
                note("  含「浏览器打开」：%s" % any("浏览器打开" in t for t in prev))
                note("  含「分享」（用户第 1 条）：%s" % any("分享" in t for t in prev))
        else:
            note("!! 资料库列表里没看到 demo.html（扫描没刷新或文件名被截断）")

    # ---- 3. logcat 关键自证 ----
    rc, logs = adb("logcat", "-d", "-v", "time")
    note("\n## 3. logcat 关键日志")
    for key, desc in EXPECTED_LOGS.items():
        hits = [l.strip() for l in logs.splitlines() if key in l]
        note("- %s（%s）：%d 条" % (key, desc, len(hits)))
        for h in hits[:4]:
            note("    %s" % h[:220])
    for key in ["[dsh-rotate] 代理已就绪", "[dsh-model] overlay", "[dsh-library]", "flutter-error"]:
        hits = [l.strip() for l in logs.splitlines() if key in l]
        note("- %s：%d 条%s" % (key, len(hits), ("\n" + "\n".join("    " + h[:220] for h in hits[:4])) if hits else ""))

    os.makedirs(os.path.dirname(LOG_OUT), exist_ok=True)
    text = "\n".join(out)
    with open(LOG_OUT, "w", encoding="utf-8") as f:
        f.write(text)
    for line in [l for l in text.splitlines() if l.isascii()][-30:]:
        print(line)
    print("\n[verify-009-ui] full log -> %s" % LOG_OUT.replace("\\", "/"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
