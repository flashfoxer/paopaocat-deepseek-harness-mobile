#!/usr/bin/env node
// 从**已替换**的源码里反推出所有 tr() 的 key（而不是复用替换前的扫描结果 ——
// 后者可能和最终代码有细微出入，表里的 key 必须与代码逐字一致）。
import fs from 'node:fs';
import { walkDart, scanStrings } from './scan.mjs';

const keys = new Map();
for (const f of walkDart(process.argv[2] || 'lib')) {
  const src = fs.readFileSync(f, 'utf8');
  for (const s of scanStrings(src)) {
    const before = src.slice(Math.max(0, s.start - 16), s.start);
    if (!/(?:context\.)?tr\(\s*$/.test(before)) continue;
    const inner = s.inner;
    if (!/[\u4e00-\u9fff]/.test(inner)) continue;
    keys.set(inner, (keys.get(inner) || 0) + 1);
  }
}
const list = [...keys.keys()].sort();
fs.writeFileSync('/tmp/i18n-keys.json', JSON.stringify(list, null, 1));
console.log(`唯一 key：${list.length} 条 · 含占位符 ${list.filter((k) => /\{\d+\}/.test(k)).length} 条`);
console.log(`多行 key：${list.filter((k) => k.includes('\n')).length} 条`);
