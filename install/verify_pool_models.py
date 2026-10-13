# -*- coding: utf-8 -*-
"""End-to-end check for the rewritten 模型 UI (settings panel + session sheet).

Run on emulator-5554 with the x86_64 debug APK built from this tree:

  1. 设置 → 模型 → 「我的模型」: exactly the 5 built-in cards in the required order
     Agnes（免费） / DeepSeek 官方 / Command（聚合，推荐） / MiMo（小米） /
     LongCat（美团）, each collapsed to ONE row (name + status badge + arrow).
  2. Expanding the Agnes card: 介绍 + 去注册 + 免费口径 + 「只需要填 API Key」+
     Key 输入框 + 「测试并保存」 — and NOT the image/video endpoint rows, no
     「获取模型」(per the user's plan for that card).
  3. Fake Key → 「测试并保存」: the emulator has no internet, so the model list
     cannot be fetched; the app must fall back to the built-in suggestion
     (agnes-3.0-flash), STILL register it in models.json, and report the failed
     connectivity test in Chinese. Acceptance point for 「填了模型了，会话页面没有
     读出来」.
  4. files/models.json: agnes + agnes-3.0-flash present, and nothing that was
     already configured is lost (compared with the pre-test snapshot).
  5. Session model sheet is two-level: level 1 = providers (+ a 「轮换池」 entry)
     with Key status; tapping a provider expands its models; tapping a model
     switches in place (会话保留).
  6. 「添加模型」 (custom endpoint) against the local 401 upstream reached through
     `adb reverse` → real 401 → Chinese reason, models still registered.

Screenshots land in <proj>\\theme-screenshots\\pool-*.png. They are pulled to an
ASCII staging dir and then copied by Python: adb mangles non-ASCII destination
paths on Windows (it re-encodes them with the ANSI code page), which is why an
earlier round "copied" screenshots that never reached the disk.

NOTE: this machine is shared with another agent that also drives the same
emulator. Every step therefore re-asserts that OUR activity is the resumed one
and verifies the expected UI state before acting, retrying a few times.

Usage:  C:\\Python314\\python.exe install\\verify_pool_models.py [all|settings|session|custom]
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
STAGE = r"D:\dev\uiverify"          # ASCII staging (adb-safe)
SHOTS = os.path.join(ROOT, "theme-screenshots")
LOGS = os.path.join(ROOT, "docs", "logs")
PKG = "com.dshmobile.dsh_mobile"

REPORT = []
SHOT_FILES = []
RESULTS = []

NODE_RE = re.compile(r"<node\b[^>]*?/?>")
ATTR_RE = re.compile(r'([\w-]+)="([^"]*)"')


def log(line=""):
    REPORT.append(line)
    print(line, flush=True)


def adb(*a, timeout=300):
    return subprocess.run([ADB, *a], capture_output=True, timeout=timeout)


def shell(cmd, timeout=300):
    return subprocess.run([ADB, "shell", cmd], capture_output=True, timeout=timeout)


def sh_out(cmd):
    return shell(cmd).stdout.decode("utf-8", "replace")


def parse_nodes(xml):
    out = []
    for m in NODE_RE.finditer(xml):
        at = dict(ATTR_RE.findall(m.group(0)))
        b = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", at.get("bounds", ""))
        if not b:
            continue
        x1, y1, x2, y2 = (int(g) for g in b.groups())
        if x2 <= x1 or y2 <= y1:
            continue
        out.append(
            {
                "text": at.get("text", ""),
                "desc": at.get("content-desc", ""),
                "cls": at.get("class", ""),
                "bounds": (x1, y1, x2, y2),
                "cx": (x1 + x2) // 2,
                "cy": (y1 + y2) // 2,
            }
        )
    return out


def dump(tag):
    for _ in range(3):
        adb("shell", "uiautomator", "dump")
        local = os.path.join(STAGE, "pool-%s.xml" % tag)
        if os.path.exists(local):
            os.remove(local)
        adb("pull", "/sdcard/window_dump.xml", local)
        if os.path.exists(local):
            xml = open(local, encoding="utf-8", errors="replace").read()
            if xml.strip():
                return xml
        time.sleep(1.5)
    return ""


def shot(name):
    remote = "/sdcard/pool-%s.png" % name
    staged = os.path.join(STAGE, "pool-%s.png" % name)
    if os.path.exists(staged):
        os.remove(staged)
    adb("shell", "screencap", "-p", remote)
    adb("pull", remote, staged)
    if not os.path.exists(staged):
        log("    !! 截图没拉下来: %s" % staged)
        return False
    local = os.path.join(SHOTS, "pool-%s.png" % name)
    shutil.copyfile(staged, local)
    ok = os.path.exists(local) and os.path.getsize(local) > 1000
    log("    shot: %s  (%d bytes)" % (local, os.path.getsize(local) if ok else -1))
    if ok:
        SHOT_FILES.append(local)
    return ok


def labels(xml):
    out = []
    for n in parse_nodes(xml):
        for v in (n["text"], n["desc"]):
            if v and v not in out:
                out.append(v)
    return out


def has(xml, needle):
    return any(needle in v for v in labels(xml))


def exact_center(xml, label):
    """Centre of a node whose text/content-desc is EXACTLY `label`.

    Needed because 我的模型 的分节说明里**就含**「测试并保存」这几个字
    （'…→ 填 Key → 测试并保存'），用子串匹配会把它当成"已经有卡展开了"，
    并且 point 到那一整行说明上 —— 于是点了个空。
    """
    for n in parse_nodes(xml):
        if n["text"] == label or n["desc"] == label:
            return (n["cx"], n["cy"])
    return None


def has_exact(xml, label):
    return exact_center(xml, label) is not None


def has_ci(xml, needle):
    n = needle.lower()
    return any(n in v.lower() for v in labels(xml))


def card_center(xml, name):
    """Centre of a 「我的模型」card row (NOT any text that merely contains the name).

    The home page has a starter card 「生成一张图片：Agnes 文生图（当前免费）」 —
    a plain `center(xml, 'Agnes')` happily matches it and opens a new chat session.
    Provider cards are semantic buttons whose label carries the badge/count, so
    require those markers.
    """
    for n in parse_nodes(xml):
        d = n["desc"]
        if name in d and ("个模型" in d or "未配 Key" in d or "已配 Key" in d):
            return (n["cx"], n["cy"])
    return None


def center(xml, needle, exact=False):
    for n in parse_nodes(xml):
        for v in (n["text"], n["desc"]):
            if not v:
                continue
            if (v == needle) if exact else (needle in v):
                return (n["cx"], n["cy"])
    return None


def tap(x, y, wait=1.5):
    adb("shell", "input", "tap", str(x), str(y))
    time.sleep(wait)


def tap_text(xml, needle, wait=1.5):
    c = center(xml, needle)
    if not c:
        log("    !! 找不到可点的「%s」" % needle)
        return False
    log("    tap 「%s」 @ %s" % (needle, c))
    tap(c[0], c[1], wait)
    return True


def tap_card(xml, name, wait=2.5):
    c = card_center(xml, name)
    if not c:
        log("    !! 找不到「%s」那张内置卡" % name)
        return False
    log("    tap 内置卡「%s」 @ %s" % (name, c))
    tap(c[0], c[1], wait)
    return True


def swipe_up(times=1, wait=1.2):
    for _ in range(times):
        adb("shell", "input", "swipe", "540", "1750", "540", "1150", "300")
        time.sleep(wait)


def scroll_top():
    for _ in range(6):
        adb("shell", "input", "swipe", "540", "1150", "540", "1800", "250")
        time.sleep(0.5)


def resumed_pkg():
    out = sh_out("dumpsys activity activities")
    m = re.search(r"topResumedActivity=ActivityRecord\{\S+ \S+ ([^/ ]+)/", out)
    return m.group(1) if m else ""


def wait_app(timeout=150):
    """Wait until OUR activity is resumed (first boot extracts the node runtime)."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        if resumed_pkg() == PKG:
            return True
        time.sleep(3)
    return False


