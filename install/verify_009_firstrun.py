#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
0.09 验证：用户第 4 条（首次安装没配模型时的引导）。

做法（**只在模拟器上，动的是模拟器自己的配置**）：
  1. 备份模拟器上 App 的三样东西：`files/models.json`、`files/dshhome/model.overlay.yml`、
     `shared_prefs/`（flutter_secure_storage 那把 Key / model id 在里面）；
  2. 全部挪走 → 重启 App → 此时 `ModelStore.hasModels == false`；
  3. 断言：首页出现「还没有可用模型」的常驻提示；点「开始新会话」弹出说明层，
     里面有「去设置」；点它应切到「设置」Tab（这就是用户要的"明确指路"）；
  4. **恢复**备份并重启，断言模型清单回来了（App 回到可用状态）。

结论写 <repo>/docs/logs/verify-009-firstrun.txt（UTF-8）；控制台只打 ASCII 摘要。
"""
import os
import re
import subprocess
import sys
import time

REPO = r"D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile"
PKG = "com.dshmobile.dsh_mobile"
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
LOG_OUT = os.path.join(REPO, "docs", "logs", "verify-009-firstrun.txt")
STAGE = r"D:\dev\uiverify\v009\firstrun"          # adb push/pull 只认 ASCII 路径
DEVICE_TMP = "/data/local/tmp/firstrun"
FD = "/data/user/0/%s/files" % PKG


def run(args, timeout=300):
    p = subprocess.run(args, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")


def adb(*args, **kw):
    return run([ADB, *args], **kw)


def sh(cmd):
    return adb("shell", cmd)


def run_as(*args):
    return adb("shell", "run-as", PKG, *args)


def dump(tag, attempts=8):
    os.makedirs(STAGE, exist_ok=True)
    local = os.path.join(STAGE, "dump-%s.xml" % tag)
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
                text = f.read()
            if re.search(r'text="[^"]+"|content-desc="[^"]+"', text):
                return text
        except Exception:
            pass
        time.sleep(2)
    return ""


def texts(xml):
    raw = re.findall(r'content-desc="([^"]*)"', xml) + re.findall(r'text="([^"]*)"', xml)
    out = []
    for item in raw:
        for piece in re.split(r"&#10;|\n", item):
            piece = piece.strip()
            if piece and piece not in out:
                out.append(piece)
    return out


def tap_text(xml, needle):
    for m in re.finditer(
        r'<node[^>]*?(?:content-desc|text)="[^"]*%s[^"]*"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"' % re.escape(needle),
        xml,
    ):
        seg = xml[m.start():m.end()]
        x1, y1, x2, y2 = (int(m.group(i)) for i in range(1, 5))
        if 'clickable="true"' in seg:
            adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
            return True
    return False


def main():
    out = []
    def note(line=""):
        out.append(line)

    note("# 0.09 验证：首启（没有模型）引导 —— 用户第 4 条")
    note("时间: %s" % time.strftime("%Y-%m-%d %H:%M:%S"))

    os.makedirs(STAGE, exist_ok=True)
    # ⚠️ 备份**必须放在 App 自己的数据目录里**：/data/local/tmp 虽然能 traverse，
    # 但 App 这个 UID **不能在里建文件**（第一版就是把 mv 的目标写在 /local/tmp，
    # 结果 mv 静默失败、配置根本没挪走，测出来的"首页没有引导"是假的）。
    BAK = FD + "/_bak_firstrun"
    run_as("rm", "-rf", BAK)
    run_as("mkdir", "-p", BAK)

    # ---- 1. 备份 ----
    note("\n## 1. 备份（放在 App 私有目录内的 %s）" % BAK)
    for src, name in ((FD + "/models.json", "models.json"),
                      (FD + "/dshhome/model.overlay.yml", "model.overlay.yml")):
        rc, o = run_as("cp", src, "%s/%s" % (BAK, name))
        note("  cp %s -> %s : rc=%s %s" % (src, name, rc, o.strip()[:80]))
    rc, o = run_as("cp", "-r", FD + "/../shared_prefs", "%s/shared_prefs" % BAK)
    note("  cp shared_prefs : rc=%s %s" % (rc, o.strip()[:80]))
    rc, o = run_as("ls", "-l", BAK)
    note("  备份目录内容：\n%s" % o.strip())

    # ---- 2. 挪走配置 → 变成"全新安装"的样子 ----
    note("\n## 2. 挪走配置（模拟首次安装）")
    for src, dst in ((FD + "/models.json", BAK + "/models.json.moved"),
                     (FD + "/dshhome/model.overlay.yml", BAK + "/overlay.moved"),
                     (FD + "/../shared_prefs", BAK + "/shared_prefs.moved")):
        rc, o = run_as("mv", src, dst)
        note("  mv %s : rc=%s %s" % (src, rc, o.strip()[:80]))
    # 逐个确认真的不在了（用 ls，参数分开传 —— 不要再走 `sh -c`，adb 会把引号吃掉）
    for p in (FD + "/models.json", FD + "/dshhome/model.overlay.yml",
              FD + "/../shared_prefs"):
        rc, o = run_as("ls", "-d", p)
        gone = "No such file" in o or rc != 0
        note("  %s → %s" % (p, "已挪走 ✅" if gone else "还在 ❌ " + o.strip()[:60]))

    # ---- 3. 冷启动，看首页引导 ----
    adb("logcat", "-c")
    sh("am force-stop %s" % PKG)
    time.sleep(2)
    sh("am start -n %s/.MainActivity" % PKG)
    time.sleep(14)
    home = dump("home-nomodel")
    ht = texts(home)
    note("\n## 3. 首页（没有模型时）")
    note("可见文案：\n%s" % "\n".join("  - %s" % t for t in ht[:40]))
    need_notice = [t for t in ht if "还没有可用模型" in t or "去设置" in t]
    note("命中的提示文案：%s" % ("、".join(need_notice) if need_notice else "（无）"))

    # 点「开始新会话」→ 应弹说明层
    note("\n## 4. 点「开始新会话」")
    if tap_text(home, "开始新会话"):
        time.sleep(3)
        dlg = dump("dialog")
        dt = texts(dlg)
        note("弹层文案：\n%s" % "\n".join("  - %s" % t for t in dt[:30]))
        has_guide = any(("去设置" in t) or ("配置模型" in t) or ("模型" in t and "设置" in t) for t in dt)
        note("弹层里有没有明确指路（去设置 / 配置模型）：%s" % has_guide)
        if tap_text(dlg, "去设置"):
            time.sleep(3)
            st = texts(dump("after-goto-settings"))
            note("点「去设置」之后的界面文案：\n%s" % "\n".join("  - %s" % t for t in st[:20]))
            note("是否到了设置页（含「外观/字号/主题」）：%s"
                 % any(t in ("外观", "字号", "主题") for t in st))
        else:
            note("!! 弹层里没找到可点的「去设置」")
    else:
        note("!! 首页没找到可点的「开始新会话」")

    # ---- 5. 恢复 ----
    note("\n## 5. 恢复备份")
    for dst, src in ((FD + "/models.json", BAK + "/models.json.moved"),
                     (FD + "/dshhome/model.overlay.yml", BAK + "/overlay.moved"),
                     (FD + "/../shared_prefs", BAK + "/shared_prefs.moved")):
        rc, o = run_as("mv", src, dst)
        note("  mv %s -> %s : rc=%s %s" % (src, dst, rc, o.strip()[:60]))
    for p in (FD + "/models.json", FD + "/dshhome/model.overlay.yml",
              FD + "/../shared_prefs"):
        rc, o = run_as("ls", "-d", p)
        note("  %s → %s" % (p, "已恢复 ✅" if rc == 0 else "缺失 ❌ " + o.strip()[:60]))
    run_as("rm", "-rf", BAK)
    adb("logcat", "-c")
    sh("am force-stop %s" % PKG)
    time.sleep(2)
    sh("am start -n %s/.MainActivity" % PKG)
    time.sleep(16)
    logs = adb("logcat", "-d", "-v", "time")[1]
    for key in ["dsh-model] 清单载入", "dsh-rotate] 代理已就绪", "dsh-skills] 内置技能"]:
        hits = [l.strip() for l in logs.splitlines() if key in l]
        note("- %s：%s" % (key, hits[-1][:160] if hits else "（无）"))

    os.makedirs(os.path.dirname(LOG_OUT), exist_ok=True)
    text = "\n".join(out)
    with open(LOG_OUT, "w", encoding="utf-8") as f:
        f.write(text)
    for line in [l for l in text.splitlines() if l.isascii()][-25:]:
        print(line)
    print("\n[verify-firstrun] full log -> %s" % LOG_OUT.replace("\\", "/"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
