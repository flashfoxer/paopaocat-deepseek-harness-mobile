#!/usr/bin/env node
// 核对翻译表与**源码**是否一致。
//
// ## 为什么这个脚本非有不可（审计 P0-11 / P1-5）
//
// 三张表的表头一直写着「由 install/i18n/gen-tables.mjs 生成，可手改
// （**改完跑 check-tables 复核**）」—— 而 `check-tables` **从来就不存在**。
// 于是"复核手段"只活在注释里，结果是：
//   * 源码里新加的文案没人发现没翻（切到外语就是一句中文，**不报错**）；
//   * 删掉的文案留在表里变成死条目（没人敢删，因为不知道还有没有用）；
//   * 三位审计员各自写脚本数，得出**三个不同答案**（1004/992/984 对 1023）——
//     那本身就是"缺一个权威提取器"的证据。
//
// ## 口径：复用仓库自己的扫描器，不另写第三个
//
// 本脚本用 `scan.mjs`（生成表的那一套）来取源码 key，所以"核对"与"生成"
// 是同源口径。特别地，它比旧的 `extract-keys.mjs` 多走一步 `groupAdjacent`：
// 相邻字面量（`'第一段'\n'第二段'`）与三引号多行串会被**拼成一个 key**，
// 而旧脚本把它们当成两条 —— 这正是三个审计数字对不上的来源之一。
//
// ## 检查项
//
//   1. 源码里有、表里没有  → **漏翻**（切外语会看到中文）
//   2. 表里有、源码里没有  → **陈旧**（死条目）
//   3. 三张表的 key 集合必须**逐条相同**（en/ja/ko 少一条就是那个语言缺文案）
//   4. 译文不能是空串
//   5. 占位符 `{n}` 集合必须与 key 一致（少一个 = 那个参数凭空消失）
//
// 用法：
//   node install/i18n/check-tables.mjs            # 默认扫 app/lib
//   node install/i18n/check-tables.mjs --json     # 机器可读
//   node install/i18n/check-tables.mjs --limit 40 # 限制每类打印条数
// 退出码：0 = 一致；1 = 有漂移。

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { walkDart, scanStrings, groupAdjacent, toKey, shouldSkip, CN } from './scan.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');

const TABLE_SPEC = [
  { field: 'en', name: '英语', table: 'kEnTable', file: 'app/lib/i18n/tables/en_table_data.dart' },
  { field: 'ja', name: '日语', table: 'kJaTable', file: 'app/lib/i18n/tables/ja_table_data.dart' },
  { field: 'ko', name: '韩语', table: 'kKoTable', file: 'app/lib/i18n/tables/ko_table_data.dart' },
];

/** 读一个 Dart **单引号**字面量（gen-tables 只产出这一种形状）。返回 [值, 下一个下标]。 */
function readLit(s, i) {
  if (s[i] !== "'") throw new Error(`位置 ${i} 不是单引号字面量：${JSON.stringify(s.slice(i, i + 20))}`);
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
      else out += '\\' + (n ?? ''); // 未知转义：原样保留，宁可报出来也别猜
      i += 2;
      continue;
    }
    if (c === "'") return [out, i + 1];
    out += c;
    i++;
  }
  throw new Error('字面量没有收尾');
}

/** 解析一张表：`const Map<String, String> kXxx = <String, String>{ 'k': 'v', ... };` */
function parseTable(absFile) {
  const src = fs.readFileSync(absFile, 'utf8');
  const open = src.indexOf('{');
  if (open < 0) throw new Error(`${absFile} 里找不到表体`);
  const map = new Map();
  let i = open + 1;
  while (i < src.length) {
    // 跳过空白、逗号、以及**注释** —— 表里有人加分段注释（`// ── 本地模型…`），
    // 不跳过去就会把它们当成 key 去读（第一版就是这样炸的）。
    if (/\s|,/.test(src[i])) { i++; continue; }
    if (src[i] === '/' && src[i + 1] === '/') {
      while (i < src.length && src[i] !== '\n') i++;
      continue;
    }
    if (src[i] === '/' && src[i + 1] === '*') {
      const end = src.indexOf('*/', i + 2);
      i = end < 0 ? src.length : end + 2;
      continue;
    }
    if (src[i] === '}') break;
    const [key, afterKey] = readLit(src, i);
    i = afterKey;
    while (i < src.length && /\s/.test(src[i])) i++;
    if (src[i] !== ':') throw new Error(`${absFile}：key 后面不是冒号（${JSON.stringify(src.slice(i, i + 20))}）`);
    i++;
    while (i < src.length && /\s/.test(src[i])) i++;
    const [value, afterValue] = readLit(src, i);
    i = afterValue;
    map.set(key, value);
  }
  return map;
}

