#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 `dsh-runtime.zip` 瘦身：剔掉**在 Android 上永远用不到**的文件。

## 背景（审计 P0-5）

0.57 的 APK 是 226.6 MB，其中 `assets/dsh-runtime.zip` 占 150.6 MB。
那个 zip 是把 **Windows 的 DSH 安装树**（`D:\\Programs\\PaopaocatDSH\\app`）
整目录打包的，所以里面躺着 Windows 的 .exe/.dll/.pdb 以及一堆开发文件。

实测（本脚本 `--plan` 复算）：

    条目 26,495   压缩后 152.1 MB   解压后 484.5 MB
    .exe   6 个  70.8 MB   ← 单个 libreoffice-kit.exe 就 66.7 MB
    .dll  10 个  16.7 MB
    .pdb   4 个   4.2 MB
    .map  4375 个  9.9 MB  ← source map，只给调试器看
    .ts   8165 个  9.0 MB  ← TypeScript 源码 / .d.ts，运行时不读
    .md    948 个  3.3 MB  ← README / CHANGELOG

## 为什么敢删（每一类都读过代码，不是"感觉应该没事"）

* **Windows 平台包**：`libreoffice-kit-win32-x64`(66.7 MB)、`sharp-win32-x64`(8.3 MB)、
  `ripgrep-win32-x64`(2.0 MB)、`sherpa-onnx-win-x64`(8.7 MB)、`koffi-win32-x64`、
  `node-pty` 的 `prebuilds/win32-*` 与 `third_party/conpty/*`。
  这几个包**都用 npm 平台后缀约定**解析二进制，而 Android 上对应的包从来就没有过：
    - `@deepseek-ai/libreoffice-kit`：`resolveEngine()` 里
      `platformTarget()` 只认 darwin/win32/linux-glibc → Android 直接
      `throw "Unsupported LibreOfficeKit host"`；而且它是**懒调用**，
      删的是 optionalDependency，连 `import` 都不受影响。
    - `@vscode/ripgrep`：`try { require.resolve(platformPkg) } catch { throw }`——
      Android 上本来就解析不到，删 win32 不改变任何行为。
    - `sherpa-onnx-node/addon.js`：一串 `possible_paths` 逐个 `try/catch` 探测。
    - `node-pty`：按 `prebuilds/<platform>-<arch>/` 取；**必须保住**
      `prebuilds/linux-arm64/pty.node`（Android 用这个）。
    - `@img/sharp-win32-x64`：sharp 有 **wasm32 兜底**，
      而且 `@img/sharp-wasm32`（3.6 MB）**在包里、必须保住**。
* **开发文件**：`.map`（source map）、`.d.ts`/`.ts`（TypeScript 声明与源码）、
  `.md`、`test/`、`coverage/`。Node 运行时**不读**这些。
  这一条不是靠"我觉得"——`--verify` 会把包内**每个 `package.json` 的入口字段**
  （main/module/exports/bin/types…）解析成真实路径，如果任何一条入口指向
  被删的文件，就报 RISK 并让整个操作失败。

## 用法

    # 先看：打什么、省多少、有没有风险（**只读，不写任何东西**）
    python3 install/slim-runtime-zip.py --plan

    # 真做：写出瘦身后的 zip
    python3 install/slim-runtime-zip.py IN.zip OUT.zip

    # 只跑排除规则自检（对着包内 package.json 入口反查）
    python3 install/slim-runtime-zip.py --verify

    # 列出被删条目（给真机冒烟时对照）
    python3 install/slim-runtime-zip.py --plan --list-dropped

## ⚠️ 唯一诚实的限制

