# -*- coding: utf-8 -*-
"""全面测试第一步：把所有"真源状态文件"抓出来，用于核对功能间的逻辑关系。

用户要"全面测试，最主要看逻辑关系"——逻辑关系 = 各功能共享的数据是否一致。
这些文件就是真源：

  1. files/models.json              配置的模型清单（会话页模型面板读它）
  2. files/dshhome/model.overlay.yml 模型路由 + 沙箱模式（DSH 真正读它）
  3. files/dshhome/experts.json      专家开关状态
  4. files/dshhome/AGENTS.md         已开专家的 brief（DSH 每会话都读它）
  5. files/workspaces.json           工作区登记表（current = 当前工作区）
  6. files/workspaces/<name>/        工作区里的产物文件（资料库扫这里）
  7. files/dshhome/sessions/         会话历史
  8. files/schedules.json            定时任务

用法：C:\\Python314\\python.exe install\\test_collect_state.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADB = r"D:\dev\android-sdk\platform-tools\adb.exe"
LOGS = os.path.join(ROOT, "docs", "logs")
PKG = "com.dshmobile.dsh_mobile"


def adb(*a, timeout=180):
    r = subprocess.run([ADB, *a], capture_output=True, timeout=timeout)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def runas(*a):
    return adb("shell", "run-as", PKG, *a)


def main():
    os.makedirs(LOGS, exist_ok=True)
    rep = []
    sec = lambda t: rep.extend(["", "=" * 72, "## " + t, "=" * 72])

    sec("1) models.json —— 配置的模型清单（会话页模型面板的真源）")
    rep.append(runas("cat", "files/models.json"))

    sec("2) model.overlay.yml —— DSH 真正读的路由 + 沙箱")
    ov = runas("cat", "files/dshhome/model.overlay.yml")
    rep.append(ov)
    rep.append("--- 关键字段抽取 ---")
    for line in ov.splitlines():
        s = line.strip()
        if any(k in s for k in ["provider:", "model:", "mode:", "baseURL:", "- id:", "name:"]):
            rep.append("  " + s)

    sec("3) experts.json —— 专家开关状态")
    rep.append(runas("cat", "files/dshhome/experts.json"))

    sec("4) AGENTS.md —— 已开专家的 brief（每会话都注入）")
    rep.append(runas("cat", "files/dshhome/AGENTS.md"))

    sec("5) workspaces.json —— 工作区登记表")
    rep.append(runas("cat", "files/workspaces.json"))

    sec("6) 工作区目录内容（资料库扫这里）")
    rep.append(runas("ls", "-la", "files/workspaces/moni-ws"))

    sec("7) 会话历史目录")
    rep.append(runas("ls", "-la", "files/dshhome/sessions"))
    rep.append("--- 每个会话目录 ---")
    rep.append(runas("ls", "-R", "files/dshhome/sessions"))

    sec("8) schedules.json —— 定时任务")
    rep.append(runas("cat", "files/schedules.json"))

    sec("9) skills 目录")
    rep.append(runas("ls", "-la", "files/dshhome/skills"))

    sec("10) logcat 里的链路证据（cwd / 扫描目录 / 模型）")
    log = adb("logcat", "-d", timeout=240)
    for line in log.splitlines():
        s = line.strip()
        if any(k in s for k in ["[dsh-library]", "[dsh-ws]", "[dsh-nav] open chat", "ACP session ready"]):
            rep.append("  " + s[:200])

    out = os.path.join(LOGS, "test-state-collect.txt")
    open(out, "w", encoding="utf-8").write("\n".join(rep))
    print("report -> %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
