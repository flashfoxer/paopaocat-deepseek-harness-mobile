#!/usr/bin/env node
// 按**源码**重写三张翻译表：保留已有译文、补新条目、删陈旧条目、修换行错。
//
// ## 为什么不直接跑 gen-tables.mjs
//
// `gen-tables.mjs` 依赖三个中间文件（`/tmp/i18n-keys.json`、
// `/tmp/i18n-out/chunk-*.json`）—— 那是"从零做一轮新翻译"的流程。
// 而日常要修的其实只有三类**漂移**（审计 P0-11 / P1-5）：
//   ① 源码新增了文案 → 表里没有（切外语看到中文，**不报错**）；
//   ② 源码删了文案 → 表里留着（死条目，没人敢删）；
//   ③ 译文的换行写法不对（原文 `\n`、译文写成 `\\n` → 界面上露出可见的 `\n`）。
// 这三类用本脚本就地修，不需要重走翻译流水线，也不丢已有的译文。
//
// ## 用法
//
//   node install/i18n/rewrite-tables.mjs            # 只有"已经全部有译文"时才写
//   node install/i18n/rewrite-tables.mjs --dry      # 只报告将要做什么
//
// 新条目的译文从 `install/i18n/translations-drift.json`（key → {en,ja,ko}）取。
// **缺任何一条就拒绝写盘** —— 宁可报错，也不要写出一张有洞的表。

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { walkDart, scanStrings, groupAdjacent, toKey, shouldSkip, CN } from './scan.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');
const DRY = process.argv.includes('--dry');
// 只列出"缺翻译"的 key（完整、不截断），不写盘。
//
// ⚠️ 为什么要专门一个开关：核对脚本 `check-tables.mjs` 的人工输出为了好看会把
// key 截断到 110 字加 `…` —— 谁要是从**那个输出**里抓 key 去写翻译，
// 抓到的就是**残缺字符串**，写进表里永远匹配不上（而且看不出来）。
// 需要机器可读的完整 key 时就用这里。
const LIST_MISSING = process.argv.includes('--list-missing');

const SPEC = [
  { field: 'en', name: '英语', table: 'kEnTable', file: 'en_table_data.dart', part: 'en_table.dart' },
  { field: 'ja', name: '日语', table: 'kJaTable', file: 'ja_table_data.dart', part: 'ja_table.dart' },
  { field: 'ko', name: '韩语', table: 'kKoTable', file: 'ko_table_data.dart', part: 'ko_table.dart' },
];

const TABLES_DIR = path.join(REPO, 'app', 'lib', 'i18n', 'tables');

/** Dart 转义 → 运行时字符串（与 check-tables.mjs 同一份逻辑，改一处要改两处）。 */
function dartUnescape(raw) {
  let out = '';
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i];
    if (c !== '\\') { out += c; continue; }
    const n = raw[i + 1];
    switch (n) {
      case 'n': out += '\n'; i++; break;
      case 'r': out += '\r'; i++; break;
      case 't': out += '\t'; i++; break;
      case "'": out += "'"; i++; break;
      case '\\': out += '\\'; i++; break;
      case '$': out += '$'; i++; break;
      case 'u': {
        const hex = raw.slice(i + 2, i + 6);
        if (/^[0-9a-fA-F]{4}$/.test(hex)) { out += String.fromCharCode(parseInt(hex, 16)); i += 5; }
        else out += '\\u';
        break;
      }
      default: out += '\\' + (n ?? ''); i++;
    }
  }
  return out;
}

function readLit(s, i) {
  if (s[i] !== "'") throw new Error(`位置 ${i} 不是单引号字面量`);
  let out = '';
  i++;
  while (i < s.length) {
    const c = s[i];
    if (c === '\\') {
      const n = s[i + 1];
      if (n === 'n') out += '\n';
      else if (n === 'r') out += '\r';
      else if (n === 't') out += '\t';
      else if (n === "'") out += "'";
      else if (n === '\\') out += '\\';
      else if (n === '$') out += '$';
      else out += '\\' + (n ?? '');
      i += 2;
      continue;
    }
    if (c === "'") return [out, i + 1];
    out += c;
    i++;
  }
  throw new Error('字面量没有收尾');
}