删完之后**必须真机冒烟**（至少 `dsh --version` 与 `make-pptx`）。
本脚本能证明的是"没有入口指向被删文件"和"Android 需要的平台变体都还在"，
**不能**证明每一条运行时代码路径都还走得通 —— 那要靠设备。
"""

from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import sys
import zipfile

# ------------------------------------------------------------------ 规则定义

WIN_SEG = re.compile(
    r"^(win32|windows|win)[-_.]|[-_.](win32|windows|win)[-_.]|[-_.](win32|windows|win)$",
    re.IGNORECASE,
)
WIN_NUM_SEG = re.compile(r"^win\d+[-_]", re.IGNORECASE)

# 许可证/版权文件**绝不删**：再分发时它们是义务，不是垃圾。
LEGAL = re.compile(
    r"^(licen[cs]e|copying|notice|authors|patents|third[-_]?party)", re.IGNORECASE
)

TEST_SEGMENTS = {
    "test", "tests", "__tests__", "__test__", "spec", "specs",
    "coverage", "testdata", "fixtures",
}
NOISE_SEGMENTS = {".github", ".circleci", ".idea", ".vscode", "benchmark", "benchmarks"}


def _segments(name: str) -> list[str]:
    return [s for s in name.replace("\\", "/").split("/") if s]


def _last(name: str) -> str:
    segs = _segments(name)
    return segs[-1] if segs else ""


def _package_content_start(segs: list[str]) -> int:
    """返回「包内容」从第几个段开始（即跳过 `.../node_modules/<pkg>` 本身）。

    为什么必须跳过：包**名**里可能正好带 test/spec 这类词。
    `@standard-schema/spec` 的 `spec` 是包名，不是测试目录 ——
    第一版规则就把它整包删了（自检抓到的）。同理 `@types/*`、`*-test` 包名。
    没有 node_modules 的路径（如 DSH 自己的 `app/lib/**`）返回 0（全段都看）。
    """
    idx = -1
    for i, s in enumerate(segs):
        if s == "node_modules":
            idx = i
    if idx < 0:
        return 0
    start = idx + 1
    if start < len(segs) and segs[start].startswith("@"):
        start += 1                      # @scope
    return min(start + 1, len(segs))    # +1 跳过包名本身


def rule_windows_binary(name: str) -> str | None:
    """W1：Windows 专有的二进制扩展名。Android 上不存在这些文件类型。"""
    ext = posixpath.splitext(_last(name))[1].lower()
    if ext in (".exe", ".dll", ".pdb", ".lib", ".exp", ".msi", ".sys", ".ocx"):
        return "W1 Windows 二进制 (.exe/.dll/.pdb/...)"
    return None


def rule_windows_platform(name: str) -> str | None:
    """W2：Windows 命名的**目录**（npm 平台包 / prebuild 变体）。

    ⚠️ 只删**目录段**，不删 Windows 命名的**单个源文件**。这一条是被自检逼出来的：
    第一版连 `file-applications-windows.js` / `default-browser/windows.js` 一起删，
    而它们是被**顶层静态 import** 的：
        dsh-native-command/lib/types/file-applications.js:4
            import { windowsFileApplications } from "./file-applications-windows.js";
        default-browser/index.js:6
            import windows from './windows.js';
    删掉 = 这两个模块一加载就崩。而这些文件**总共 0.0 MB** ——
    省不到任何体积，却拿"核心模块崩"去冒险，纯属亏本。
    （`isexe/index.js` 的 `require('./windows.js')` 在 `if (process.platform === 'win32')`
      里，那种才是安全的；但既然省不到体积，就不做这个区分了。）

    ⚠️ 这里**不**豁免许可证文件（与 markdown/测试目录规则不同）。
    曾经豁免过，后果是 `libreoffice-kit-win32-x64/LICENSE` 活了下来，于是这个包
    "底下还有文件"→ 整包移除的豁免不成立 → 自检对着 6 个预期删除的包报假失败。
    许可证豁免的目的是"别把还留着的包里的 LICENSE 删掉"，不是让一个
    整个都要扔的平台包被它的一张 LICENSE 拖住。该包的 LICENSE 与它
    要分发的二进制一一对应，二进制不发，许可证义务也随之不存在。
    """
    segs = _segments(name)
    for seg in segs[:-1]:                    # 只看目录段，不看文件名
        if WIN_SEG.search(seg) or WIN_NUM_SEG.search(seg):
            return f"W2 Windows 平台目录 (段 `{seg}`)"
        if seg.lower() == "conpty":
            return f"W2 ConPTY（Windows 专有伪终端，段 `{seg}`）"
    if _last(name).lower() == "openconsole.exe":
        return "W2 ConPTY 可执行文件"
    return None


def rule_source_map(name: str) -> str | None:
    if posixpath.splitext(_last(name))[1].lower() == ".map":
        return "D1 source map（只有调试器用）"
    return None


def rule_ts_declarations(name: str) -> str | None:
    low = _last(name).lower()
    if low.endswith((".d.ts", ".d.mts", ".d.cts")):
        return "D2 TypeScript 声明（.d.ts，编译期用）"
    return None


def rule_ts_source(name: str) -> str | None:
    low = _last(name).lower()
    if low.endswith((".ts", ".tsx", ".mts", ".cts")):
        return "D3 TypeScript 源码（Node 运行时只读 .js/.mjs/.cjs）"
    return None


def rule_markdown(name: str) -> str | None:
    low = _last(name).lower()
    if low.endswith((".md", ".markdown", ".mdx")):
        if LEGAL.match(_last(name)):
            return None
        return "D4 文档 (.md)"
    return None


def rule_tsconfig(name: str) -> str | None:
    low = _last(name).lower()
    if low in ("tsconfig.json", "tsconfig.build.json", ".eslintrc", ".eslintrc.js",
               ".eslintrc.cjs", ".eslintrc.json", ".prettierrc", ".prettierrc.json",
               ".editorconfig", ".npmignore", ".gitattributes", ".babelrc",
               "jsconfig.json") or low.startswith(".eslintrc."):
        return "D5 构建/编辑器配置（运行时不需要）"
    return None


def rule_test_dirs(name: str) -> str | None:
    if LEGAL.match(_last(name)):
        return None
    segs = _segments(name)
    start = _package_content_start(segs)
    for seg in segs[start:]:                # 只看包**内容**，不看包名
        low = seg.lower()
        if low in TEST_SEGMENTS:
            return f"D6 测试/覆盖目录（段 `{seg}`）"
        if low in NOISE_SEGMENTS:
            return f"D6 与运行无关的目录（段 `{seg}`）"
    return None


RULES = [
    rule_windows_binary,
    rule_windows_platform,
    rule_source_map,
    rule_ts_declarations,
    rule_ts_source,
    rule_markdown,
    rule_tsconfig,
    rule_test_dirs,
]

# -------------------------------------------------- 绝不能删的保底清单（加锁）
#
# 如果某条规则误伤了这些，就让整个操作失败（或按保底清单保留）——
# 而不是"少个文件应该也能跑"。
MUST_KEEP_PATTERNS = [
    re.compile(r"node-pty/prebuilds/linux-(arm64|x64)/"),
    re.compile(r"@img/sharp-wasm32/"),
    re.compile(r"libreoffice-kit/(lib|package\.json|README|NOTICE)"),
    re.compile(r"/shims/"),
    re.compile(r"^app/package\.json$"),
    re.compile(r"^app/lib/"),
    re.compile(r"^app/node_modules/\.bin/"),
    # ---- 名字里带 win32/windows，但**DSH 核心是静态 import 它的**，删了起不来 ----
    # 名字骗人：这两个看着像"纯 Windows 平台包"，其实被核心模块写成了顶层
    # `import ... from "@deepseek-ai/dsh-win32-process"`（不是条件加载）：
    #   dsh-subprocess-local/lib/index.js、runner.js  →  dsh-win32-process
    #   dsh-sandbox-local/lib/index.js                →  dsh-sandbox-windows-acl
    # 删掉 = 这两条顶层 import 解析失败 = App 起不来。
    # 而它们**总共只有 0.1 MB** —— 为省 0.1 MB 冒"起不来"的风险没有道理。
    # （这两个包在非 Windows 上调用相关函数时才会抛错，import 本身是安全的。）
    re.compile(r"^app/node_modules/@deepseek-ai/dsh-win32-process/"),
    re.compile(r"^app/node_modules/@deepseek-ai/dsh-sandbox-windows-acl/"),
]


def must_keep(name: str) -> str | None:
    n = name.replace("\\", "/")
    for p in MUST_KEEP_PATTERNS:
        if p.search(n):
            return f"保底清单命中 {p.pattern}"
    return None


# ------------------------------------------------------- package.json 入口反查
#
# 关键区分：**运行时入口** vs **编译期入口**。
#   * main / module / browser / bin / exports(运行时条件) → Node 真的会 require，
#     指向被删文件 = 真风险，必须让整个操作失败。
#   * types / typings / exports.types → 只有 TypeScript 消费者在编译期读，
#     运行时**永远不读**。它们指向 .d.ts 是正常的，也正该被删。
# 混在一起的后果：自检会对着几百个 `@aws-sdk/*/dist-types/index.d.ts` 报假风险
# （第一版就是这么翻的），最后人就开始无视这个检查。
ENTRY_FIELDS_RUNTIME = ("main", "module", "browser", "unpkg", "jsdelivr")
ENTRY_FIELDS_TYPES = ("types", "typings")


# Node 求值 exports 时**只认这些条件**（加上 'types'，那属于编译期）。
# 其它自定义条件（`source`、`@zod/source`、`deno`、`bun`、`development`…）
# 除非调用方显式 `--conditions`，否则永不被选中 —— 而 DSH 不会。
#
# 为什么必须区分（这是自检抓到的假失败）：
#   zod         → exports["."] = { "@zod/source": "./src/index.ts", import: "./index.js", … }
#   eventsource → { "source": "./src/index.ts", import: "./dist/index.js", … }
# 若把 `src/index.ts` 当运行时入口，就会判定"删 .ts 源码有风险"而白白放弃 1.9 MB ——
# 但 Node 根本不会走那条分支。
RUNTIME_CONDITIONS = {"node", "import", "require", "default", "browser"}


def _walk_exports(node, runtime: list[str], types: list[str]) -> None:
    if isinstance(node, str):
        runtime.append(node)
    elif isinstance(node, list):
        for x in node:
            _walk_exports(x, runtime, types)
    elif isinstance(node, dict):
        for k, v in node.items():
            if k == "types":                     # 编译期
                _walk_types(v, types)
            elif k.startswith("."):              # 子路径（"./mini" 等）→ 继续展开
                _walk_exports(v, runtime, types)
            elif k in RUNTIME_CONDITIONS:        # 运行时条件 → 算运行时入口
                _walk_exports(v, runtime, types)
            # 其它自定义条件：Node 永不匹配，忽略


def _walk_types(node, types: list[str]) -> None:
    if isinstance(node, str):
        types.append(node)
    elif isinstance(node, list):
        for x in node:
            _walk_types(x, types)
    elif isinstance(node, dict):
        for v in node.values():
            _walk_types(v, types)


def collect_entry_points(zf: zipfile.ZipFile):
    """→ (运行时入口: {包目录: [路径]}, 编译期入口: {包目录: [路径]})。"""
    runtime_out: dict[str, list[str]] = {}
    types_out: dict[str, list[str]] = {}
    for info in zf.infolist():
        n = info.filename.replace("\\", "/")
        if not n.endswith("/package.json") or "/node_modules/" not in n:
            continue
        pkgdir = posixpath.dirname(n)
        try:
            data = json.loads(zf.read(info.filename))
        except Exception:
            continue
        rt: list[str] = []
        ts: list[str] = []
        for f in ENTRY_FIELDS_RUNTIME:
            v = data.get(f)
            if isinstance(v, str):
                rt.append(v)
            elif isinstance(v, dict):
                rt.extend(x for x in v.values() if isinstance(x, str))
        for f in ENTRY_FIELDS_TYPES:
            v = data.get(f)
            if isinstance(v, str):
                ts.append(v)
            elif isinstance(v, dict):
                ts.extend(x for x in v.values() if isinstance(x, str))
        if "exports" in data:
            _walk_exports(data["exports"], rt, ts)
        b = data.get("bin")
        if isinstance(b, str):
            rt.append(b)
        elif isinstance(b, dict):
            rt.extend(x for x in b.values() if isinstance(x, str))

        def resolve(vals):
            out = []
            for v in vals:
                v = v.split("?")[0].lstrip("./")
                if v:
                    out.append(posixpath.normpath(posixpath.join(pkgdir, v)))
            return sorted(set(out))

        runtime_out[pkgdir] = resolve(rt)
        types_out[pkgdir] = resolve(ts)
    return runtime_out, types_out


def verify_entries(zf: zipfile.ZipFile, dropped_reasons: dict[str, str]):
    """任何被删的路径如果是某包的**运行时**声明入口 → 风险。

    返回 (runtime_risks, types_hits)；types_hits 只作信息，不算失败。
    """
    present = {i.filename.replace("\\", "/") for i in zf.infolist()}
    kept = {n for n in present if n not in dropped_reasons}
    kept_dirs: set[str] = set()
    for p in kept:
        kept_dirs.update(_ancestor_dirs(p))

    runtime, types = collect_entry_points(zf)
    risks = []
    for pkgdir, entries in runtime.items():
        # 整包被删 = 有意的平台包移除，不是"弄坏了保留的包"。
        # 这类跨包后果由 verify_imports 负责查（谁还在 import 它）。
        if pkgdir not in kept_dirs:
            continue
        for e in entries:
            if e in dropped_reasons and e in present:
                risks.append((pkgdir, e, dropped_reasons[e]))
    # 编译期入口命中：预期之中（.d.ts 就该被删），只报个数
    type_hits = []
    for pkgdir, entries in types.items():
        for e in entries:
            if e in dropped_reasons and e in present:
                type_hits.append((pkgdir, e))
    return risks, type_hits


# ------------------------------------------------- 静态引用反查（真正的安全闩）
#
# package.json 入口反查只管"包自己声明的入口"。它**管不到**真正致命的一种情况：
#
#   A 包的代码里写着 `import x from "B"`（顶层静态 import），而 B 被规则删了。
#   这时 A 的 package.json 完好无损，可 A 一加载就崩。
#
# 本轮真实的例子：`dsh-subprocess-local/lib/index.js`（DSH 核心）
# 顶层 `import ... from "@deepseek-ai/dsh-win32-process"`。
# 光看名字，`dsh-win32-process` 像是"纯 Windows 包"，删掉天经地义 ——
# 实际上删了 App 就起不来。这条检查就是为了挡住这一类。

# `esm`  = ESM 顶层 import：按规范**提升且无条件执行**，
#          目标被删 = 这个模块一加载就崩。**必须当失败处理。**
# `lazy` = require() / import()：可能在 if 里、可能带兜底。要再看有没有平台判断：
#          附近出现 platform / TESTING_ 就当作"平台分支"，删它本来就是目的。
SPEC_PATTERNS = [
    (re.compile(r"""\bfrom\s*['"]([^'"]+)['"]"""), "esm"),          # import/export ... from
    (re.compile(r"""\bimport\s+['"]([^'"]+)['"]"""), "esm"),        # import "x"（纯副作用）
    (re.compile(r"""\brequire\s*\(\s*['"]([^'"]+)['"]\s*\)"""), "lazy"),
    (re.compile(r"""\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)"""), "lazy"),
]
GUARD_HINTS = ("platform", "TESTING_", "TESTING_WINDOWS")
CODE_EXT = (".js", ".mjs", ".cjs", ".ts", ".mts", ".cts")
# Node **不能执行** .d.ts —— 所以 `import "...d.ts"` 必然是类型引用
# （JSDoc / TS 语法），不可能是真的运行时加载。直接跳过，消掉一整类噪声。
TYPE_ONLY_SUFFIX = (".d.ts", ".d.mts", ".d.cts")


def _is_guarded(txt: str, pos: int) -> bool:
    """匹配点附近有没有"失败也无所谓"的保护。

    两类信号：
      ① 平台判断（`process.platform` / `runtimePlatform` / `TESTING_`）→ 平台分支，
         删它本就是目的；
      ② 包在 `try { … } catch …` 里 → 目标不存在会被 catch 掉。

    ⚠️ 窗口必须给够，而且要**大小写不敏感**。踩过的两个坑：
      * sharp 的 `runtimePlatform` 是大写 P —— 大小写敏感匹配直接漏掉；
      * sharp / koffi 的 `case` 分支离 `try {` 有近千字符，`catch` 也在
        近千字符之外 —— 300 字符窗口根本够不着。
    这类只在 `lazy`（require/import()）上报，ESM 顶层 import 不走这个判断。
    """
    back = txt[max(0, pos - 1500): pos]
    fwd = txt[pos: pos + 1500]
    low = back.lower()
    if any(h in low for h in GUARD_HINTS):
        return True
    if ("try {" in back or "try{" in back) and "catch" in fwd:
        return True
    return False


def _resolve_candidates(base: str) -> list[str]:
    """把一个模块基路径展开成可能存在的文件（模拟 Node 的解析顺序）。"""
    if posixpath.splitext(base)[1].lower() in CODE_EXT or base.endswith(".json"):
        return [base]
    out = []
    for ext in (".js", ".mjs", ".cjs", ".json", ".node"):
        out.append(base + ext)
    for ext in (".js", ".mjs", ".cjs"):
        out.append(posixpath.join(base, "index" + ext))
    out.append(posixpath.join(base, "package.json"))
    return out


def _ancestor_dirs(path: str) -> list[str]:
    """path 的所有祖先目录（含直接父目录）。"""
    out = []
    d = posixpath.dirname(path)
    while d:
        out.append(d)
        nd = posixpath.dirname(d)
        if nd == d:
            break
        d = nd
    return out


def verify_imports(zf: zipfile.ZipFile, dropped: dict[str, str]):
    """返回 [(importer, spec, kind, 说明)]，只报**由本次删除造成**的断裂。"""
    infos = zf.infolist()
    present = {i.filename.replace("\\", "/") for i in infos}
    kept = {n for n in present if n not in dropped}

    # 预计算：哪些目录「底下还有文件」——把 O(n*m) 的扫描变成集合查询
    present_dirs: set[str] = set()
    kept_dirs: set[str] = set()
    for p in present:
        present_dirs.update(_ancestor_dirs(p))
    for p in kept:
        kept_dirs.update(_ancestor_dirs(p))

    pkg_json_cache: dict[str, dict] = {}

    def pkg_json(pkgdir: str) -> dict:
        cand = pkgdir + "/package.json"
        if cand not in present:
            return {}
        if cand not in pkg_json_cache:
            raw = None
            for key in (cand.replace("/", "\\"), cand):
                try:
                    raw = zf.read(key)
                    break
                except KeyError:
                    continue
            try:
                pkg_json_cache[cand] = json.loads(raw) if raw else {}
            except Exception:
                pkg_json_cache[cand] = {}
        return pkg_json_cache[cand]

    def find_pkg_dir(importer_dir: str, pkg: str):
        d = importer_dir
        while True:
            cand = posixpath.join(d, "node_modules", pkg)
            if cand in present_dirs:
                return cand
            if not d or "/" not in d:
                return None
            d = posixpath.dirname(d)

    broken = []
    for info in infos:
        n = info.filename.replace("\\", "/")
        if n not in kept or not n.endswith(CODE_EXT) or info.file_size > 2_000_000:
            continue
        try:
            txt = zf.read(info.filename).decode("utf-8", "ignore")
        except Exception:
            continue
        if "require(" not in txt and "import" not in txt:
            continue
        importer_dir = posixpath.dirname(n)
        seen: set[str] = set()
        for rx, kind in SPEC_PATTERNS:
            for m in rx.finditer(txt):
                spec = m.group(1)
                if spec.endswith(TYPE_ONLY_SUFFIX):
                    continue                  # 类型引用，不是运行时加载
                key = f"{kind}\x00{spec}"
                if key in seen:
                    continue
                seen.add(key)
                if kind == "lazy" and _is_guarded(txt, m.start()):
                    continue                  # 平台分支 / try-catch 里的加载，删它正是目的
                if spec.startswith((".", "/")):
                    base = posixpath.normpath(posixpath.join(importer_dir, spec))
                    cands = _resolve_candidates(base)
                    had = [c for c in cands if c in present]
                    if not had:
                        continue                  # 本来就没有，不关这次的事
                    if not [c for c in cands if c in kept]:
                        broken.append((n, spec, kind, "相对路径目标被删：" + had[0]))
                    continue
                parts = spec.split("/")
                pkg = "/".join(parts[:2]) if spec.startswith("@") else parts[0]
                sub = "/".join(parts[2:] if spec.startswith("@") else parts[1:])
                pkgdir = find_pkg_dir(importer_dir, pkg)
                if pkgdir is None:
                    continue                  # 本来就没装，不关这次的事
                if pkgdir not in present_dirs:
                    continue
                if pkgdir not in kept_dirs:
                    broken.append((n, spec, kind, f"整包被删：{pkgdir}"))
                    continue
                if sub:
                    cands = _resolve_candidates(posixpath.join(pkgdir, sub))
                else:
                    pj = pkg_json(pkgdir)
                    cands = []
                    for f in ("main", "module", "exports"):
                        v = pj.get(f)
                        if isinstance(v, str):
                            cands += _resolve_candidates(
                                posixpath.join(pkgdir, v.lstrip("./"))
                            )
                    cands += _resolve_candidates(posixpath.join(pkgdir, "index"))
                had = [c for c in cands if c in present]
                if had and not [c for c in cands if c in kept]:
                    broken.append((n, spec, kind, "目标入口被删：" + had[0]))
    return broken


def verify_licenses(zf: zipfile.ZipFile, dropped: dict[str, str]):
    """我们要分发的包里，根级许可证文件必须还在。

    为什么需要：`rule_windows_platform` **不再**豁免许可证文件（那曾导致
    整包删除的豁免失效）。代价是它可能顺手删掉一个**仍然要分发**的包的 LICENSE ——
    那是再分发义务问题，不是"少个文件也能跑"。
    所以单独查一遍：只要一个包还有文件被保留，它原来的根级许可证就必须保留。
    """
    present = {i.filename.replace("\\", "/") for i in zf.infolist()}
    kept = {n for n in present if n not in dropped}
    kept_dirs: set[str] = set()
    for p in kept:
        kept_dirs.update(_ancestor_dirs(p))

    # 每个包目录 → 它的根级许可证文件
    pkg_licenses: dict[str, list[str]] = {}
    for p in present:
        segs = _segments(p)
        if "node_modules" not in segs:
            continue
        start = _package_content_start(segs) - 1        # 回到包名那一段
        pkgdir = "/".join(segs[: start + 1])
        if posixpath.dirname(p) != pkgdir:
            continue                                    # 只看包根目录下的文件
        if LEGAL.match(_last(p)):
            pkg_licenses.setdefault(pkgdir, []).append(p)

    lost = []
    for pkgdir, files in pkg_licenses.items():
        if pkgdir not in kept_dirs:
            continue                                    # 整包不发 → 许可证义务不成立
        for f in files:
            if f not in kept:
                lost.append((pkgdir, f))
    return lost


def plan(zf: zipfile.ZipFile, list_dropped: bool, quiet: bool = False):
    total_entries = 0
    total_c = 0
    kept_c = 0
    per_rule: dict[str, list[int]] = {}
    dropped: dict[str, str] = {}
    locked: list[tuple[str, str]] = []

    for info in zf.infolist():
        name = info.filename.replace("\\", "/")
        total_entries += 1
        total_c += info.compress_size
        reason = None
        for rule in RULES:
            reason = rule(name)
            if reason:
                break
        if reason:
            lock = must_keep(name)
            if lock:
                locked.append((name, reason))
                reason = None
        if reason:
            dropped[name] = reason
            st = per_rule.setdefault(reason, [0, 0])
            st[0] += 1
            st[1] += info.compress_size
        else:
            kept_c += info.compress_size

    dropped_c = total_c - kept_c
    if not quiet:
        print(f"条目 {total_entries}   压缩后 {total_c / 1e6:.1f} MB")
        print("\n--- 各规则命中 ---")
        for reason, (n, b) in sorted(per_rule.items(), key=lambda kv: -kv[1][1]):
            print(f"  {b / 1e6:8.1f} MB  {n:6d} 个   {reason}")
        print(
            f"\n删除 {len(dropped)} 个条目 · {dropped_c / 1e6:.1f} MB（{dropped_c / total_c * 100:.1f}%）"
        )
        print(f"保留 {total_entries - len(dropped)} 个条目 · {kept_c / 1e6:.1f} MB")
        if locked:
            print(f"\n⚠️ {len(locked)} 个条目同时命中规则和保底清单 —— 已按保底清单保留：")
            for n, r in locked[:10]:
                print(f"    KEEP {n}   （规则曾想删：{r}）")
    if list_dropped and not quiet:
        print("\n--- 被删条目（前 60） ---")
        for n in sorted(dropped)[:60]:
            print(f"  {n}")
        if len(dropped) > 60:
            print(f"  ... 另有 {len(dropped) - 60} 条")
    return dropped, kept_c, total_c


def resolve_zip(args) -> str:
    if args.inzip:
        return args.inzip
    for cand in (
        "/root/办公/__migr/03-build-deps/android-node/app-assets/dsh-runtime.zip",
        "/tmp/apkchk/assets/dsh-runtime.zip",
    ):
        if os.path.isfile(cand):
            return cand
    raise SystemExit("找不到输入 zip，请显式给路径：slim-runtime-zip.py IN.zip OUT.zip")


def main() -> int:
    ap = argparse.ArgumentParser(description="剔除 Android 上用不到的运行时文件")
    ap.add_argument("inzip", nargs="?", help="输入 dsh-runtime.zip")
    ap.add_argument("outzip", nargs="?", help="输出路径（给了才会写）")
    ap.add_argument("--plan", action="store_true", help="只打计划，不写任何文件")
    ap.add_argument("--verify", action="store_true", help="只跑排除规则自检")
    ap.add_argument("--list-dropped", action="store_true", help="列出被删条目")
    args = ap.parse_args()

    src = resolve_zip(args)
    if not os.path.isfile(src):
        print(f"找不到输入：{src}", file=sys.stderr)
        return 2

    with zipfile.ZipFile(src) as zf:
        dropped, kept_c, total_c = plan(zf, args.list_dropped, quiet=args.verify)
        risks, type_hits = verify_entries(zf, dropped)
        broken = verify_imports(zf, dropped)
        static_broken = [b for b in broken if b[2] == "esm"]
        dyn_broken = [b for b in broken if b[2] != "esm"]
        lost_lic = verify_licenses(zf, dropped)

        failed = False
        if lost_lic:
            failed = True
            print(f"\n❌ 许可证检查失败：{len(lost_lic)} 个**仍要分发**的包丢了根级许可证")
            for pkg, f in lost_lic[:10]:
                print(f"    {f}   （包 {pkg} 仍在包里）")
            print("    这是再分发义务问题，不是'少个文件也能跑'。")
        if risks:
            failed = True
            print(f"\n❌ 入口反查失败：{len(risks)} 条**运行时入口**会被删掉")
            for pkg, e, r in risks[:20]:
                print(f"    {e}\n        包 {pkg}\n        规则 {r}")
        if static_broken:
            failed = True
            print(f"\n❌ 引用反查失败：{len(static_broken)} 处**顶层 ESM import** 会断")
            for imp, spec, _k, why in static_broken[:20]:
                print(f"    {imp}\n        引用 \"{spec}\"  —— {why}")
            print("    这是最严重的一类：ESM 顶层 import 按规范提升且无条件执行，")
            print("    目标没了就是模块一加载即抛 —— 通常等于 App 起不来。")
        if dyn_broken:
            print(f"\n⚠️ {len(dyn_broken)} 处 require()/import() 会断，"
                  f"且附近**没有**平台判断（可能是无条件加载，需真机确认）")
            for imp, spec, _k, why in dyn_broken[:10]:
                print(f"    {imp}\n        引用 \"{spec}\"  —— {why}")
        if failed:
            print("\n规则太宽，先修规则 —— 不要直接发。")
            return 1
        if not args.verify:
            print("\n✅ 排除规则自检通过：")
            print(f"     · 没有任何运行时入口被删（另有 {len(type_hits)} 条编译期 .d.ts 入口，预期之中）")
            print("     · 没有任何**原本可用的**静态 import 被删断")

        if args.plan or args.verify or not args.outzip:
            if not args.verify:
                print(f"\n预计：{total_c / 1e6:.1f} MB → {kept_c / 1e6:.1f} MB"
                      f"（省 {(total_c - kept_c) / 1e6:.1f} MB）")
                print("（--plan 只读模式；给 outzip 参数才会真的写文件）")
            return 0

        # ---- 真的写 ----
        out = args.outzip
        if os.path.abspath(out) == os.path.abspath(src):
            print("拒绝对输入文件原地覆盖，请给不同的输出路径", file=sys.stderr)
            return 2
        written = 0
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zo:
            for info in zf.infolist():
                name = info.filename.replace("\\", "/")
                if name in dropped:
                    continue
                # **原样保留条目名**（这个 zip 用的是反斜杠分隔符，
                # 消费端 MainActivity.kt 靠 replace('\\','/') 兜底；
                # 改名会让唯一的差异变成"多了一处没说清的行为变化"）
                new = zipfile.ZipInfo(info.filename, date_time=info.date_time)
                new.compress_type = info.compress_type or zipfile.ZIP_DEFLATED
                new.external_attr = info.external_attr
                new.internal_attr = info.internal_attr
                new.create_system = info.create_system
                zo.writestr(new, zf.read(info.filename))
                written += 1
        osize = os.path.getsize(out)
        print(f"\n写出 {out}")
        print(f"  条目 {written}（原 {len(zf.infolist())}）")
        print(f"  体积 {osize / 1e6:.1f} MB（原 {os.path.getsize(src) / 1e6:.1f} MB，"
              f"省 {(os.path.getsize(src) - osize) / 1e6:.1f} MB）")
        print("\n⚠️ 下一步必须真机冒烟：至少 `dsh --version` 与 `make-pptx`。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