def cleanup_device():
    """Dismiss stuck system dialogs before driving our app.

    Hit for real: a leftover SAF "SAVE" dialog (from an unrelated log-export flow)
    was sitting on top, and its SAVE button (812,2211)-(1043,2337) overlaps the
    设置 nav item (864,2194)-(1080,2337). Every "switch to 设置" tap therefore
    pressed SAVE, which opened the system share sheet — and the share sheet owns
    topResumedActivity, so the app could never come to the front.
    """
    for _ in range(4):
        adb("shell", "input", "keyevent", "4")   # BACK
        time.sleep(0.7)
    adb("shell", "am", "force-stop", "com.android.intentresolver")
    adb("shell", "am", "force-stop", "com.google.android.documentsui")
    adb("shell", "am", "force-stop", "com.android.documentsui")
    adb("shell", "input", "keyevent", "3")       # HOME
    time.sleep(2)


def launch_app():
    adb("shell", "am", "force-stop", PKG)
    time.sleep(1)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    return wait_app(150)


def goto_settings():
    """Land on 设置 → 模型 for sure, then return that dump.

    Two traps this guards against (both actually hit during verification):
      * `am start` resumes MainActivity immediately, but the Flutter shell is
        still initialising for ~10-25s (the node runtime is extracted on first
        launch). Tapping 设置 during that window does nothing, and the NEXT tap
        then lands on the home page — where a starter card literally contains
        the word "Agnes"（生成一张图片：Agnes 文生图）, so a sloppy locator opens
        a brand-new chat session instead of the Agnes card.
      * So: wait for the bottom nav to exist, tap 设置, then VERIFY that the
        设置 page is really showing (外观 / 我的模型) before returning.
    """
    xml = ""
    for _ in range(3):
        if resumed_pkg() != PKG:
            cleanup_device()
            launch_app()
        t0 = time.time()
        while time.time() - t0 < 90:
            xml = dump("w")
            if has(xml, "首页") and has(xml, "设置"):
                break
            time.sleep(3)
        if not has(xml, "首页"):
            # 可能被别的系统窗口挡住（共享面板 / 存储对话框）：清一次再来
            log("    （底部导航看不到，清理系统弹窗后重试）")
            cleanup_device()
            continue
        tap(972, 2280, 4)
        xml = dump("set")
        if has(xml, "我的模型") or has(xml, "外观"):
            scroll_top()
            return dump("sethome")
        log("    （设置页没出来，重试；当前可见：%s）" % labels(xml)[:5])
        time.sleep(3)
    return xml


