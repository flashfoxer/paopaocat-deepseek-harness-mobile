#!/usr/bin/env node
// DSH 手机版 i18n 替换器：把待翻译的中文字面量包成 `context.tr(...)` / `tr(...)`。
//
// ## 三个不显然的点
//
// 1. **必须从后往前改**。任何一处替换都会让后面的下标失效；一起算好、按 start
//    降序套用，就不会互相错位。
// 2. **`const` 必须一起摘掉**。`const Text('设置')` → `const Text(context.tr('设置'))`
//    是编译错误（常量表达式里不能有函数调用）。这里按**括号配对**找出每个 `const`
//    修饰的表达式区间，只要区间里落进了替换点，就把那个 `const` 删掉 ——
//    比「先编译、再照报错一个个删」快得多，也不必猜。
// 3. **相邻字面量要合成一句**。Flutter 里多行文案是 `'前半' '后半'`，
//    Dart 编译期拼成一整句；只包前半会得到半句话去查表。scan.mjs 已经合过组了。
//
// 用法：
//   node replace.mjs [--dry] [文件...]      # 不给文件则处理全部命中文件
import fs from 'node:fs';
import path from 'node:path';
import { collect, walkDart, scanFile } from './scan.mjs';

const args = process.argv.slice(2);
const dry = args.includes('--dry');
let files = args.filter((a) => !a.startsWith('--'));

const LIB = process.env.I18N_LIB || 'lib';

if (files.length === 0) {
  files = [...new Set(collect(LIB).map((x) => x.file))];
}

/** 字符串里有没有未转义的 quote */
function hasUnescaped(s, ch) {
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '\\') { i++; continue; }
    if (s[i] === ch) return true;
  }
  return false;
}

/** 挑一个不会打架的引号把内容包起来 */
function quoteLiteral(inner) {
  // ⚠️ 真实换行必须用三引号：早先一律用单引号包，多行文案会变成
  // `tr('\n第一行\n第二行')` —— 单引号串跨行是语法错误（`expert_page.dart`
  // 那处「生成技能」的长提示词就是这么坏的，一个串报了 225 个 illegal_character）。
  if (inner.includes('\n')) {
    if (!inner.includes("'''")) return `'''${inner}'''`;
    if (!inner.includes('"""')) return `"""${inner}"""`;
    return `'''${inner.replace(/'''/g, "\\'\\'\\'")}'''`;
  }
  const hasS = hasUnescaped(inner, "'");
  const hasD = hasUnescaped(inner, '"');
  if (!hasS) return `'${inner}'`;
  if (!hasD) return `"${inner}"`;
  return `'${inner.replace(/(?<!\\)'/g, "\\'")}'`;
}

/** 从 src[open] 的括号找到配对的闭合位置（跳过字符串与注释） */
function matchBracket(src, open, strings) {
  const pairs = { '(': ')', '[': ']', '{': '}' };
  const close = pairs[src[open]];
  if (!close) return -1;
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    // 跳过字符串
    const s = strings.find((x) => x.start === i);
    if (s) { i = s.end - 1; continue; }
    if (src[i] === '/' && src[i + 1] === '/') { while (i < src.length && src[i] !== '\n') i++; continue; }
    if (src[i] === '/' && src[i + 1] === '*') {
      let d = 1; i += 2;
      while (i < src.length && d > 0) {
        if (src[i] === '/' && src[i + 1] === '*') { d++; i += 2; }
        else if (src[i] === '*' && src[i + 1] === '/') { d--; i += 2; }
        else i++;
      }
      i--;
      continue;
    }
    if (src[i] === src[open]) depth++;
    else if (src[i] === close) { depth--; if (depth === 0) return i; }
  }
  return -1;
}

/** 找出所有 `const <表达式>` 的区间（只处理能配对成括号的那些） */
function constScopes(src, strings) {
  const scopes = [];
  const re = /\bconst\b/g;
  let m;
  while ((m = re.exec(src))) {
    // 字符串里的 "const" 不算
    if (strings.some((s) => m.index >= s.start && m.index < s.end)) continue;
    if (src[m.index - 1] === '$') continue;

    let i = m.index + 5;
    while (i < src.length && /\s/.test(src[i])) i++;
    // 往前扫到第一个括号；中途遇到 ; 或 = 说明是 `const var = ...` 声明，跳过
    let j = i;
    let bracket = -1;
    while (j < src.length && j < i + 80) {
      const c = src[j];
      if ('([{'.includes(c)) { bracket = j; break; }
      if (c === ';' || c === '=' || c === '\n') break;
      j++;
    }
    if (bracket < 0) continue;
    const close = matchBracket(src, bracket, strings);
    if (close < 0) continue;
    scopes.push({ delStart: m.index, delEnd: m.index + 5, from: m.index, to: close + 1 });
  }
  return scopes;
}

let changedFiles = 0;
let totalEdits = 0;
let totalConsts = 0;
const report = [];

for (const file of files) {
  const src = fs.readFileSync(file, 'utf8');
  const hits = scanFile(file).sort((a, b) => a.start - b.start);
  if (hits.length === 0) continue;

  // UI 层走 context.tr（靠 InheritedWidget 依赖刷新 const widget）；
  // 拿不到 context 的 data/state/protocol 层走全局 tr（scan 阶段已保证
  // 那些文件里的中文都是要翻的界面文案）。
  //
  // ⚠️ 这里必须拼成一个**完整函数名**再看要不要参数：早先写成
  // `${recv}.tr(...)` 时 recv 为空串，产出的是裸 `.tr(` —— 能编译期解析成
  // dot-shorthand 报一堆莫名其妙的错，已由 fixup-bare-tr.mjs 兜底修过。
  const fn = file.includes(`${path.sep}ui${path.sep}`) ? 'context.tr' : 'tr';

  const edits = [];
  for (const h of hits) {
    const lit = quoteLiteral(h.key);
    const call = h.args.length
      ? `${fn}(${lit}, [${h.args.join(', ')}])`
      : `${fn}(${lit})`;
    edits.push({ start: h.start, end: h.end, text: call });
  }

  // const 摘除：区间里落进替换点的 const 必须删
  const { scanStrings } = await import('./scan.mjs');
  const strings = scanStrings(src);
  const scopes = constScopes(src, strings);
  for (const sc of scopes) {
    if (edits.some((e) => e.start > sc.from && e.start < sc.to)) {
      edits.push({ start: sc.delStart, end: sc.delEnd, text: '' });
      totalConsts++;
    }
  }

  edits.sort((a, b) => b.start - a.start);
  let out = src;
  for (const e of edits) {
    // 连着删 const 时可能出现空白多余，压一下 `const ` 前后的双空格
    out = out.slice(0, e.start) + e.text + out.slice(e.end);
  }
  // 删掉 const 后可能出现 "(  )" 之类，不做花哨清理 —— 交给 dart format。

  totalEdits += hits.length;
  report.push(`${String(hits.length).padStart(4)}  ${file}${dry ? '' : '  ✓'}`);
  if (!dry) fs.writeFileSync(file, out);
  changedFiles++;
}

console.log(report.join('\n'));
console.log(`\n${dry ? '[dry] ' : ''}文件 ${changedFiles} · 替换 ${totalEdits} 处 · 摘 const ${totalConsts} 个`);
