#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
0.09 端到端验证（在 Android 设备/模拟器上跑，通过 adb）。

验的是这一版新增的四条链路（都是**真机行为**，不是读代码）：
  1. 随包工具箱是否落到 App 私有目录（shims/android-exec-shim.cjs、toolbox/make-pptx.mjs、toolbox/rotate-proxy.mjs）
  2. 「执行环境 shim」是否真的让 `bash -c ...` 跑起来、并且 shell 里能调 `node`
     （Android 上没有 bash，DST 的 bash 工具写死 spawn "bash"）
  3. 不做模型调用也能验的：用 shim 跑 `bash -c 'node make-pptx.mjs ...'` 生成真 .pptx，并检查它是个合法 ZIP
  4. overlay 是否是「多厂家 + rotate + sandbox」的新形状

可选（--with-model）：再用 headless profile 真跑一次模型任务，验证模型真的能用 bash 工具
生成 pptx（需要设备上有可用凭据，凭据来自 files/dev-api-key.txt）。

用法：
  python verify_009_headless.py            # 只跑不花钱的检查
  python verify_009_headless.py --with-model

结论写到 <repo>/docs/logs/verify-009-headless.txt（UTF-8）；控制台只打 ASCII 摘要。
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
LOG_OUT = os.path.join(REPO, "docs", "logs", "verify-009-headless.txt")
DEVICE_SCRIPT = "/data/local/tmp/v009.sh"


def run(args, timeout=600, binary=False):
    p = subprocess.run(args, capture_output=True, timeout=timeout)
    if binary:
        return p.returncode, p.stdout
    return p.returncode, p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")


def adb(*args, **kw):
    return run([ADB, *args], **kw)


def adb_shell(cmd, timeout=600):
    return adb("shell", cmd, timeout=timeout)