function parseTable(absFile) {
  const src = fs.readFileSync(absFile, 'utf8');
  const open = src.indexOf('{');
  const map = new Map();
  let i = open + 1;
  while (i < src.length) {
    if (/\s|,/.test(src[i])) { i++; continue; }
    if (src[i] === '/' && src[i + 1] === '/') { while (i < src.length && src[i] !== '\n') i++; continue; }
    if (src[i] === '/' && src[i + 1] === '*') { const e = src.indexOf('*/', i + 2); i = e < 0 ? src.length : e + 2; continue; }
    if (src[i] === '}') break;
    const [k, a] = readLit(src, i);
    i = a;
    while (/\s/.test(src[i])) i++;
    if (src[i] !== ':') continue;
    i++;
    while (/\s/.test(src[i])) i++;
    const [v, b] = readLit(src, i);
    i = b;
    map.set(k, v);
  }
  return map;
}

/** 源码级内容 → Dart 单引号字面量（与 gen-tables.mjs 逐字一致，保证格式不漂） */
function litSourceLevel(s) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === '\\') { out += c + (s[i + 1] ?? ''); i++; continue; }
    if (c === "'") { out += "\\'"; continue; }
    if (c === '$') { out += '\\$'; continue; }
    if (c === '\n') { out += '\\n'; continue; }
    if (c === '\r') { out += '\\r'; continue; }
    if (c === '\t') { out += '\\t'; continue; }
    out += c;
  }
  return `'${out}'`;
}

function litPlain(s) {
  let out = '';
  for (const c of s) {
    if (c === '\\') out += '\\\\';
    else if (c === "'") out += "\\'";
    else if (c === '$') out += '\\$';
    else if (c === '\n') out += '\\n';
    else if (c === '\r') out += '\\r';
    else if (c === '\t') out += '\\t';
    else out += c;
  }
  return `'${out}'`;
}

/** 修复"译文里把换行写成了字面 \n"：按 key 的换行数把字面 `\n` 换成真换行。 */
function repairNewlines(key, value) {
  const want = (key.match(/\n/g) || []).length;
  let got = (value.match(/\n/g) || []).length;
  if (got === want) return { value, repaired: false };
  if (got > want) return { value, repaired: false, hopeless: true };
  let out = value;
  let need = want - got;
  while (need > 0) {
    const at = out.indexOf('\\n'); // 字面反斜杠 + n
    if (at < 0) break;
    out = out.slice(0, at) + '\n' + out.slice(at + 2);
    need--;
  }
  return { value: out, repaired: true };
}

