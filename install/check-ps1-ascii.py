#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PowerShell 脚本的「纯 ASCII」约束检查。

## 为什么这是一条真问题，不是洁癖

这些 `.ps1` 是**在 Windows 上用 PowerShell 5.1 跑**的。PS 5.1 读没有 BOM 的
`.ps1` 时按**系统 ANSI 代码页**解码（中文 Windows 上是 GBK），于是文件里的
UTF-8 中文会变成乱码字节。乱码**不一定**只是显示难看 —— 它可能凑出一个
多余的引号或反引号，把后面的行**静默拆坏**。

这不是推测，是**已经发生过一次**的故障（记录在 `rebuild-and-verify.ps1` 顶部）：
`build-local-apk.ps1` 里写了一个中文工作区路径，结果脚本报
`CommandNotFoundException`，而且报的行号看着毫不相干。

所以几个脚本自己写了「THIS FILE MUST STAY PURE ASCII」。但**规则不会自己执行**：

  * 我本轮就踩了一次 —— 往 `build-local-apk.ps1` 加了几行中文注释；
  * `uitap.ps1` 也一直带着中文示例，正好违反它自己第 12 行那句声明。

这个脚本把那条规则变成可执行的门禁。

## 用法

    python3 install/check-ps1-ascii.py            # 检查 install\*.ps1
    python3 install/check-ps1-ascii.py --selftest # 验证这个检查器自己有效

退出码：0 = 通过；1 = 有文件违反自己声明的规则（或带了 BOM）。
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile

# 只有**自我声明**了这条规则的脚本才受约束 —— 别的脚本里出现中文（比如要打印
# 给用户看的提示）是正常需求，不该被这条门禁管。
DECLARES_ASCII_RULE = re.compile(
    r"(this file must stay|must stay 100% pure ascii|must stay pure ascii"
    r"|ascii-only on purpose|keep this file ascii)",
    re.IGNORECASE,
)

BOM = b"\xef\xbb\xbf"


def scan_file(path: str):
    """返回 (声明了规则吗, 非ASCII字节位置列表, 有BOM吗)。"""
    with open(path, "rb") as f:
        raw = f.read()
    declares = bool(DECLARES_ASCII_RULE.search(raw.decode("latin-1")))
    bad = [i for i, c in enumerate(raw) if c > 127]
    return declares, bad, raw.startswith(BOM)


def line_of(raw: bytes, pos: int) -> int:
    return raw[:pos].count(b"\n") + 1


def scan_dir(directory: str):
    """返回 (违规列表, 受约束文件数)。违规项 = (文件, 行号, 摘录) 或 (文件, 0, 'BOM')。"""
    offenders = []
    governed = 0
    for name in sorted(os.listdir(directory)):
        if not name.lower().endswith(".ps1"):
            continue
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            continue
        declares, bad, has_bom = scan_file(path)
        if not declares:
            continue
        governed += 1
        raw = open(path, "rb").read()
        for pos in bad:
            ln = line_of(raw, pos)
            if not any(o[0] == name and o[1] == ln for o in offenders):
                excerpt = raw.split(b"\n")[ln - 1].decode("utf-8", "replace").strip()
                offenders.append((name, ln, excerpt))
        if has_bom:
            offenders.append((name, 0, "文件带 UTF-8 BOM"))
    return offenders, governed


# ------------------------------------------------------------------ 自测

SELFTEST_GOOD = b"# ascii only\n# THIS FILE MUST STAY PURE ASCII\nWrite-Host 'ok'\n"
SELFTEST_BAD = (
    "# THIS FILE MUST STAY PURE ASCII\n"
    "Write-Host 'ok'\n"
).encode() + b"# \xe4\xb8\x93\xe5\xae\xb6\n"
SELFTEST_FREE = b"# no rule declared here\nWrite-Host '\xe4\xb8\xad\xe6\x96\x87'\n"


def selftest() -> int:
    d = tempfile.mkdtemp(prefix="ps1ascii-")
    cases = {
        "good.ps1": SELFTEST_GOOD,
        "bad.ps1": SELFTEST_BAD,
        "free.ps1": SELFTEST_FREE,          # 没声明规则 → 中文合法，不该报
        "bom.ps1": BOM + SELFTEST_GOOD,
    }
    for name, blob in cases.items():
        with open(os.path.join(d, name), "wb") as f:
            f.write(blob)

    offenders, governed = scan_dir(d)
    names = {o[0] for o in offenders}

    ok = True
    checks = [
        ("受约束文件数 = 3（good/bad/bom 都声明了规则）", governed == 3),
        ("bad.ps1 被抓到", "bad.ps1" in names),
        ("bom.ps1 被抓到", "bom.ps1" in names),
        ("good.ps1 不误报", "good.ps1" not in names),
        ("free.ps1 不受约束（中文合法）", "free.ps1" not in names),
    ]
    for label, passed in checks:
        print(f"  [{'ok ' if passed else 'FAIL'}] {label}")
        ok = ok and passed
    print("自测：" + ("全部通过" if ok else "有失败"))
    return 0 if ok else 1


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="检查声明了 ASCII-only 的 .ps1 是否真的纯 ASCII")
    ap.add_argument("--dir", default=here, help="要扫描的目录（默认脚本所在目录）")
    ap.add_argument("--selftest", action="store_true", help="验证这个检查器自己有效")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    offenders, governed = scan_dir(args.dir)
    print(f"受约束的 .ps1：{governed} 个（即自我声明了 ASCII-only 的那些）")
    if not offenders:
        print("全部通过：没有一个违反自己声明的纯 ASCII 规则。")
        return 0

    print(f"\n违反 {len(offenders)} 处 —— 在 PowerShell 5.1 上可能**静默拆坏**后续行：")
    for name, ln, excerpt in offenders:
        where = f"第 {ln} 行" if ln else "整个文件"
        print(f"  {name}  {where}: {excerpt}")
    print("\n修法：把这些字面量换成 ASCII（中文值改为命令行传入，或在别处文档里写）。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
