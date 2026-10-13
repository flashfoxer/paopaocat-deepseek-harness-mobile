# -*- coding: utf-8 -*-
"""复现并验证用户报的现象：
  「设置好模型后，会话里仍显示未配置模型；只有退出重进才看得见」

复现路径（严格照用户操作）：
  1. 删掉 models.json → 让内存里的 ModelStore 从"空"开始
  2. 启动 App
  3. 设置 → 修改配置 → 测试并保存（会写 models.json）
  4. **不重启**，直接去首页开会话 → 应该能看见模型

修复前：第 4 步显示「未配置模型」；修复后：显示模型名。

用法：C:\\Python314\\python.exe install\\verify_model_propagation.py
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
    return subprocess.run([ADB, *a], capture_output=True, timeout=timeout)


def runas(*a):
    return adb("shell", "run-as", PKG, *a).stdout.decode("utf-8", "replace")


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


def main():
    os.makedirs(STAGE, exist_ok=True)
    rep = []

    rep.append("=== 0) 清空 models.json（让内存从空开始）===")
    runas("rm", "files/models.json")
    rep.append("  models.json 存在? " + ("是" if "models.json" in runas("ls", "files") else "否"))

    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", PKG + "/.MainActivity")
    time.sleep(28)

    # 设置 → 修改配置 → 测试并保存
    tap(972, 2280)
    time.sleep(6)
    xml = dump("p-settings")
    btn = center(xml, "修改配置")
    rep.append("")
    rep.append("=== 1) 设置页（应处于收起态，有「修改配置」）===")
    rep.append("  修改配置 @ %s" % (btn,))
    if not btn:
        rep.append("  [MISS] 没找到修改配置（可见：%s）" % " | ".join(labels(xml)[:8]))
        found_cfg = False
    else:
        found_cfg = True
        tap(btn[0], btn[1])
        time.sleep(3)
        for _ in range(4):
            adb("shell", "input", "swipe", "540", "1600", "540", "1200", "700")
            time.sleep(1)
        xml2 = dump("p-expanded")
        save = center(xml2, "测试并保存")
        rep.append("  测试并保存 @ %s" % (save,))
        if not save:
            rep.append("  [MISS] 没找到测试并保存（可见：%s）" % " | ".join(labels(xml2)[:10]))
            found_cfg = False
        else:
            tap(save[0], save[1])
            rep.append("  已点击「测试并保存」，等待真实连通性测试…")
            ok = False
            for i in range(15):
                time.sleep(4)
                j = "\n".join(labels(dump("p-wait")))
                if "该模型已就绪" in j:
                    ok = True
                    rep.append("  [OK] 连通性测试通过（第 %d 次轮询）" % (i + 1))
                    break
                if "连通性测试没通过" in j:
                    rep.append("  [FAIL] 测试没通过（Key/端点问题，不是本轮要验的）")
                    break
            if not ok:
                rep.append("  等待超时，继续后续检查")

    # 不重启，直接去会话
    tap(108, 2280)   # 首页
    time.sleep(3)
    xml3 = dump("p-home")
    c = center(xml3, "开始新会话")
    rep.append("")
    rep.append("=== 2) 不重启，直接开会话 ===")
    if not c:
        rep.append("  [MISS] 没找到开始新会话")
    else:
        tap(c[0], c[1])
        time.sleep(25)
        xml4 = dump("p-chat")
        labs = labels(xml4)
        j = "\n".join(labs)
        rep.append("  会话页可见: " + " | ".join(v.replace("\n", " / ")[:45] for v in labs[:12]))
        no_cfg = "未配置模型" in j
        has_model = ("deepseek" in j) or ("v4.1" in j) or ("commandcode" in j)
        rep.append("")
        rep.append("  [%s] 会话页**不再**显示「未配置模型」" % ("OK" if not no_cfg else "MISS"))
        rep.append("  [%s] 会话页显示了模型名" % ("OK" if has_model else "MISS"))

    # 关键日志
    log = adb("logcat", "-d", timeout=240).stdout.decode("utf-8", "replace")
    rep.append("")
    rep.append("=== 3) 关键日志（清单重读 / 落盘）===")
    n = 0
    for l in log.splitlines():
        if "[dsh-model] 清单载入" in l or "已落盘" in l or "已写入配置" in l:
            n += 1
            rep.append("  " + l.strip()[-150:])
    if n == 0:
        rep.append("  (无)")

    out = os.path.join(LOGS, "verify-model-propagation.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    for line in rep:
        s = line.strip()
        if s.startswith("[") or s.startswith("==="):
            print("  " + s.encode("ascii", "replace").decode("ascii")[:92])
    return 0


if __name__ == "__main__":
    sys.exit(main())
