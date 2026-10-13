#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 `assets/kb/kb_manifest.json` 回填/核对 `sha256`（与 `bytes`）。

## 为什么需要它（审计 P0-4）

清单里原来只有 `bytes` —— **只看体积，同长度的损坏或篡改一律放行**。
`kb_store.dart` 现在会在 rename 之前核对 `sha256`（给了才核对），
但前提是**清单里得有这个值**。手工填 64 位十六进制不现实，所以用这个：

    # 从已经下载好的文件算，写回清单
    python3 install/kb/sha256-fill.py --id zhwiki-cn-2307 --file /path/to/zhwiki.json --write

    # 只核对（CI/发版前跑）：清单里的值与文件对不上就退出 1
    python3 install/kb/sha256-fill.py --id zhwiki-cn-2307 --file /path/to/zhwiki.json

    # 只看看清单里哪些包还没有 sha256
    python3 install/kb/sha256-fill.py --list

## 口径

* **只填你自己核对过的那份文件**。sha256 的意义是"与审查过的产物绑定"——
  填一个你没看过的文件的哈希，等于把审核责任丢给下次下载。
* 上游改了文件 → 下载会**校验失败**（这是功能，不是 bug）。要接受新版本，
  得重新下载、重新审核、再跑一次这个脚本。
* 只写 `sha256`（需要时也写 `bytes`），**其它字段一个都不动**（`note` 里那些
  实测结论是人工写的，脚本不许碰）。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MANIFEST = os.path.join(REPO, "app", "assets", "kb", "kb_manifest.json")

CHUNK = 1 << 20  # 1 MiB


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def load_manifest() -> dict:
    with open(MANIFEST, encoding="utf-8") as f:
        return json.load(f)


def find_pack(cfg: dict, pack_id: str) -> dict:
    for p in cfg.get("packs", []):
        if p.get("id") == pack_id:
            return p
    raise SystemExit(f"清单里没有 id={pack_id} 这一包；现有："
                     + ", ".join(p.get("id", "?") for p in cfg.get("packs", [])))


def write_manifest_text(cfg: dict, replacements: dict[str, tuple[str, str]]) -> None:
    """按**文本**替换，保住原始排版与 `note` 里那些人工写的实测结论。

    replacements: id -> (旧行文本, 新行文本)
    """
    with open(MANIFEST, encoding="utf-8") as f:
        text = f.read()
    for pack_id, (old, new) in replacements.items():
        if text.count(old) != 1:
            raise SystemExit(f"文本替换不可靠（{pack_id}：命中 {text.count(old)} 次），已放弃写入")
        text = text.replace(old, new)
    # 写完必须仍是合法 JSON
    json.loads(text)
    with open(MANIFEST, "w", encoding="utf-8") as f:
        f.write(text)


def main() -> int:
    ap = argparse.ArgumentParser(description="回填/核对知识库清单的 sha256")
    ap.add_argument("--id", help="清单里的 pack id")
    ap.add_argument("--file", help="要算哈希的本地文件（你自己下载并核对过的那份）")
    ap.add_argument("--write", action="store_true", help="把结果写回清单")
    ap.add_argument("--list", action="store_true", help="只列出各包的 sha256/bytes 现状")
    args = ap.parse_args()

    cfg = load_manifest()

    if args.list:
        print(f"清单：{MANIFEST}\n")
        for p in cfg.get("packs", []):
            has = p.get("sha256") or "（缺）"
            print(f"  {p.get('id'):<22} bytes={p.get('bytes'):<12} sha256={has}")
        missing = [p.get("id") for p in cfg.get("packs", []) if not p.get("sha256")]
        if missing:
            print(f"\n⚠️ {len(missing)} 包还没有 sha256，只能做体积校验：{', '.join(missing)}")
        return 0

    if not args.id or not args.file:
        ap.error("需要 --id 与 --file（或 --list）")
    pack = find_pack(cfg, args.id)

    if not os.path.isfile(args.file):
        raise SystemExit(f"文件不存在：{args.file}")

    size = os.path.getsize(args.file)
    digest = sha256_of(args.file)
    print(f"文件：{args.file}")
    print(f"  bytes  = {size}")
    print(f"  sha256 = {digest}")

    declared_bytes = pack.get("bytes") or 0
    declared_hash = (pack.get("sha256") or "").lower()

    problems = []
    if declared_bytes and declared_bytes != size:
        problems.append(f"体积不一致：清单 {declared_bytes}，实际 {size}")
    if declared_hash and declared_hash != digest:
        problems.append(f"sha256 不一致：清单 {declared_hash}，实际 {digest}")
    for pr in problems:
        print(f"  ✗ {pr}")

    if not args.write:
        if problems:
            print("\n（这不是 --write 模式；上面的不一致仅供判断）")
        elif declared_hash:
            print("\n✓ 清单里的值与这份文件一致")
        else:
            print("\n清单里还没有 sha256 —— 加 --write 写入上面这个值")
        return 1 if problems else 0

    if declared_hash and declared_hash != digest and not problems:
        problems.append("未知不一致")

    # 组装文本替换
    replacements: dict[str, tuple[str, str]] = {}
    blocks = []
    if declared_bytes != size:
        blocks.append(f'"{size}"')
    # 逐字段替换：先 bytes 再 sha256，都是"该 pack 的紧邻行"
    text_changes = []
    if declared_bytes:
        text_changes.append(('"bytes": %d,' % declared_bytes, '"bytes": %d,' % size))
    else:
        text_changes.append(('"entries":', '"bytes": %d,\n      "entries":' % size))

    if declared_hash:
        text_changes.append(('"sha256": "%s",' % declared_hash, '"sha256": "%s",' % digest))
    else:
        # 插在 bytes 行之后（bytes 现在已经是对的）
        text_changes.append(('"bytes": %d,' % size,
                             '"bytes": %d,\n      "sha256": "%s",' % (size, digest)))

    with open(MANIFEST, encoding="utf-8") as f:
        text = f.read()
    for old, new in text_changes:
        if text.count(old) != 1:
            raise SystemExit(
                f"文本替换不可靠（`{old}` 命中 {text.count(old)} 次），已放弃写入 —— "
                "请手工改，别用脚本猜")
        text = text.replace(old, new)
    json.loads(text)  # 必须是合法 JSON
    with open(MANIFEST, "w", encoding="utf-8") as f:
        f.write(text)

    back = load_manifest()
    p2 = find_pack(back, args.id)
    assert p2.get("sha256") == digest and p2.get("bytes") == size, "写回后校验失败"
    print(f"\n✓ 已写回清单：{MANIFEST}")
    print("  下一步：`git diff` 看一眼，再出包（出包前的核对会确认资产进了包）")
    print("  ⚠️ 你填的哈希代表「这份文件是审查过的产物」—— 只填你核对过的文件。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