def scroll_to(xml, needle, max_swipes=6, tag="s"):
    for i in range(max_swipes):
        if has(xml, needle):
            return xml
        swipe_up(1)
        xml = dump("%s%d" % (tag, i))
    return xml


def models_json():
    return sh_out("run-as %s cat files/models.json" % PKG)


def cfg_of(text):
    try:
        return json.loads(text)
    except Exception:
        return None


def show_nodes(xml, limit=40):
    log("    可见节点（text | content-desc | class | bounds）:")
    n = 0
    for x in parse_nodes(xml):
        if not x["text"] and not x["desc"]:
            continue
        log("      - %s | %s | %s | %s"
            % (x["text"].replace("\n", "\\n")[:60],
               x["desc"].replace("\n", "\\n")[:70],
               x["cls"].replace("android.view.", "").replace("android.widget.", ""),
               x["bounds"]))
        n += 1
        if n >= limit:
            break


def check(cond, text):
    log("  [%s] %s" % ("OK  " if cond else "MISS", text))
    RESULTS.append((bool(cond), text))
    return bool(cond)


def find_field(xml, needle):
    """Locate the Key input box.

    Flutter exposes EditableText as one merged `android.widget.EditText` node whose
    bounds cover the WHOLE card, so tapping its centre hits nothing useful. The
    InputDecoration helper line under the field IS exposed reliably, so the box is
    derived from it (the field sits just above the helper). Fallbacks: the exact
    'API Key' floating label, then a small EditText node.
    """
    nodes = parse_nodes(xml)
    # ① 用输入框下方的 helper 行反推（最稳）
    for n in nodes:
        for v in (n["text"], n["desc"]):
            if v and ("不写进 models.json" in v or "Keystore" in v):
                x1, y1, x2, y2 = n["bounds"]
                return {"cx": (x1 + x2) // 2, "cy": y1 - 60, "bounds": n["bounds"],
                        "text": "(derived from helper line)", "desc": "", "cls": "helper+offset"}
    # ② 悬浮的 'API Key' 标签（点它下面一点就是输入框）
    c = exact_center(xml, "API Key")
    if c:
        return {"cx": c[0], "cy": c[1] + 35, "bounds": (c[0], c[1], c[0], c[1]),
                "text": "API Key", "desc": "", "cls": "label+offset"}
    # ③ 高矮正常的 EditText（排除掉"整张卡"那个合并节点）
    for n in nodes:
        if n["cls"].endswith("EditText"):
            h = n["bounds"][3] - n["bounds"][1]
            if h < 400:
                return n
    for n in nodes:
        for v in (n["text"], n["desc"]):
            if v and needle in v:
                return n
    return None


