#!/usr/bin/env node
// 给用到 tr() 的文件补 `i18n/dsh_i18n.dart` 的 import。
//
// 为什么单独一步：替换器只认「字符串字面量」，不碰 import 区 ——
// 混在一起做容易把 import 块搅乱。这里按**相对深度**算路径
// （lib/data/x.dart 是 `../i18n/...`，lib/ui/pages/x.dart 是 `../../i18n/...`），
// 插在最后一条 import 之后。
import fs from 'node:fs';
import path from 'node:path';
import { walkDart } from './scan.mjs';

const libRoot = process.argv[2] || 'lib';
const target = path.join(path.resolve(libRoot), 'i18n', 'dsh_i18n.dart');
const usesTr = /(?<![A-Za-z0-9_$])(?:context\.)?tr\(/;

let added = 0;
const touched = [];

for (const f of walkDart(libRoot)) {
  if (f.includes(`${path.sep}i18n${path.sep}`)) continue;
  let src = fs.readFileSync(f, 'utf8');
  if (!usesTr.test(src)) continue;

  const rel = path.relative(path.dirname(path.resolve(f)), target).split(path.sep).join('/');
  if (src.includes(`'${rel}'`)) continue;

  const importRe = /^import\s+['"][^'"]+['"];\s*$/gm;
  let last = null;
  let m;
  while ((m = importRe.exec(src))) last = m;
  if (!last) { console.log(`⏭  没有 import 段，跳过 ${f}`); continue; }

  const at = last.index + last[0].length;
  src = src.slice(0, at) + `\nimport '${rel}';` + src.slice(at);
  fs.writeFileSync(f, src);
  added++;
  touched.push(`${f}  →  ${rel}`);
}

console.log(touched.join('\n'));
console.log(`\n补 import：${added} 个文件`);
