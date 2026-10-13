#!/usr/bin/env node
// 把「`static const` / 顶层 `const` 的初始化器里调了 tr()」改成 getter。
//
// 为什么必须改成 getter 而不是 `static final`：`final` 只求值一次并被缓存，
// 用户切语言后它还是老语言那句 —— 而 getter 每次访问都重查表。
// 这些位置本就没有 BuildContext（所以替换器生成的 `context.tr` 在这里是
// `Undefined name 'context'`），因此一并改用全局 `tr`。
import fs from 'node:fs';
import path from 'node:path';
import { walkDart, scanStrings } from './scan.mjs';

const libRoot = process.argv[2] || 'lib';
const RE = /^(\s*)(static\s+)?const\s+(.+?)\s+([A-Za-z_]\w*)\s*=\s*/gm;

function findSemi(src, from, strings) {
  let depth = 0;
  for (let i = from; i < src.length; i++) {
    const s = strings.find((x) => x.start === i);
    if (s) { i = s.end - 1; continue; }
    const c = src[i];
    if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) depth--;
    else if (c === ';' && depth === 0) return i;
  }
  return -1;
}

let total = 0;
const report = [];

for (const f of walkDart(libRoot)) {
  if (f.includes(`${path.sep}i18n${path.sep}`)) continue;
  const src = fs.readFileSync(f, 'utf8');
  const strings = scanStrings(src);
  const edits = [];
  RE.lastIndex = 0;
  let m;
  while ((m = RE.exec(src))) {
    const [full, indent, isStatic, type, name] = m;
    const eqEnd = m.index + full.length;
    const semi = findSemi(src, eqEnd, strings);
    if (semi < 0) continue;
    const expr = src.slice(eqEnd, semi);
    if (!/(?:context\.)?tr\(/.test(expr)) continue;
    const fixed = expr.replace(/(?<!context)\.tr\(/g, 'tr(').replace(/context\.tr\(/g, 'tr(');
    edits.push({
      start: m.index,
      end: semi + 1,
      text: `${indent}${isStatic || ''}${type} get ${name} =>${fixed};`,
    });
  }
  if (!edits.length) continue;
  let out = src;
  for (const e of edits.sort((a, b) => b.start - a.start)) {
    out = out.slice(0, e.start) + e.text + out.slice(e.end);
  }
  fs.writeFileSync(f, out);
  total += edits.length;
  report.push(`${String(edits.length).padStart(3)}  ${f}`);
}

console.log(report.join('\n'));
console.log(`\nconst → getter：${total} 处`);