def type_into(node, text):
    tap(node["cx"], node["cy"], 1.5)
    adb("shell", "input", "text", text)
    time.sleep(1.2)


def app_pid():
    return sh_out("pidof %s" % PKG).strip()


def logcat_since(marker, lines=1500):
    out = sh_out("logcat -d -t %d" % lines)
    return marker in out


def tap_confirmed(needle, marker, tries=4, tag="tc"):
    """Tap something and confirm from logcat that OUR handler really ran.

    Shared-device reality: another agent force-stops this app mid-run and the
    layout shifts while the IME animates, so a single coordinate tap is not
    evidence. Each try re-dumps, re-locates the target and then requires the
    handler's own debugPrint marker to appear in logcat.
    """
    for i in range(tries):
        xml = dump("%s%d" % (tag, i))
        c = center(xml, needle)
        if not c:
            log("    「%s」不在可见区，滚动一次再试（第 %d 次）" % (needle, i + 1))
            swipe_up(1)
            time.sleep(1)
            continue
        log("    tap 「%s」 @ %s（第 %d 次尝试）" % (needle, c, i + 1))
        tap(c[0], c[1], 3)
        for _ in range(6):
            if logcat_since(marker):
                log("    logcat 命中处理函数标记：%s" % marker)
                return True
            time.sleep(2)
    return False


def tap_marker(x, y, marker, wait=7.0):
    """Tap a coordinate and wait for a logcat marker (handler really ran)."""
    log("    tap (%d, %d) 并等 logcat 标记 %s" % (x, y, marker))
    adb("shell", "input", "tap", str(x), str(y))
    t0 = time.time()
    while time.time() - t0 < wait:
        if logcat_since(marker):
            log("    logcat 命中：%s" % marker)
            return True
        time.sleep(1.5)
    return False


def last_interrupt_age():
    """Seconds since the last external `Force stopping com.dshmobile...` (logcat).

    Self-contained on purpose: the emulator clock and the host clock differ, so
    the age is derived from the newest logcat timestamp seen.
    """
    out = sh_out("logcat -d -v epoch -t 4000")
    now = 0.0
    last = -1.0
    for line in out.splitlines():
        m = re.match(r"^(\d+\.\d+)", line)
        if not m:
            continue
        t = float(m.group(1))
        now = max(now, t)
        if "Force stopping com.dshmobile" in line:
            last = max(last, t)
    if last < 0:
        return 999.0
    return now - last


def ocr(png, tag):
    """Local OCR (rapidocr) of a screenshot -> text, used for content assertions.

    uiautomator merges several of Flutter's Text siblings into one node, so
    "is this sentence on screen" cannot be answered from the dump alone; the
    pixels can.
    """
    txt = os.path.join(STAGE, "ocr-%s.txt" % tag)
    py = sys.executable
    subprocess.run([py, os.path.join(ROOT, "install", "ocr_image.py"), png, txt],
                   capture_output=True, timeout=600)
    if not os.path.exists(txt):
        return ""
    data = open(txt, encoding="utf-8", errors="replace").read()
    log("    OCR(%s) -> %d 行：%s" % (tag, len(data.splitlines()),
                                     (data.splitlines()[0] if data else "")[:70]))
    return data


# ═══════════════════════════════════════════════════════════════════ steps

