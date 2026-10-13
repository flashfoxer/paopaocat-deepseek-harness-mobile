#!/usr/bin/env node
// 收尾修正：把替换器 v1 的 bug 产物改回来。
//
// bug：非 UI 层（data / state / protocol / local / main）不该带接收者，
// 但替换器拼字符串时没判断，生成了**裸 `.tr(...)`** ——
// `static const String label = .tr('Agnes（免费）');`
// 这会被解析成 Dart 3.13 的 dot-shorthand，报的错完全指不到病根。
//
// 只匹配**前面不是 `context`** 的 `.tr(`，所以 UI 层正确的 `context.tr(` 不受影响。
import fs from 'node:fs';
import path from 'node:path';
import { walkDart } from './scan.mjs';

const libRoot = process.argv[2] || 'lib';
let n = 0;
const touched = [];

for (const f of walkDart(libRoot)) {
  if (f.includes(`${path.sep}i18n${path.sep}`)) continue;
  const src = fs.readFileSync(f, 'utf8');
  const fixed = src.replace(/(?<!context)\.tr\(/g, 'tr(');
  if (fixed !== src) {
    const hits = (src.match(/(?<!context)\.tr\(/g) || []).length;
    fs.writeFileSync(f, fixed);
    n += hits;
    touched.push(`${String(hits).padStart(4)}  ${f}`);
  }
}

console.log(touched.join('\n'));
console.log(`\n修掉裸 .tr( ：${n} 处`);
