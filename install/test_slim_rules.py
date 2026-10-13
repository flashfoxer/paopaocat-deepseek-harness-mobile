#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`slim-runtime-zip.py` 的规则回归测试。

瘦身规则是"删东西"的规则，所以它必须同时被两个方向钉住：

  * **有牙齿**：该删的大件真的被删（否则白瘦身）；
  * **不误伤**：被**顶层静态 import** 的 Windows 名字文件必须保住
    （否则 App 起不来 —— 这是本文件最重要的一组断言）。

每条断言的依据都写在用例的 docstring 里，都是读过真实代码得到的结论。

跑：python3 install/test_slim_rules.py
"""

from __future__ import annotations

import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SLIM = os.path.join(HERE, "slim-runtime-zip.py")

spec = importlib.util.spec_from_file_location("slim_runtime_zip", SLIM)
slim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(slim)


def drop_reason(path: str) -> str | None:
    """按真实顺序跑一遍规则（含保底清单）。None = 保留。"""
    for rule in slim.RULES:
        reason = rule(path)
        if reason:
            if slim.must_keep(path):
                return None
            return reason
    return None


class HasTeeth(unittest.TestCase):
    """该删的必须真删。"""

    def test_windows_binaries(self):
        """exe/dll/pdb 在 Android 上不可能被加载，是最大的块。"""
        for p in [
            "app/node_modules/@deepseek-ai/libreoffice-kit-win32-x64/bin/libreoffice-kit.exe",
            "app/node_modules/@vscode/ripgrep-win32-x64/bin/rg.exe",
            "app/node_modules/sherpa-onnx-win-x64/onnxruntime.dll",
            "app/node_modules/@img/sharp-win32-x64/lib/libvips-42.dll",
            "app/node_modules/node-pty/prebuilds/win32-x64/conpty.pdb",
            "app/node_modules/node-pty/third_party/conpty/1.25.260303002/win10-x64/OpenConsole.exe",
        ]:
            self.assertIsNotNone(drop_reason(p), p)

    def test_windows_platform_dirs(self):
        """npm 平台包与 prebuild 变体目录整体删。"""
        for p in [
            "app/node_modules/@deepseek-ai/libreoffice-kit-win32-x64/program/soffice.bin",
            "app/node_modules/sherpa-onnx-win-x64/sherpa-onnx.node",
            "app/node_modules/@koromix/koffi-win32-x64/win32_x64/koffi.node",
            "app/node_modules/node-pty/prebuilds/win32-arm64/conpty.node",
            "app/node_modules/koffi/build/koffi/win32_x64/koffi.node",
        ]:
            self.assertIsNotNone(drop_reason(p), p)

    def test_dev_files(self):
        """source map / .d.ts / .ts 源码 / 文档 / 测试目录。"""
        for p in [
            "app/node_modules/foo/dist/index.js.map",
            "app/node_modules/foo/dist/index.d.ts",
            "app/node_modules/zod/src/index.ts",
            "app/node_modules/foo/README.md",
            "app/node_modules/foo/test/foo.test.js",
            "app/node_modules/foo/.github/workflows/ci.yml",
        ]:
            self.assertIsNotNone(drop_reason(p), p)

    def test_keeps_darwin_and_linux_prebuilds(self):
        """只删 win32 变体；linux/darwin 的 prebuild 不碰（规则上也不该命中）。"""
        for p in [
            "app/node_modules/node-pty/prebuilds/linux-arm64/pty.node",
            "app/node_modules/node-pty/prebuilds/linux-x64/pty.node",
            "app/node_modules/node-pty/prebuilds/darwin-arm64/pty.node",
        ]:
            self.assertIsNone(drop_reason(p), p)


class NoFriendlyFire(unittest.TestCase):
    """不误伤 —— 这一组是"App 能不能起来"的关键。"""

    def test_statically_imported_windows_sources_survive(self):
        """这两个是被**顶层静态 import** 的，删了模块一加载就崩。

        dsh-native-command/lib/types/file-applications.js:4
            import { windowsFileApplications } from "./file-applications-windows.js";
        default-browser/index.js:6
            import windows from './windows.js';
        """
        for p in [
            "app/node_modules/@deepseek-ai/dsh-native-command/lib/types/file-applications-windows.js",
            "app/node_modules/default-browser/windows.js",
            "app/node_modules/isexe/windows.js",
            # getMachineId 是 opentelemetry 的平台分支（在 if 里）
            "app/node_modules/@opentelemetry/resources/build/esm/detectors/platform/node/machine-id/getMachineId-win.js",
        ]:
            self.assertIsNone(drop_reason(p), f"误删了被引用的平台源文件：{p}")

    def test_windows_named_dsh_core_packages_are_locked(self):
        """名字像"纯 Windows 包"，其实被 DSH 核心顶层静态 import。"""
        for p in [
            "app/node_modules/@deepseek-ai/dsh-win32-process/lib/index.js",
            "app/node_modules/@deepseek-ai/dsh-win32-process/package.json",
            "app/node_modules/@deepseek-ai/dsh-sandbox-windows-acl/lib/index.js",
        ]:
            self.assertIsNone(drop_reason(p), p)
            self.assertIsNotNone(slim.must_keep(p), f"保底清单没覆盖 {p}")

    def test_package_named_spec_is_not_a_test_dir(self):
        """`@standard-schema/spec` 的 `spec` 是**包名**，不是测试目录。

        第一版规则把它整包删了（自检抓到）。
        """
        for p in [
            "app/node_modules/@standard-schema/spec/dist/index.js",
            "app/node_modules/@standard-schema/spec/dist/index.cjs",
        ]:
            self.assertIsNone(drop_reason(p), p)

    def test_keeps_android_critical_assets(self):
        for p in [
            "app/node_modules/@img/sharp-wasm32/lib/sharp-wasm32-0.35.4.node.wasm",
            "app/shims/android-fs-shim.cjs",
            "app/shims/android-shim-flock.js",
            "app/lib/types/args.d.ts",          # DSH 自己的类型目录，锁住
            "app/package.json",
        ]:
            self.assertIsNone(drop_reason(p), p)

    def test_license_of_kept_package_survives(self):
        """我们不删"还在分发的包"的许可证 —— 那是再分发义务。"""
        for p in [
            "app/node_modules/foo/LICENSE",
            "app/node_modules/foo/LICENSE.md",
            "app/node_modules/@deepseek-ai/libreoffice-kit/NOTICE",
        ]:
            self.assertIsNone(drop_reason(p), p)


class GuardDetection(unittest.TestCase):
    """`_is_guarded` 要认得出"失败也无所谓"的加载。"""

    def test_sharp_switch_in_try(self):
        """sharp 的真实形态：try + switch(runtimePlatform) + case "win32-x64"。"""
        txt = (
            "if (!sharp) {\n  try {\n    switch (runtimePlatform) {\n"
            '      case "linux-arm64":\n        sharp = require("@img/sharp-linux-arm64/sharp.node");\n        break;\n'
            + '      case "linux-x64":\n        sharp = require("@img/sharp-linux-x64/sharp.node");\n        break;\n' * 8
            + '      case "win32-x64":\n        sharp = require("@img/sharp-win32-x64/sharp.node");\n        break;\n'
            "    }\n  } catch (err) { errors.push(err); }\n"
        )
        pos = txt.index("@img/sharp-win32-x64")
        self.assertTrue(slim._is_guarded(txt, pos))

    def test_koffi_if_in_try(self):
        """koffi 的真实形态：if (pkg == 'win32-x64') { try { require(...) } catch {} }"""
        txt = (
            "function loadStatic(pkg) {\n    let native = null;\n"
            "    if (pkg == 'win32-x64') {\n        try {\n"
            "            native = require('@koromix/koffi-win32-x64');\n"
            "        } catch (err) {\n            // Go on\n        }\n    }\n"
        )
        pos = txt.index("@koromix/koffi-win32-x64")
        self.assertTrue(slim._is_guarded(txt, pos))

    def test_unguarded_top_level_require_is_not_guarded(self):
        """反例：没有任何保护的顶层 require 不能被当成"安全"。"""
        txt = "const x = require('@scope/thing');\nmodule.exports = x;\n"
        self.assertFalse(slim._is_guarded(txt, txt.index("@scope/thing")))


class ExportConditions(unittest.TestCase):
    """Node 只认标准条件；自定义条件的 .ts 源码不算运行时入口。"""

    def test_custom_condition_not_runtime(self):
        """zod: { "@zod/source": "./src/index.ts", import: "./index.js" }"""
        rt, ts = [], []
        slim._walk_exports(
            {".": {"@zod/source": "./src/index.ts", "types": "./index.d.cts",
                   "import": "./index.js", "require": "./index.cjs"}},
            rt, ts,
        )
        self.assertIn("./index.js", rt)
        self.assertIn("./index.cjs", rt)
        self.assertNotIn("./src/index.ts", rt, "自定义条件的 .ts 被当成了运行时入口")
        self.assertIn("./index.d.cts", ts)

    def test_source_condition_not_runtime(self):
        """eventsource: { "source": "./src/index.ts", "import": "./dist/index.js" }"""
        rt, ts = [], []
        slim._walk_exports(
            {".": {"source": "./src/index.ts", "import": "./dist/index.js",
                   "require": "./dist/index.cjs", "default": "./dist/index.js"}},
            rt, ts,
        )
        self.assertNotIn("./src/index.ts", rt)
        self.assertIn("./dist/index.js", rt)


class PackageRootDetection(unittest.TestCase):
    """`_package_content_start`：包名不算"包内容"。"""

    def test_scoped_package_name_excluded(self):
        segs = "app/node_modules/@standard-schema/spec/dist/index.js".split("/")
        start = slim._package_content_start(segs)
        self.assertNotIn("spec", segs[start:], "包名 spec 被当成包内容了")

    def test_real_test_dir_included(self):
        segs = "app/node_modules/foo/test/x.js".split("/")
        start = slim._package_content_start(segs)
        self.assertIn("test", segs[start:])


class RealZip(unittest.TestCase):
    """对着真实 runtime zip 跑一遍（包不在就跳过）。"""

    ZIP = "/root/办公/__migr/03-build-deps/android-node/app-assets/dsh-runtime.zip"

    def setUp(self):
        if not os.path.isfile(self.ZIP):
            self.skipTest("本机没有 dsh-runtime.zip")

    def test_drops_known_big_items_keeps_known_critical(self):
        import zipfile

        with zipfile.ZipFile(self.ZIP) as z:
            names = {i.filename.replace("\\", "/") for i in z.infolist()}
        must_drop = [
            "app/node_modules/@deepseek-ai/libreoffice-kit-win32-x64/bin/libreoffice-kit.exe",
            "app/node_modules/@vscode/ripgrep-win32-x64/bin/rg.exe",
        ]
        for p in must_drop:
            self.assertIn(p, names, f"真实 zip 里没有 {p}（测试假设过时）")
            self.assertIsNotNone(drop_reason(p), p)
        must_keep = [
            "app/node_modules/@deepseek-ai/dsh-win32-process/package.json",
            "app/node_modules/@img/sharp-wasm32/lib/sharp-wasm32-0.35.4.node.wasm",
            "app/node_modules/node-pty/prebuilds/linux-arm64/pty.node",
            "app/node_modules/default-browser/windows.js",
        ]
        for p in must_keep:
            if p in names:
                self.assertIsNone(drop_reason(p), f"真实 zip 里误删了 {p}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