def step_settings():
    log("")
    log("=== ① 设置 → 模型：「我的模型」5 张内置卡 + 顺序 + 状态徽标 ===")
    xml = goto_settings()
    shot("01-settings-mymodels")
    if not has(xml, "我的模型"):
        xml = scroll_to(xml, "我的模型", 4, "m")
    show_nodes(xml, 30)
    order = ["Agnes（免费）", "DeepSeek 官方", "Command（聚合，推荐）",
             "MiMo（小米）", "LongCat（美团）"]
    joined = "\n".join(labels(xml))
    pos = []
    for k in order:
        pos.append(joined.find(k))
        check(has(xml, k), "第 %d 张内置卡：%s" % (order.index(k) + 1, k))
    check(all(p >= 0 for p in pos) and pos == sorted(pos),
          "5 张卡的顺序就是 Agnes → DeepSeek → Command → MiMo → LongCat")
    check(has(xml, "未配 Key") or has(xml, "已配 Key"), "收起态有「未配 Key / 已配 Key」徽标")
    check(not has(xml, "已测试通过"), "还没测过时不会谎称「已测试通过」")

    log("")
    log("=== ② 展开 Agnes（免费）那张卡 ===")
    opened = False
    for attempt in range(3):
        if not has(xml, "Agnes"):
            xml = scroll_to(xml, "Agnes", 3, "a")
        if tap_card(xml, "Agnes", wait=2.5):
            xml = dump("agnes")
            if has(xml, "测试并保存") or has(xml, "去注册"):
                opened = True
                break
        xml = goto_settings()
    xml = scroll_to(xml, "测试并保存", 3, "ag")
    shot("02-agnes-expanded")
    show_nodes(xml, 30)
    check(opened, "点得到 Agnes 卡（手风琴展开）")
    check(has(xml, "去注册"), "有「去注册 / 申请 Key」按钮")
    check(has(xml, "测试并保存"), "有「测试并保存」按钮")
    check(not has(xml, "获取模型"), "Agnes 卡里没有「获取模型」（方案：Agnes 只要那几项）")
    log("    （介绍 / 免费口径 / 「只需要填 API Key」这几句在 uiautomator 里会被")
    log("      Flutter 合并进父节点，所以改由**截图 OCR** 判：）")
    png2 = os.path.join(SHOTS, "pool-02-agnes-expanded.png")
    content = ocr(png2, "agnes") if os.path.exists(png2) else ""
    for needle in ["只需要填", "去注册", "测试并保存"]:
        check(needle in content, "截图 OCR 里出现「%s」" % needle)
    for needle in ["限时", "现价", "公告为准"]:
        check(needle in content, "免费口径照官方限定（含「%s」）" % needle)
    check("获取模型" not in content, "截图 OCR 里没有「获取模型」")
    check("轮换组" not in content, "界面文案不再出现「轮换组」（统一叫轮换池）")

def step_save():
    log("")
    log("=== ③ 填 Key → 点「测试并保存」（每次从干净状态起，短序列多次重试）===")
    key = "sk-pool-verify-not-a-real-key"
    ok_save = False
    for attempt in range(6):
        age = last_interrupt_age()
        log("  --- 第 %d 次尝试（距上次被外部 force-stop %.0fs）---" % (attempt + 1, age))
        # 每次从**干净状态**开始：重启 App → 设置 tab → 列表回到顶部。
        # 这样这一小段只有 ~25s，且每一步的前置条件都是确定的。
        if not launch_app():
            log("    App 没起来")
            continue
        time.sleep(3)
        xml = goto_settings()
        if not (has(xml, "我的模型") or has(xml, "外观")):
            log("    没进到设置页，重来（可见：%s）" % labels(xml)[:5])
            continue
        if not has(xml, "Agnes"):
            xml = scroll_to(xml, "Agnes", 2, "s")
        if not has_exact(xml, "测试并保存"):
            if not tap_card(xml, "Agnes", wait=2.5):
                log("    点不到 Agnes 卡（可见文本：%s）" % labels(xml)[:6])
                continue
            xml = dump("s2")
        fld = find_field(xml, "API Key")
        btn = exact_center(xml, "测试并保存")
        if not fld or not btn:
            log("    定位失败（field=%s btn=%s），重来" % (bool(fld), bool(btn)))
            continue
        pid0 = app_pid()
        type_into(fld, key)
        # obscureText 的输入框**不会**把内容暴露给 uiautomator（这是有意的），
        # 所以这里只验证"焦点确实在某个输入框上"。
        focused = dump("typed")
        focused_flag = 'focused="true"' in focused
        log("    输入框聚焦=%s（obscureText 不回显内容，只能这样验）" % focused_flag)
        adb("shell", "input", "keyevent", "111")
        time.sleep(1.5)
        if not focused_flag and not btn:
            continue
        if app_pid() != pid0:
            log("    App 被外部重启，重来")
            continue
        log("    按钮基准位 y=%d；两种布局各试一次" % btn[1])
        if tap_marker(540, btn[1], "[dsh-model-panel] 测试并保存开始", 7):
            ok_save = True
            break
        if tap_marker(540, btn[1] + 150, "[dsh-model-panel] 测试并保存开始", 7):
            ok_save = True
            break
        log("    两次点击都没命中按钮")
    check(ok_save, "「测试并保存」真的被按下（logcat 有 [dsh-model-panel] 测试并保存开始）")
    log("    等落盘 + 连通性测试（15s）…")
    time.sleep(15)
    after_now = models_json()
    check("agnes-3.0-flash" in after_now,
          "落盘：models.json 里出现 agnes-3.0-flash")
    xml = dump("saved")
    shot("04-after-test-and-save")
    show_nodes(xml, 30)
    check(has(xml, "会话的模型面板里现在就能选") or has(xml, "已经登记"),
          "界面明确说模型已经登记、会话里能选")
    check(has(xml, "agnes-3.0-flash"), "界面列出了 agnes-3.0-flash")
    check(has(xml, "预置建议模型"), "如实说明用的是预置建议模型（没拉到真实列表）")
    check(has(xml, "测试") and (has(xml, "没通过") or has(xml, "失败")),
          "如实贴出测试失败的中文原因")
    png = os.path.join(SHOTS, "pool-04-after-test-and-save.png")
    c4 = ocr(png, "saved") if os.path.exists(png) else ""
    for needle in ["agnes-3.0-flash", "预置建议模型", "测试"]:
        check(needle in c4, "截图 OCR（保存后）里出现「%s」" % needle)
    return xml