// ── 1) 源码 key（源码级 + 运行时两种形态）
const srcKeys = new Map(); // 运行时 -> 源码级
const libDir = path.join(REPO, 'app', 'lib');
for (const f of walkDart(libDir)) {
  if (f.includes(`${path.sep}i18n${path.sep}tables${path.sep}`)) continue;
  if (f.endsWith(`${path.sep}dsh_i18n.dart`)) continue;
  const src = fs.readFileSync(f, 'utf8');
  for (const g of groupAdjacent(src, scanStrings(src))) {
    const before = src.slice(Math.max(0, g.start - 24), g.start);
    if (!/(?:context\.)?tr\(\s*$/.test(before)) continue;
    const { key: raw } = toKey(g);
    if (!CN.test(raw)) continue;
    if (shouldSkip(f, raw)) continue;
    srcKeys.set(dartUnescape(raw), raw);
  }
}

// ── 2) 新条目的译文
const driftFile = path.join(HERE, 'translations-drift.json');
const drift = fs.existsSync(driftFile)
  ? JSON.parse(fs.readFileSync(driftFile, 'utf8'))
  : {};

// ── 2.5) --list-missing：只报"表里没有的 key"（完整文本）
if (LIST_MISSING) {
  const first = parseTable(path.join(TABLES_DIR, SPEC[0].file));
  const missing = [...srcKeys.keys()].filter((k) => !first.has(k)).sort();
  if (process.argv.includes('--json')) {
    process.stdout.write(JSON.stringify(missing, null, 1) + '\n');
  } else {
    for (const k of missing) process.stdout.write(JSON.stringify(k) + '\n');
  }
  console.error(`缺翻译：${missing.length} 条（已按 --json 要求输出${
    process.argv.includes('--json') ? ' JSON' : ' 每行一个 JSON 字符串（完整、不截断）'}）`);
  process.exit(missing.length > 0 ? 0 : 0);
}

// ── 3) 逐张表重写
let totalNew = 0;
let totalStale = 0;
let totalRepaired = 0;
const missingTranslations = [];

for (const spec of SPEC) {
  const abs = path.join(TABLES_DIR, spec.file);
  const old = parseTable(abs);
  const lines = [];
  let newCount = 0;
  let repaired = 0;

  const keysSorted = [...srcKeys.keys()].sort();
  for (const runtimeKey of keysSorted) {
    const rawKey = srcKeys.get(runtimeKey);
    let value = old.get(runtimeKey);
    if (value === undefined) {
      const t = drift[runtimeKey];
      if (!t || !t[spec.field]) {
        missingTranslations.push(`${spec.name}: ${JSON.stringify(runtimeKey.slice(0, 60))}`);
        continue;
      }
      value = t[spec.field];
      newCount++;
    } else {
      const r = repairNewlines(runtimeKey, value);
      if (r.repaired) { value = r.value; repaired++; }
      else if (r.hopeless) {
        console.log(`⚠️ ${spec.name}：这条译文的换行**多于**原文，未自动修（请人工看）：${JSON.stringify(runtimeKey.slice(0, 60))}`);
      }
    }
    lines.push(`  ${litSourceLevel(rawKey)}: ${litPlain(value)},`);
  }

  const stale = [...old.keys()].filter((k) => !srcKeys.has(k));
  totalNew += newCount;
  totalStale += stale.length;
  totalRepaired += repaired;

  const body =
    `part of '${spec.part}';\n\n` +
    `/// key = 中文原文（与源码逐字一致），value = ${spec.name}。\n` +
    `///\n` +
    `/// 由 install/i18n/gen-tables.mjs 生成，可手改（改完跑 check-tables 复核）。\n` +
    `const Map<String, String> ${spec.table} = <String, String>{\n${lines.join('\n')}\n};\n`;

  console.log(
    `${spec.file.padEnd(22)} 原有 ${String(old.size).padStart(4)} → 新表 ${String(lines.length).padStart(4)} ` +
      `（补 ${newCount} · 删陈旧 ${stale.length} · 修换行 ${repaired}）`,
  );

  if (!DRY) fs.writeFileSync(abs, body);
}

console.log(
  `\n合计：补 ${totalNew} 条 · 删陈旧 ${totalStale} 条 · 修换行 ${totalRepaired} 条` +
    (DRY ? '（--dry，未写盘）' : ''),
);

if (missingTranslations.length) {
  console.log(`\n❌ 缺 ${missingTranslations.length} 条译文，**未写盘**（宁可不改，也不要写出有洞的表）：`);
  for (const m of missingTranslations.slice(0, 40)) console.log(`   ${m}`);
  console.log(`\n把这些补进 ${path.relative(process.cwd(), driftFile)} 后重跑。`);
  process.exit(1);
}
if (!DRY) console.log('✅ 已写盘。接着跑 `node install/i18n/check-tables.mjs` 复核。');