/**
 * Dart 转义 → 运行时字符串。
 *
 * ⚠️ **这一步绝不能省**。`toKey().key` 是**源码级**文本（`\n` 是两个字符），
 * 而表里的 key 在 Dart 运行时已经是真正的换行。拿两种形态直接比，
 * 同一个 key 会**同时**被报成"漏翻"和"陈旧" —— 第一版就是这样，
 * 于是三个审计员各自数出三个不同答案（1004/992/984）。
 *
 * 仓库里没有任何 `tr(r'...')`（raw 字面量当 key）—— 已实测 0 处，
 * 所以这里可以放心解释转义。（若以后出现 raw，本条需要单独处理。）
 */
function dartUnescape(raw) {
  let out = '';
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i];
    if (c !== '\\') {
      out += c;
      continue;
    }
    const n = raw[i + 1];
    switch (n) {
      case 'n': out += '\n'; i++; break;
      case 'r': out += '\r'; i++; break;
      case 't': out += '\t'; i++; break;
      case 'b': out += '\b'; i++; break;
      case 'f': out += '\f'; i++; break;
      case 'v': out += '\v'; i++; break;
      case '0': out += '\0'; i++; break;
      case "'": out += "'"; i++; break;
      case '"': out += '"'; i++; break;
      case '\\': out += '\\'; i++; break;
      case '$': out += '$'; i++; break;
      case 'x': {
        const hex = raw.slice(i + 2, i + 4);
        if (/^[0-9a-fA-F]{2}$/.test(hex)) { out += String.fromCharCode(parseInt(hex, 16)); i += 3; }
        else out += '\\x';
        break;
      }
      case 'u': {
        if (raw[i + 2] === '{') {
          const end = raw.indexOf('}', i + 3);
          const hex = raw.slice(i + 3, end);
          if (end > 0 && /^[0-9a-fA-F]+$/.test(hex)) { out += String.fromCodePoint(parseInt(hex, 16)); i = end; }
          else out += '\\u';
        } else {
          const hex = raw.slice(i + 2, i + 6);
          if (/^[0-9a-fA-F]{4}$/.test(hex)) { out += String.fromCharCode(parseInt(hex, 16)); i += 5; }
          else out += '\\u';
        }
        break;
      }
      default:
        // 认不出来的转义：原样保留（宁可报出来也别猜）
        out += '\\' + (n ?? '');
        i++;
    }
  }
  return out;
}