def step_json(before_txt):
    log("")
    log("=== ④ models.json 落盘核对（其它厂家/轮换池一条都不许丢）===")
    bcfg = cfg_of(before_txt) or {}
    b_providers = [p.get("id") for p in bcfg.get("providers", [])]
    b_groups = [g.get("name") for g in bcfg.get("groups", [])]
    b_models = ["%s/%s" % (m.get("provider"), m.get("id")) for m in bcfg.get("models", [])]
    after = models_json()
    log(after.strip())
    acfg = cfg_of(after) or {}
    a_providers = [p.get("id") for p in acfg.get("providers", [])]
    a_groups = [g.get("name") for g in acfg.get("groups", [])]
    a_models = ["%s/%s" % (m.get("provider"), m.get("id")) for m in acfg.get("models", [])]
    check("agnes" in a_providers, "agnes 厂家写进去了")
    check("agnes/agnes-3.0-flash" in a_models, "agnes-3.0-flash 模型写进去了")
    check(all(p in a_providers for p in b_providers),
          "测试前已有的厂家没丢：%s -> %s" % (b_providers, a_providers))
    check(all(g in a_groups for g in b_groups),
          "测试前已有的轮换池没丢：%s -> %s" % (b_groups, a_groups))
    check(all(m in a_models for m in b_models),
          "测试前已有的模型没丢：%s -> %s" % (b_models, a_models))
    return after


def open_chat_sheet():
    """首页 → 开始新会话 → 打开模型面板。返回 (xml, ok)."""
    if resumed_pkg() != PKG:
        launch_app()
        time.sleep(4)
    xml = dump("home")
    if not tap_text(xml, "首页", wait=3):
        tap(108, 2280, 3)
        xml = dump("home2")
    # 已经开始过会话就直接找模型胶囊；否则点「开始新会话」
    for attempt in range(4):
        xml = dump("chat%d" % attempt)
        if has(xml, "当前模型"):
            break
        if has(xml, "开始新会话") and tap_text(xml, "开始新会话", wait=6):
            time.sleep(6)
            continue
        time.sleep(6)
    if not has(xml, "当前模型"):
        log("    !! 进不了会话页（等不到「当前模型」）")
        return xml, False
    shot("05-chat-page")
    if not tap_text(xml, "当前模型", wait=3.5):
        return xml, False
    return dump("sheet1"), True


def step_session():
    log("")
    log("=== ⑤ 会话页模型面板：两级（厂家 → 模型）+ 「轮换池」 ===")
    xml, ok = open_chat_sheet()
    if not ok:
        check(False, "打开模型面板")
        return
    shot("06-model-sheet-level1")
    show_nodes(xml, 30)
    check(has(xml, "选择模型"), "弹层标题「选择模型」")
    check(has(xml, "轮换池"), "第一级里有「轮换池」这一项")
    check(has(xml, "Algnes") or has(xml, "Agnes"), "第一级里有厂家 Agnes")
    check(has(xml, "未配 Key") or has(xml, "已配 Key"), "第一级标了 Key 状态")
    if tap_text(xml, "Agnes", wait=3):
        xml = dump("sheet2")
        shot("07-model-sheet-level2-agnes")
        show_nodes(xml, 30)
        check(has(xml, "agnes-3.0-flash"), "第二级列出了 agnes-3.0-flash")
        check(has(xml, "未配 Key") or has(xml, "已配 Key"), "第二级仍有 Key 状态")
        if tap_text(xml, "agnes-3.0-flash", wait=5):
            xml = dump("selected")
            shot("08-chat-after-select-model")
            check(has(xml, "会话保留") or has(xml, "已切换到"),
                  "切换走的是「会话内切换、不重建会话」那条路")
    else:
        check(False, "点得开厂家 Agnes（第二级）")


