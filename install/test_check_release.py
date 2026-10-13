#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`check-release.py` 自己的测试。

一个"关于交付物的闸"如果不被测，就会变成它想消灭的那种东西（静默失效）。
这里用**合成 APK** 端到端跑真脚本、看真实退出码：

    ❌ 误报？  好包必须 PASS（否则每次出包都红灯，人就开始无视它）
    ✅ 抓得住？ 少一个字符串 / 少一个资产 / 版本对不上 —— 三种都必须 FAIL

外加一条**地面真值**测试：直接解析真实 0.57 APK 的二进制 manifest，
确认 AXML 解析器读出的 versionName 就是 0.0.57（UTF-16 字符串池路径）。

跑：python3 install/test_check_release.py
"""

from __future__ import annotations

import importlib.util
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CHECKER = os.path.join(HERE, "check-release.py")


# ----------------------------------------------------------- 合成 AXML（UTF-8）

def _pad4(b: bytes) -> bytes:
    return b + b"\x00" * (-len(b) % 4)


def build_axml(strings: list[str], manifest_attrs: list[tuple[str, int, object]]) -> bytes:
    """造一份够用的二进制 AndroidManifest.xml（只有 manifest 一个元素）。

    manifest_attrs: [(属性名, dataType, 值)]；dataType 0x03=字符串, 0x10=int。
    """
    # -- 字符串池（UTF-8 标志 0x100）
    encoded: list[bytes] = []
    for s in strings:
        raw = s.encode("utf-8")
        # uleb128 字符数 + uleb128 字节数 + 数据
        nchars = len(s)
        item = bytes([nchars & 0x7F]) + bytes([len(raw) & 0x7F]) + raw + b"\x00"
        encoded.append(item)
    offsets = []
    cursor = 0
    blob = b""
    for item in encoded:
        offsets.append(cursor)
        blob += item
        cursor += len(item)
    blob = _pad4(blob)

    pool_header_size = 28
    strings_start = pool_header_size + 4 * len(strings)
    pool_size = strings_start + len(blob)
    pool = struct.pack(
        "<HHIIIIII", 0x0001, pool_header_size, pool_size,
        len(strings), 0, 0x100, strings_start, 0,
    )
    pool += struct.pack("<%dI" % len(strings), *offsets)
    pool += blob

    # -- START_NAMESPACE / END_NAMESPACE / END_ELEMENT
    # ⚠️ ResXMLTree_node = chunk header(8) + lineNumber(4) + **comment(4)** = 16 字节，
    #    少写 comment 会让每个 chunk 恰恰短 4 字节，后面全部错位。
    ns_chunk = struct.pack(
        "<HHIIIII", 0x0100, 16, 24, 1, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    )

    # -- START_ELEMENT manifest
    attr_size = 20
    attr_start = 20
    count = len(manifest_attrs)
    el_size = 16 + attr_start + count * attr_size
    el = struct.pack("<HHIII", 0x0102, 16, el_size, 1, 0xFFFFFFFF)
    el += struct.pack("<II", 0xFFFFFFFF, strings.index("manifest"))
    el += struct.pack("<HHHHHH", attr_start, attr_size, count, 0, 0, 0)
    for name, dtype, value in manifest_attrs:
        if dtype == 0x03:
            data = strings.index(str(value))
        else:
            data = int(value)
        el += struct.pack("<IIIHBB", 0xFFFFFFFF, strings.index(name), 0xFFFFFFFF, attr_size, 0, dtype)
        el += struct.pack("<I", data)

    end_el = struct.pack("<HHIIIII", 0x0103, 16, 24, 1, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF)
    end_ns = struct.pack("<HHIIIII", 0x0101, 16, 24, 1, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF)

    body = pool + ns_chunk + el + end_el + end_ns
    return struct.pack("<HHI", 0x0003, 8, 8 + len(body)) + body


# ------------------------------------------------------------ 合成一个完整 APK

def make_repo(dst: str, version: str = "0.0.57", kapp: str = "0.57") -> str:
    """复制出**最小**的仓库骨架（只含核对真正会读的东西）。"""
    app = os.path.join(dst, "app")
    os.makedirs(os.path.join(app, "lib", "local"), exist_ok=True)
    for rel in ("lib/app_version.dart", "pubspec.yaml", "lib/local/android_toolbox.dart"):
        shutil.copy2(os.path.join(REPO, "app", rel), os.path.join(app, rel))
    # 覆盖版本号
    vp = os.path.join(app, "lib", "app_version.dart")
    with open(vp, encoding="utf-8") as f:
        src = f.read()
    src = re.sub(r"""kAppVersion\s*=\s*'[^']*'""", f"kAppVersion = '{kapp}'", src)
    with open(vp, "w", encoding="utf-8") as f:
        f.write(src)
    pp = os.path.join(app, "pubspec.yaml")
    with open(pp, encoding="utf-8") as f:
        src = f.read()
    src = re.sub(r"^version:\s*\S+", f"version: {version}", src, count=1, flags=re.M)
    with open(pp, "w", encoding="utf-8") as f:
        f.write(src)
    shutil.copytree(os.path.join(REPO, "app", "assets"), os.path.join(app, "assets"), dirs_exist_ok=True)
    return dst