/** 源码里所有**已经被 tr() 包着**的 key（与 gen-tables 同源口径，转成运行时形态）。 */
function extractSourceKeys(libDir) {
  const keys = new Map(); // key -> { file, count }
  for (const f of walkDart(libDir)) {
    // 表自己不算（它们也在 lib/ 下，但由 part/import 组成，不是调用点）
    if (f.includes(`${path.sep}i18n${path.sep}tables${path.sep}`)) continue;
    if (f.endsWith(`${path.sep}dsh_i18n.dart`)) continue;
    const src = fs.readFileSync(f, 'utf8');
    const groups = groupAdjacent(src, scanStrings(src));
    for (const g of groups) {
      const before = src.slice(Math.max(0, g.start - 24), g.start);
      if (!/(?:context\.)?tr\(\s*$/.test(before)) continue; // 只看已被 tr() 包的
      const { key: rawKey } = toKey(g);
      if (!CN.test(rawKey)) continue;
      if (shouldSkip(f, rawKey)) continue;
      const key = dartUnescape(rawKey); // ← 与表里的运行时形态对齐
      const hit = keys.get(key);
      if (hit) hit.count++;
      else keys.set(key, { file: path.relative(REPO, f), count: 1 });
    }
  }
  return keys;
}

const PLACEHOLDER = /\{(\d+)\}/g;
function placeholders(s) {
  const out = new Set();
  for (const m of s.matchAll(PLACEHOLDER)) out.add(m[1]);
  return out;
}

function main() {
  const args = process.argv.slice(2);
  const json = args.includes('--json');
  const li = args.indexOf('--limit');
  const limit = li >= 0 ? Number(args[li + 1]) : 12;
  const libDir = args.find((a) => !a.startsWith('--') && !/^\d+$/.test(a)) || path.join(REPO, 'app', 'lib');

  const source = extractSourceKeys(libDir);
  const tables = TABLE_SPEC.map((spec) => ({
    ...spec,
    data: parseTable(path.join(REPO, spec.file)),
  }));

  const problems = [];
  const report = { sourceCount: source.size, tables: {}, problems: [] };

  for (const t of tables) {
    const missing = [...source.keys()].filter((k) => !t.data.has(k));
    const stale = [...t.data.keys()].filter((k) => !source.has(k));
    const empty = [...t.data.entries()].filter(([, v]) => v.trim() === '').map(([k]) => k);
    const badPh = [];
    for (const [k, v] of t.data) {
      const a = placeholders(k);
      const b = placeholders(v);
      const same = a.size === b.size && [...a].every((x) => b.has(x));
      if (!same) badPh.push({ key: k, want: [...a].sort(), got: [...b].sort() });
    }
    // 换行结构必须一致。
    //
    // 为什么单列一条：实战抓到过 —— 某个译文的源码写法是 `\\n`（两个反斜杠）
    // 而原文是 `\n`，于是**运行时英文界面里会出现可见的 `\n` 两个字符**，
    // 中文没事、编译也没事。占位符检查看不出这种问题。
    const badNl = [];
    for (const [k, v] of t.data) {
      const kn = (k.match(/\n/g) || []).length;
      const vn = (v.match(/\n/g) || []).length;
      if (kn !== vn) badNl.push({ key: k, want: kn, got: vn });
    }
    report.tables[t.field] = {
      entries: t.data.size,
      missing: missing.length,
      stale: stale.length,
      empty: empty.length,
      placeholderMismatch: badPh.length,
      newlineMismatch: badNl.length,
    };
    if (missing.length) problems.push(`${t.name}：**漏翻** ${missing.length} 条`);
    if (stale.length) problems.push(`${t.name}：**陈旧** ${stale.length} 条`);
    if (empty.length) problems.push(`${t.name}：空译文 ${empty.length} 条`);
    if (badPh.length) problems.push(`${t.name}：占位符不一致 ${badPh.length} 条`);
    if (badNl.length) problems.push(`${t.name}：换行数与原文不一致 ${badNl.length} 条`);
    t.missing = missing;
    t.stale = stale;
    t.empty = empty;
    t.badPh = badPh;
    t.badNl = badNl;
  }

  // 三张表 key 集合必须逐条相同
  const [a, b, c] = tables;
  const diff = (x, y) => [...x.data.keys()].filter((k) => !y.data.has(k));
  const ab = diff(a, b);
  const ba = diff(b, a);
  const ac = diff(a, c);
  const ca = diff(c, a);
  report.keySetDiff = { ens_ja: ab.length, ja_en: ba.length, en_ko: ac.length, ko_en: ca.length };
  if (ab.length || ba.length) {
    problems.push(`en 与 ja 的 key 集合不一致（en 多的 ${ab.length} 条 / ja 多的 ${ba.length} 条）`);
  }
  if (ac.length || ca.length) {
    problems.push(`en 与 ko 的 key 集合不一致（en 多的 ${ac.length} 条 / ko 多的 ${ca.length} 条）`);
  }

  if (json) {
    console.log(JSON.stringify({ ...report, ok: problems.length === 0 }, null, 2));
    return problems.length ? 1 : 0;
  }

  console.log('='.repeat(72));
  console.log(`i18n 核对：源码 key ${source.size} 条 · 表 ${a.data.size} 条`);
  console.log('='.repeat(72));
  for (const t of tables) {
    const r = report.tables[t.field];
    console.log(
      `${String(t.name).padEnd(4)}  表内 ${String(r.entries).padStart(4)} 条 · ` +
        `漏翻 ${String(r.missing).padStart(3)} · 陈旧 ${String(r.stale).padStart(3)} · ` +
        `空 ${r.empty} · 占位符错 ${r.placeholderMismatch} · 换行错 ${r.newlineMismatch}`,
    );
  }

  const show = (title, keys, src) => {
    if (!keys.length) return;
    console.log(`\n--- ${title}（${keys.length} 条，列前 ${Math.min(limit, keys.length)}）---`);
    for (const k of keys.slice(0, limit)) {
      const one = k.replace(/\n/g, '\\n');
      const where = src?.get(k)?.file;
      console.log(`  ${one.length > 110 ? one.slice(0, 110) + '…' : one}${where ? `   〔${where}〕` : ''}`);
    }
    if (keys.length > limit) console.log(`  …另有 ${keys.length - limit} 条`);
  };
  show('源码有、表里没有（漏翻）', a.missing, source);
  show('表里有、源码没有（陈旧）', a.stale);
  show('空译文', a.empty);
  if (a.badNl.length) {
    console.log(`\n--- 换行数与原文不一致（${a.badNl.length} 条；译文里会露出可见的 \\n）---`);
    for (const p of a.badNl.slice(0, limit)) {
      console.log(`  原文 ${p.want} 个换行 / 译文 ${p.got} 个：${JSON.stringify(p.key).slice(0, 90)}`);
    }
  }
  if (a.badPh.length) {
    console.log(`\n--- 占位符不一致（${a.badPh.length} 条）---`);
    for (const p of a.badPh.slice(0, limit)) {
      console.log(`  ${p.key.replace(/\n/g, '\\n').slice(0, 80)}  期望 {${p.want}} 实得 {${p.got}}`);
    }
  }

  console.log('\n' + '-'.repeat(72));
  if (!problems.length) {
    console.log('结论：源码与三张表完全一致 ✓');
    return 0;
  }
  console.log('结论：有漂移 —— 这正是"切到外语会看到中文 / 删掉的文案还留在表里"的来源');
  for (const p of problems) console.log(`  · ${p}`);
  console.log('\n修法：补翻 / 删陈旧条目之后重跑本脚本；改完记得同步 app/test/i18n_test.dart');
  console.log('      里那个被钉住的条目数（`kEnTable.length`）。');
  return 1;
}

process.exit(main());