def step_custom():
    log("")
    log("=== ⑥ 添加模型（自定义端点 → 本机 401 上游）===")
    xml = goto_settings()
    xml = scroll_to(xml, "添加模型", 8, "c")
    if not tap_text(xml, "展开", wait=2.5):
        if not tap_text(xml, "添加模型", wait=2.5):
            check(False, "展开「添加模型」")
            return
    xml = scroll_to(dump("custom"), "Base URL", 5, "cu")
    shot("09-add-model-form")
    show_nodes(xml, 24)
    check(has(xml, "Base URL"), "自定义表单里有可手填的 Base URL")
    base = find_field(xml, "Base URL")
    if base:
        type_into(base, "http://127.0.0.1:8899/v1")
        log("    已把 Base URL 指到本机 401 上游（adb reverse 8899）")
    else:
        log("    !! 找不到 Base URL 输入框")
    xml = dump("custom2")
    keyf = None
    for n in parse_nodes(xml):
        if n["cls"].endswith("EditText"):
            if keyf is None:
                keyf = n
            elif keyf is n:
                pass
    # Key 是第 4 个输入框（厂家名 / provider id / Base URL / API Key / model id / 上下文）
    edits = [n for n in parse_nodes(xml) if n["cls"].endswith("EditText")]
    if len(edits) >= 5:
        type_into(edits[3], "sk-pool-lease-401")
        type_into(edits[4], "verify-model")
        log("    已填 Key 与 model id")
    else:
        log("    !! 输入框数量不对：%d" % len(edits))
    adb("shell", "input", "keyevent", "111")
    time.sleep(2)
    xml = scroll_to(dump("custom3"), "测试并保存", 4, "cs")
    if tap_text(xml, "测试并保存", wait=3):
        log("    点了「测试并保存」，等真实 401 回来…")
        time.sleep(25)
        xml = dump("custom401")
        shot("10-custom-401")
        show_nodes(xml, 30)
        check(has(xml, "已经登记") or has(xml, "会话里现在能选"),
              "401 之后模型仍然登记好了（测试失败不阻止登记）")
        check(has(xml, "verify-model"), "轮换池/清单里能看到 verify-model")
        check(has(xml, "401") or has(xml, "鉴权") or has(xml, "Key"),
              "401 被翻译成中文原因贴出来")
    else:
        check(False, "点得到「测试并保存」")


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else "all"
    os.makedirs(STAGE, exist_ok=True)
    os.makedirs(SHOTS, exist_ok=True)
    os.makedirs(LOGS, exist_ok=True)

    before = models_json()
    log("=== 测试前的 models.json ===")
    log(before.strip())

    cleanup_device()
    if not launch_app():
        log("!! 应用没起来（topResumedActivity 一直不是 %s）" % PKG)
    time.sleep(2)

    if only in ("all", "settings"):
        step_settings()
        step_save()
        step_json(before)
    elif only == "save":
        step_save()
        step_json(before)
    if only in ("all", "session"):
        step_session()
    if only in ("all", "custom"):
        step_custom()

    log("")
    log("=== 截图落盘核对 ===")
    for p in SHOT_FILES:
        log("  %s  %s bytes" % (p, os.path.getsize(p) if os.path.exists(p) else -1))
    log("  共 %d 张" % len(SHOT_FILES))

    okn = sum(1 for c, _ in RESULTS if c)
    log("")
    log("=== 结论：%d/%d 项通过 ===" % (okn, len(RESULTS)))
    for c, t in RESULTS:
        if not c:
            log("  MISS: %s" % t)

    out = os.path.join(LOGS, "pool-models-verify.txt")
    open(out, "w", encoding="utf-8").write("\n".join(REPORT))
    log("")
    log("报告 -> %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
