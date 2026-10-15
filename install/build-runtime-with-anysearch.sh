#!/usr/bin/env bash
# 把 AnySearch 的搜索后端插件打进**运行时压缩包**（用户 2026-10-15 选的第 3 项）。
#
# 为什么必须动这个包：出厂的 `dsh-base` 组合里，联网搜索的后端钉死是
# `web-search-deepseek`（要 DEEPSEEK_API_KEY）。要换成 AnySearch，需要
#   ① 运行时里有 `@deepseek-ai/dsh-web-search-anysearch` 这个包（本脚本做这件事）；
#   ② App 的 overlay 把 `web.searchProvider` 改钉到 `anysearch`（Dart 侧已做，
#      见 `app/lib/data/session_capabilities.dart`）。
# 只做 ① 或只做 ② 都不生效 —— 而且**不能**在缺 ① 的时候写 ②（插件解析不到会让会话起不来）。
#
# ⚠️ 这个包里的条目名是**反斜杠**（Windows 上的 .NET ZipFile 建的，不符合 zip 规范）。
#    Linux 的 `unzip` 会把 `app\lib\bin.js` 解成一个**名字里带反斜杠的文件**，
#    所以这里用 Python 手工把 `\` 归一成 `/` 再落盘、再重新打包成规范（正斜杠）的 zip
#    —— 手机侧的解包代码本来就会把 `\` 归一（见 MainActivity.unpack），两种都认。
#
# 用法：
#   install/build-runtime-with-anysearch.sh [输入 zip] [输出 zip]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
IN_ZIP="${1:-/root/办公/dsh-runtime-0.57-slim.zip}"
OUT_ZIP="${2:-/root/办公/dsh-runtime-0.57-slim-anysearch.zip}"
PLUGIN_SRC="$REPO/runtime-plugins/dsh-web-search-anysearch"

[ -f "$IN_ZIP" ] || { echo "✗ 找不到输入运行时包：$IN_ZIP" >&2; exit 1; }
[ -f "$PLUGIN_SRC/lib/index.js" ] || { echo "✗ 找不到插件源码：$PLUGIN_SRC" >&2; exit 1; }

IN_ZIP="$IN_ZIP" OUT_ZIP="$OUT_ZIP" PLUGIN_SRC="$PLUGIN_SRC" python3 - <<'PY'
import hashlib, json, os, pathlib, shutil, sys, tempfile, zipfile

src = os.environ['IN_ZIP']
out = os.environ['OUT_ZIP']
plugin = pathlib.Path(os.environ['PLUGIN_SRC'])
PKG = 'app/node_modules/@deepseek-ai/dsh-web-search-anysearch'

tmp = tempfile.mkdtemp(prefix='dsh-runtime-build-')
try:
    # ① 解出来（把条目名里的反斜杠归一成正斜杠）
    with zipfile.ZipFile(src) as z:
        infos = z.infolist()
        for info in infos:
            name = info.filename.replace('\\', '/')
            if not name or name.endswith('/'):
                continue
            if name.startswith('/') or '..' in name.split('/'):
                raise SystemExit(f'✗ 包里有可疑路径：{info.filename!r}')
            dst = pathlib.Path(tmp, name)
            dst.parent.mkdir(parents=True, exist_ok=True)
            with z.open(info) as f, open(dst, 'wb') as g:
                shutil.copyfileobj(f, g)
    print(f'解出 {len(infos)} 个条目 → {tmp}')

    # ② 放进插件（整包：lib/ + package.json + README）
    dst = pathlib.Path(tmp, PKG)
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(plugin, dst)
    print(f'写入插件 → {PKG}')

    # ③ 重新打包（规范正斜杠；手机侧会归一，两种都认）
    count = 0
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, _dirs, files in os.walk(tmp):
            for f in files:
                full = pathlib.Path(root, f)
                rel = full.relative_to(tmp).as_posix()
                z.write(full, rel)
                count += 1
    size = os.path.getsize(out)
    sha = hashlib.sha256(open(out, 'rb').read()).hexdigest()
    print(f'\n✓ 已生成：{out}')
    print(f'  条目 {count}（原 {len(infos)}，+{count - len(infos)}）')
    print(f'  大小 {size} 字节（原 {os.path.getsize(src)}）')
    print(f'  sha256 {sha}')

    # ④ 自检：新包里插件文件在不在、原条目数有没有丢
    with zipfile.ZipFile(out) as z:
        names = set(z.namelist())
        for need in (f'{PKG}/package.json', f'{PKG}/lib/index.js'):
            assert need in names, f'✗ 新包里缺 {need}'
        assert not any('\\' in n for n in names), '✗ 还有反斜杠条目'
    print('  自检：插件在包里 ✓ / 条目全为正斜杠 ✓')
    print(json.dumps({'out': out, 'size': size, 'sha256': sha}, ensure_ascii=False))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PY
