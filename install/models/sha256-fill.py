#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把**本机真实文件**的 sha256 填进模型清单（审计 P1-10）。

## 为什么需要它

`assets/models/model_manifest.json` 现在三个模型**都没有 `sha256`**，所以 App 只能
做体积校验（下载器会如实标 `hashVerified=false`，界面显示「仅体积校验」）。
而清单顶层的 `requireHash` 是**发布版的总开关**：一旦打开，缺哈希的条目会**被拒绝安装**。

⚠️ 顺序不能反：**先填哈希，再打开 requireHash**。反过来的话所有人都下不了模型
（而且报错信息看起来像"清单坏了"，不是"我们忘了填"）。

## 为什么这台机器填不了

三个模型是 584 MB ~ 2.58 GB，本机只有 4 MiB 的测试残留（`/tmp/h_*.litertlm`），
**不是同一份文件** —— 拿它算出来的哈希是错的，比不填更糟（会把真实的下载判成"校验失败"）。
所以在有真实文件的机器上跑本脚本。

## 用法

    python3 install/models/sha256-fill.py --list
    python3 install/models/sha256-fill.py --list-bad
    python3 install/models/sha256-fill.py --id gemma-3-1b-it --file /path/to/gemma3-1b.litertlm --write

`--file` 必须与清单里那条的 `bytes` **逐个字节相等**才会写（大小不符时脚本退出 2）
—— 这条防的是"下错版本却把哈希填进去"。
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MANIFEST = REPO / 'app' / 'assets' / 'models' / 'model_manifest.json'


def load():
    return json.loads(MANIFEST.read_text(encoding='utf-8'))


def sha256_of(path, chunk=1 << 20):
    h = hashlib.sha256()
    total = 0
    with open(path, 'rb') as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            total += len(b)
            h.update(b)
    return h.hexdigest(), total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--list', action='store_true', help='列出每个模型的 sha256 状态')
    ap.add_argument('--list-bad', action='store_true', help='只列出缺 sha256 的（便于脚本化）')
    ap.add_argument('--id', help='模型 id')
    ap.add_argument('--file', help='本机真实文件（必须与清单 bytes 完全一致）')
    ap.add_argument('--write', action='store_true', help='真写盘（默认只预览）')
    a = ap.parse_args()

    man = load()
    models = man.get('models', [])

    if a.list or a.list_bad:
        need = 0
        for m in models:
            has = bool(m.get('sha256'))
            if not has:
                need += 1
            if a.list_bad and has:
                continue
            print('%-16s %-12s sha256=%s' % (
                m.get('id'), ('%.1f MB' % (m.get('bytes', 0) / 1e6)),
                m['sha256'][:16] + '…' if has else '（缺）'))
        print('\n共 %d 个模型，缺 sha256 的 %d 个' % (len(models), need))
        if need:
            print('清单 requireHash = %s' % man.get('requireHash'))
            if man.get('requireHash'):
                print('❌ requireHash 已打开却还有条目缺哈希 —— 这些条目会被**拒绝安装**！')
                return 1
            print('提示：填完哈希再考虑打开 requireHash（顺序反了会让人都下不了）。')
        return 0

    if not a.id or not a.file:
        ap.print_help()
        return 2

    entry = next((m for m in models if m.get('id') == a.id), None)
    if entry is None:
        print('❌ 清单里没有 id=%s' % a.id)
        return 2

    p = Path(a.file)
    if not p.is_file():
        print('❌ 文件不存在：%s' % p)
        return 2

    digest, size = sha256_of(p)
    if size != entry.get('bytes'):
        print('❌ 大小不符：文件 %d 字节 / 清单 %s 字节' % (size, entry.get('bytes')))
        print('   这大概率不是同一条模型的同一份文件 —— **不要**把它的哈希填进去。')
        return 2

    print('%s' % entry['id'])
    print('  文件：%s（%d 字节）' % (p, size))
    print('  sha256：%s' % digest)
    if not a.write:
        print('（预览，未写盘；加 --write 才写）')
        return 0

    entry['sha256'] = digest
    MANIFEST.write_text(
        json.dumps(man, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    # 写回来先自己验一遍 JSON 没坏（比"写坏了才发现"便宜）
    json.loads(MANIFEST.read_text(encoding='utf-8'))
    print('✅ 已写入 %s' % MANIFEST.relative_to(REPO))
    print('   接着跑：flutter test test/model_manifest_test.dart')
    return 0


if __name__ == '__main__':
    sys.exit(main())