def read_table(repo: str) -> dict[str, str]:
    p = os.path.join(repo, "app", "lib", "local", "android_toolbox.dart")
    with open(p, encoding="utf-8") as f:
        src = f.read()
    a = src.find("Map<String, String> assets")
    b = src.find("};", a)
    return dict(re.findall(r"""['"](assets/[^'"]+)['"]\s*:\s*['"]([^'"]+)['"]""", src[a:b]))


def make_apk(dst: str, repo: str, *, version_name: str = "0.0.57", version_code: int = 57,
             drop_key: str | None = None, drop_asset: str | None = None) -> str:
    strings = ["manifest", "versionName", "versionCode", version_name]
    axml = build_axml(
        sorted(set(strings)),
        [("versionName", 0x03, version_name), ("versionCode", 0x10, version_code)],
    )

    table = read_table(repo)
    blob = b"".join(k.encode() for k in table if k != drop_key)

    path = os.path.join(dst, "test.apk")
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("AndroidManifest.xml", axml)
        z.writestr("lib/arm64-v8a/libapp.so", blob)
        # 真实 APK 一定带这几个"运行时 dlopen"的库；不带的话新加的设备/引擎检查
        # 会如实报错（这不是误报，是合成的"好包"不够真实）。
        for lib in (
            "libLiteRtClGlAccelerator.so",
            "libLiteRtCompilerPlugin_Qualcomm.so",
            "libLiteRtDispatch_Qualcomm.so",
            "liblitertlm_jni.so",
        ):
            z.writestr("lib/arm64-v8a/" + lib, b"\x7fELF" + b"x" * 64)
        # ffmpeg / ffprobe：**必须**在包里（口播/短剧要 exec 它们），
        # 而且必须是真的 **AArch64** ELF 头 —— 普通夹具补 `\x7fELF` 还不够，
        # 核对脚本会读 e_machine（偏移 18，EM_AARCH64 = 183）。
        for exe in ("libffmpeg.so", "libffprobe.so",
                    "libavcodec.so", "libavformat.so", "libavfilter.so", "libavutil.so",
                    "libswscale.so", "libswresample.so", "libavdevice.so", "libpostproc.so"):
            header = bytearray(b"\x7fELF")
            header += b"\x02\x01\x01\x00"        # 64 位、小端
            header += b"\x00" * 8                   # padding
            header += b"\x02\x00\xb7\x00"        # e_type=EXEC, e_machine=183(AArch64)
            header += b"\x01\x00\x00\x00"
            header += b"\x00" * 30
            z.writestr("lib/arm64-v8a/" + exe, bytes(header) + b"x" * 64)
        z.writestr("assets/dsh-runtime.zip", b"x" * 1024)
        # 包里放**仓库里全部资产**（不只是工具箱那张表）—— 资产核对比的是全量
        root = os.path.join(repo, "app", "assets")
        for dirpath, _dirs, files in os.walk(root):
            for fn in files:
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, os.path.join(repo, "app")).replace("\\", "/")
                if rel == drop_asset:
                    continue
                with open(full, "rb") as f:
                    z.writestr("assets/flutter_assets/" + rel, f.read())
    return path


class CheckReleaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp(prefix="chkrel-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = make_repo(os.path.join(self.tmp, "repo"), "0.0.57", "0.57")

    def run_checker(self, apk: str, repo: str | None = None) -> tuple[int, str]:
        p = subprocess.run(
            [sys.executable, CHECKER, apk, "--repo", repo or self.repo],
            capture_output=True, text=True,
        )
        return p.returncode, p.stdout + p.stderr

    # ---- 不误报 ----
    def test_good_package_passes(self):
        apk = make_apk(self.tmp, self.repo)
        code, out = self.run_checker(apk)
        self.assertEqual(code, 0, f"好包被误报成失败：\n{out}")
        self.assertIn("全部通过", out)

    # ---- 抓得住：0.57 那个真实 bug 的形状 ----
    # 0.57 真实漏掉的那一条是 `assets/toolbox/open-app.mjs`；那个功能已于
    # 2026-10-10 取消、脚本也删了，所以这里换成**当前真实存在**的条目来复现
    # 同一个形状（表里有、libapp.so 里没有）。抓的仍然是"漏一条就发不出去"。
    def test_missing_table_key_fails(self):
        key = "assets/toolbox/make-image.mjs"
        apk = make_apk(self.tmp, self.repo, drop_key=key)
        code, out = self.run_checker(apk)
        self.assertEqual(code, 1, f"少了落盘表字符串却通过了：\n{out}")
        self.assertIn("make-image.mjs", out)
        self.assertIn("落盘表自检", out)

    # ---- 版本口径：pub 强制三段式，界面是两段式，两者是同一个版本 ----
    def test_version_normalisation(self):
        """`0.0.58` 与 `0.58` 必须视为同一版本，否则每一版都报一条假 WARN。"""
        # 按**文件路径**加载检查器：install/ 不在 sys.path 上（测试平时是
        # 以子进程方式跑它的），import 名字会 ModuleNotFoundError。
        spec = importlib.util.spec_from_file_location(
            "check_release", os.path.join(HERE, "check-release.py"))
        cr = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cr)
        norm = cr._norm_version
        # 同一版本的不同写法
        for a, b in (("0.58", "0.0.58"), ("0.58", "0.58"), ("0.58", "0.58.0"),
                     ("0.0.57", "0.57")):
            self.assertEqual(norm(a), norm(b), f"{a} 与 {b} 应该算同一版本")
        # 真漂移不能被放过
        for a, b in (("0.58", "0.0.57"), ("0.58", "0.57"), ("0.0.58", "0.0.59")):
            self.assertNotEqual(norm(a), norm(b), f"{a} 与 {b} 是不同版本，不该判成一样")

    def test_missing_ffmpeg_fails(self):
        """ffmpeg/ffprobe 缺了必须在出包时就拦下 —— 它不会让 App 崩，
        而是等用户点「口播 / 短剧」时才 ENOENT，那是最难查的一类问题。"""
        apk = make_apk(self.tmp, self.repo)
        with zipfile.ZipFile(apk) as z:
            blobs = [(n, z.read(n)) for n in z.namelist()
                     if not n.endswith(("libffmpeg.so", "libffprobe.so"))]
        with zipfile.ZipFile(apk, "w") as z:
            for n, b in blobs:
                z.writestr(n, b)
        code, out = self.run_checker(apk, self.repo)
        self.assertNotEqual(code, 0, f"缺 ffmpeg 竟然通过了：\n{out}")
        self.assertIn("libffmpeg.so", out)

    def test_wrong_arch_ffmpeg_fails(self):
        """放错架构（例如误拷了 x86 的 ffmpeg）也要拦下：装上去只会 exec 失败。"""
        apk = make_apk(self.tmp, self.repo)
        with zipfile.ZipFile(apk) as z:
            blobs = [(n, z.read(n)) for n in z.namelist()]
        with zipfile.ZipFile(apk, "w") as z:
            for n, b in blobs:
                if n.endswith("libffmpeg.so"):
                    b = bytearray(b)
                    b[18:20] = b"\x3e\x00"  # EM_X86_64 = 62
                z.writestr(n, bytes(b))
        code, out = self.run_checker(apk, self.repo)
        self.assertNotEqual(code, 0, f"x86 的 ffmpeg 竟然通过了：\n{out}")
        self.assertIn("AArch64", out)

    def test_retired_engine_libs_fail(self):
        """llama.cpp 相关库不该在包里（0.47 已按"路线 A"下线，是纯死重）。"""
        apk = make_apk(self.tmp, self.repo)
        # 往包里塞两个 llama 的库 —— 正是 0.57 真实包的样子
        with zipfile.ZipFile(apk, "a") as z:
            z.writestr("lib/arm64-v8a/libggml-vulkan.so", b"x" * 1000)
            z.writestr("lib/arm64-v8a/libllamaserver.so", b"x" * 10)
        code, out = self.run_checker(apk)
        self.assertEqual(code, 1, f"包里带着已下线的引擎却没报错：\n{out}")
        self.assertIn("已下线的引擎", out)
        self.assertIn("libllamaserver.so", out)

    def test_missing_dlopen_lib_fails(self):
        """运行时 dlopen 的库缺了必须报错 —— 编译期毫无征兆，真机才崩。"""
        apk = make_apk(self.tmp, self.repo)
        # 重造一个 APK：把其中一个 dlopen 的库拿掉
        with zipfile.ZipFile(apk) as z:
            keep = [
                (i.filename, z.read(i.filename))
                for i in z.infolist()
                if i.filename != "lib/arm64-v8a/libLiteRtDispatch_Qualcomm.so"
            ]
        with zipfile.ZipFile(apk, "w") as z:
            for n, b in keep:
                z.writestr(n, b)
        code, out = self.run_checker(apk)
        self.assertEqual(code, 1, f"缺了 dlopen 的库却没报错：\n{out}")
        self.assertIn("libLiteRtDispatch_Qualcomm.so", out)

    def test_missing_asset_fails(self):
        apk = make_apk(self.tmp, self.repo, drop_asset="assets/toolbox/make-image.mjs")
        code, out = self.run_checker(apk)
        self.assertEqual(code, 1, f"少了资产却通过了：\n{out}")
        self.assertIn("资产同一", out)

    # ---- 抓得住：发了旧包 ----
    def test_stale_version_fails(self):
        apk = make_apk(self.tmp, self.repo, version_name="0.0.56", version_code=56)
        code, out = self.run_checker(apk)
        self.assertEqual(code, 1, f"版本对不上却通过了：\n{out}")
        self.assertIn("versionName", out)

    def test_newer_tree_than_package_fails(self):
        """包是 0.0.57，源码树已经 0.0.58 → 这个包不该发。"""
        repo = make_repo(os.path.join(self.tmp, "repo2"), "0.0.58", "0.58")
        apk = make_apk(self.tmp, repo, version_name="0.0.57", version_code=57)
        code, out = self.run_checker(apk, repo)
        self.assertEqual(code, 1)
        self.assertIn("当前源码", out)

    # ---- 地面真值：真实 APK 的二进制 manifest ----
    def test_real_apk_manifest_ground_truth(self):
        import importlib.util

        real = os.path.join(REPO, "dist", "paopaocat-preview-0.57-arm64-v8a.apk")
        if not os.path.isfile(real):
            self.skipTest("本机没有 0.57 APK，跳过地面真值测试")
        spec = importlib.util.spec_from_file_location("check_release", CHECKER)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        attrs = mod.read_manifest_version(real)
        self.assertEqual(attrs.get("versionName"), "0.0.57", attrs)
        self.assertEqual(attrs.get("versionCode"), 57, attrs)

    # ---- 顺带：核对脚本自己的解析器能吃下真实包的字符串池（UTF-16）----
    def test_no_bom_weirdness_on_missing_manifest(self):
        path = os.path.join(self.tmp, "empty.apk")
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("lib/arm64-v8a/libapp.so", b"")
        code, out = self.run_checker(path)
        self.assertIn(code, (0, 1), out)  # 不该崩
        self.assertIn("SKIP", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