def adb_run_as(cmd, timeout=600):
    return adb("shell", "run-as", PKG, *cmd.split(), timeout=timeout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--with-model", action="store_true")
    args = ap.parse_args()

    out = []

    def note(line=""):
        out.append(line)

    note("# 0.09 端到端验证（设备侧）")
    note("时间: %s" % time.strftime("%Y-%m-%d %H:%M:%S"))

    rc, devices = adb("devices")
    note("\n## 设备\n%s" % devices.strip())

    rc, dumpsys = adb_shell("dumpsys package %s" % PKG)
    native = None
    abi = None
    for line in dumpsys.splitlines():
        m = re.search(r"legacyNativeLibraryDir=(\S+)", line)
        if m:
            native = m.group(1)
        m = re.search(r"primaryCpuAbi=(\S+)", line)
        if m:
            abi = m.group(1)
    note("\n## 路径\nnativeLibDir=%s\ncpuAbi=%s" % (native, abi))
    if not native:
        note("!! 找不到 nativeLibraryDir，后面没法跑")
        finish(out)
        return 1

    files_dir = "/data/user/0/%s/files" % PKG
    # ⚠️ legacyNativeLibraryDir 是 `.../lib`，真正的 .so（libnode.so 及其依赖
    # libz1.so / libssl3.so …）在**它的 ABI 子目录**里。LD_LIBRARY_PATH 必须指向
    # 那个子目录，否则会报 `CANNOT LINK EXECUTABLE ... library "libz1.so" not found`
    # （第一版就踩了这个坑）。
    native_abi = "%s/%s" % (native, abi)
    node = "%s/libnode.so" % native_abi
    fs_shim = "%s/shims/android-fs-shim.cjs" % files_dir
    exec_shim = "%s/shims/android-exec-shim.cjs" % files_dir
    toolbox = "%s/toolbox" % files_dir
    dsh_home = "%s/dshhome" % files_dir
    dsh_bin = "%s/dsh/lib/bin.js" % files_dir

    task = (
        "请用 bash 工具做两件事，并把每一步的真实输出贴出来：\n"
        "1) 运行 `echo SHELL_OK` 与 `node --version`；\n"
        "2) 用随包脚本生成一个真的 .pptx：\n"
        "   先把这份大纲写到文件 outline.json："
        '{"title":"执行环境验证","slides":[{"title":"第一条","bullets":["bash 能跑","node 能跑"]}]}\n'
        "   然后运行 `node \"$DSH_ANDROID_TOOLBOX/make-pptx.mjs\" outline.json verify.pptx`，\n"
        "   最后用 `ls -l verify.pptx` 确认文件存在并把体积报出来。\n"
        "不要用 HTML 顶替 pptx。"
    ).replace('"', '\\"')

    model_block = ""
    if args.with_model:
        model_block = r'''
echo "== 4. 模型端到端（headless，真调模型）=="
KEY=$(cat $FD/dev-api-key.txt 2>/dev/null)
WS=$(ls -d $FD/workspaces/* 2>/dev/null | head -1)
[ -z "$WS" ] && WS=$FD/workspace
mkdir -p $FD/v009 && cd $FD/v009
COM_API_KEY="$KEY" DEEPSEEK_API_KEY="$KEY" OPENAI_API_KEY="$KEY" ROTATE_API_KEY=local-rotate \
LD_LIBRARY_PATH=$NATIVE DSH_HOME=$DH HOME=$FD PATH=/system/bin:/system/xbin \
TMPDIR=$FD/tmp \
DSH_ANDROID_NODE_BIN=$NODE DSH_ANDROID_FS_SHIM=$FS DSH_ANDROID_EXEC_SHIM=$EXEC \
DSH_ANDROID_TOOLBOX=$TB DSH_ANDROID_TMPDIR=$FD/tmp \
$NODE --expose-internals --require $FS --require $EXEC $DSHBIN \
  --profile headless --patch $DH/model.overlay.yml "$TASK" 2>&1 | tail -60
echo "---- 产物 ----"
ls -l $FD/v009 2>&1
'''

    device_sh = r'''#!/system/bin/sh
FD=__FD__
DH=__DH__
NATIVE=__NATIVE__
NODE=__NODE__
FS=__FS__
EXEC=__EXEC__
TB=__TB__
DSHBIN=__DSHBIN__
TASK="__TASK__"

echo "== 1. 工具箱 / shim 是否落盘 =="
ls -l $TB 2>&1
ls -l $FD/shims 2>&1

echo
echo "== 1b. 内置技能（<DSH_HOME>/skills）=="
ls -1 $DH/skills 2>&1 | head -20
echo "SKILL.md 数量: $(ls $DH/skills/*/SKILL.md 2>/dev/null | wc -l)"

echo
echo "== 1c. AGENTS.md 受管区块（执行环境 + 生图/生视频规则）=="
echo "DSH_ANDROID_TOOLBOX 出现次数: $(grep -c DSH_ANDROID_TOOLBOX $DH/AGENTS.md 2>/dev/null)"
echo "make-video.mjs 出现次数: $(grep -c make-video.mjs $DH/AGENTS.md 2>/dev/null)"
echo "平台注册地址出现次数: $(grep -c platform.agnes-ai.cn $DH/AGENTS.md 2>/dev/null)"

echo
echo "== 2. overlay 原文（不在设备侧解析：toybox 的 grep 在这个 ERE 上会 segfault，实测过）=="
cat $DH/model.overlay.yml 2>&1

echo
echo "== 3. 执行环境 shim：bash -c / node / make-pptx（不调模型）=="
mkdir -p $FD/v009 && cd $FD/v009
export LD_LIBRARY_PATH=$NATIVE
export DSH_ANDROID_NODE_BIN=$NODE
export DSH_ANDROID_FS_SHIM=$FS
export DSH_ANDROID_EXEC_SHIM=$EXEC
export DSH_ANDROID_TOOLBOX=$TB
export DSH_ANDROID_TMPDIR=$FD/tmp
export PATH=/system/bin:/system/xbin
$NODE --expose-internals --require $FS --require $EXEC -e '
const cp = require("child_process");
const cmd = [
  "echo BASH_OK",
  "node --version",
  "cat > outline.json <<EOF",
  JSON.stringify({title:"shim 验证",slides:[{title:"一",bullets:["bash 能跑","node 能跑"]}]}),
  "EOF",
  "node \"$DSH_ANDROID_TOOLBOX/make-pptx.mjs\" outline.json shim-verify.pptx",
  "ls -l outline.json shim-verify.pptx"
].join("\n");
cp.spawn("bash", ["-c", cmd], {stdio: "inherit"}).on("exit", c => console.log("[shim-test] exit=" + c));
' 2>&1

echo
echo "== 3b. 生成的 pptx 是不是合法 ZIP =="
ls -l $FD/v009/shim-verify.pptx 2>&1
head -c 4 $FD/v009/shim-verify.pptx 2>/dev/null | od -c | head -1

echo
echo "== 3c. Agnes 脚本：没配 Key 时必须给出注册地址（不许假装成功）=="
if [ -f $TB/make-image.mjs ]; then
  AGNES_API_KEY= $NODE $TB/make-image.mjs "一只在窗台晒太阳的猫" no-key.png 2>&1 | head -6
  echo "make-image 退出码=$?"
else
  echo "make-image.mjs 不存在"
fi
if [ -f $TB/make-video.mjs ]; then
  AGNES_API_KEY= $NODE $TB/make-video.mjs "一只在窗台晒太阳的猫" no-key.mp4 2>&1 | head -6
  echo "make-video 退出码=$?"
else
  echo "make-video.mjs 不存在"
fi
MODEL_BLOCK
echo
echo "== 完成 =="
'''

    device_sh = (
        device_sh.replace("__FD__", files_dir)
        .replace("__DH__", dsh_home)
        .replace("__NATIVE__", native_abi)
        .replace("__NODE__", node)
        .replace("__FS__", fs_shim)
        .replace("__EXEC__", exec_shim)
        .replace("__TB__", toolbox)
        .replace("__DSHBIN__", dsh_bin)
        .replace("__TASK__", task if args.with_model else "skip")
        .replace("MODEL_BLOCK", model_block)
    )

    # ⚠️ adb push 的**中文源路径**会失败（本项目的老坑：pull/push 都不认中文路径），
    # 所以设备脚本先落到纯 ASCII 目录再 push；结论日志仍然写回 docs/logs（那是 Python
    # 自己写文件，不受 adb 限制）。
    ascii_dir = r"D:\dev\uiverify\v009"
    os.makedirs(ascii_dir, exist_ok=True)
    local_sh = os.path.join(ascii_dir, "v009-device.sh")
    with open(local_sh, "w", encoding="utf-8", newline="\n") as f:
        f.write(device_sh)

    rc, push = adb("push", local_sh, DEVICE_SCRIPT)
    note("\n## push\n%s" % push.strip())
    rc, chmod = adb_shell("chmod 644 %s" % DEVICE_SCRIPT)
    note("chmod rc=%s %s" % (rc, chmod.strip()))

    rc, res = adb("exec-out", "run-as", PKG, "sh", DEVICE_SCRIPT, timeout=1800)
    note("\n## 设备侧输出（run-as）\n%s" % res)

    finish(out)
    return 0


def finish(out):
    os.makedirs(os.path.dirname(LOG_OUT), exist_ok=True)
    text = "\n".join(out)
    with open(LOG_OUT, "w", encoding="utf-8") as f:
        f.write(text)
    # 控制台只打 ASCII 摘要，避免 cp936 下中文/emoji 抛 UnicodeEncodeError
    ascii_lines = [l for l in text.splitlines() if l.isascii()]
    for line in ascii_lines[-40:]:
        print(line)
    print("\n[verify-009] full log -> %s" % LOG_OUT.replace("\\", "/"))


if __name__ == "__main__":
    sys.exit(main())
