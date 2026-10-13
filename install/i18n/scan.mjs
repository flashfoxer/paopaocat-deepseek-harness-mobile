#!/usr/bin/env node
// DSH 手机版 i18n 工具 —— Dart 词法扫描（v2）。
//
// v1 的教训：
//   1. 原来把全角标点也算「含中文」，于是 `'（'` 这种纯标点串也被抓进来 ——
//      翻它没有意义。v2 只认**汉字**（源语言是中文，所以源串只可能有汉字）。
//   2. `lib/data/artifacts.dart` 里有**正则表达式**（`^[`*「『《]+`），
//      它含汉字字符类但绝不能翻译。v2 用精确黑名单挡掉。
//   3. 原来把 `${...}` 一律压成 `${…}`，丢了插值表达式 —— 而带变量的句子
//      （450 条！）必须转成 `{0}` 占位符 + 传参，否则每次变量不同就查不到表。
//      v2 输出结构化 segments。
//
// 用法：
//   node scan.mjs report <lib目录>   —— 统计 + 写 /tmp/i18n-*.json
//   node scan.mjs list  <lib目录>   —— 只打待翻译的唯一串
import fs from 'node:fs';
import path from 'node:path';

/** 只认汉字：源语言是中文，翻译针对的就是这些字 */
export const CN = /[\u3400-\u4dbf\u4e00-\u9fff]/;

const IDENT_START = /[A-Za-z_\u00a0-\uffff]/;

/**
 * **整文件不翻译**。理由分三类，别随手往里加：
 *   · 电脑端资产（技能名 / 专家库 / 内置会话）—— 用户已定「保持电脑端原文」；
 *   · 内部日志 —— 排障时要 grep 出 `[dsh-xxx]` 那些行，翻译只会让人找不到；
 *   · 发给电脑端的内容（交接笔记、导出的脚本）—— App 不替电脑端决定语言。
 */
export const SKIP_FILES = new Set([
  // ⚠️ `builtin_starters.dart` **原来在这张名单里**（旧理由："内置会话模板，
  //    点一下会发给电脑端"）—— 2026-10-12 查出这条**排得太宽**：
  //    那个文件里除了"发给模型的首句"，还有**首页卡片的标题与副标题**，
  //    那是纯粹的手机端 UI 文字。整文件跳过的后果是：切英/日/韩时首页
  //    13 张卡片**全是中文**，而 check-tables 照样报 0 漂移（它看不见就以为没有）。
  //    现在**移出名单**，让那 39 条（13 条 × 标题/副标题/首句）正常进三张表。
  //    首句也该翻：它是**这台手机拼出来、以用户身份发出去**的第一句话，
  //    不是电脑端 DSH 的资产（技能名本身是 ASCII，不受语言影响）。
  'builtin_skills.dart',     // 随包技能（装到电脑端的 DSH_HOME/skills）
  'expert_store.dart',       // 专家库（321 名，来自电脑端插件资产）
  'skill_store.dart',        // 技能名（电脑端读到的）
  'changelog.dart',          // 更新日志（项目自己的中文技术流水）
  'dsh_runtime.dart',        // [dsh-runtime] 内部日志
  'rotation_proxy.dart',     // [dsh-rotate] 内部日志
  'session_index.dart',      // [ws-index] 内部日志
  'android_toolbox.dart',    // [dsh-toolbox] 内部日志
  'session_registry.dart',   // [dsh-live] 内部日志
  'provider_keys.dart',      // [dsh-keys] 内部日志
  'acp_client.dart',         // 协议日志
  'diagnostics_log.dart',    // 运行日志本身
  'context_budget.dart',     // 交接笔记：正文是发给上一个模型的提示词
  'session_transcript.dart', // 生成给 node 跑的脚本注释
]);

/** 精确逐字黑名单：长得像中文、其实是**正则/协议字面量**的串 */
export const SKIP_STRINGS = new Set([
  '^[`*「『《]+',
  '[`*」』》]+$',
  '（',
  '）',
  '、',
  '：',
  '，',
  '。',
]);

/** `[dsh-host] ...` 这类调试日志 */
const LOG_PREFIX = /^\[[a-zA-Z0-9_-]{2,}\]/;

export function shouldSkip(file, text) {
  if (SKIP_FILES.has(path.basename(file))) return true;
  if (SKIP_STRINGS.has(text)) return true;
  if (LOG_PREFIX.test(text)) return true;
  if (!CN.test(text)) return true;
  return false;
}

/**
 * 扫描一份 Dart 源码里的字符串字面量。
 * 返回的每项带 `segments`（结构化文本/插值）与 `inner`（源码级内容，保留转义）。
 */
export function scanStrings(src) {
  const out = [];
  const n = src.length;
  let i = 0;

  while (i < n) {
    const c = src[i];

    if (c === '/' && src[i + 1] === '/') {
      while (i < n && src[i] !== '\n') i++;
      continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      let depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (src[i] === '/' && src[i + 1] === '*') { depth++; i += 2; }
        else if (src[i] === '*' && src[i + 1] === '/') { depth--; i += 2; }
        else i++;
      }
      continue;
    }

    if (c === "'" || c === '"') {
      const isRaw = (src[i - 1] === 'r' || src[i - 1] === 'R') &&
        !IDENT_START.test(src[i - 2] || '');
      const start = i;
      const q = c;
      const triple = src[i + 1] === q && src[i + 2] === q;
      const openLen = (isRaw ? 1 : 0) + (triple ? 3 : 1);
      i += triple ? 3 : 1;

      const segments = [];
      let buf = '';
      let closed = false;

      const flush = () => { if (buf) { segments.push({ type: 'text', text: buf }); buf = ''; } };

      while (i < n) {
        const ch = src[i];
        if (!isRaw && ch === '\\') { buf += src[i] + (src[i + 1] ?? ''); i += 2; continue; }

        if (!isRaw && ch === '$' && src[i + 1] === '{') {
          flush();
          const es = i + 2;
          let depth = 1;
          i += 2;
          while (i < n && depth > 0) {
            const d = src[i];
            if (d === '{') { depth++; i++; continue; }
            if (d === '}') { depth--; if (depth === 0) break; i++; continue; }
            if (d === "'" || d === '"') {
              const iq = d;
              i++;
              while (i < n && src[i] !== iq) { if (src[i] === '\\') i++; i++; }
              i++;
              continue;
            }
            i++;
          }
          segments.push({ type: 'interp', expr: src.slice(es, i) });
          i++; // 吃掉 }
          continue;
        }
        if (!isRaw && ch === '$' && IDENT_START.test(src[i + 1] || '')) {
          flush();
          const es = i + 1;
          let j = es;
          while (j < n && /[A-Za-z0-9_]/.test(src[j])) j++;
          segments.push({ type: 'interp', expr: src.slice(es, j) });
          i = j;
          continue;
        }
        if (!isRaw && ch === '$') { buf += '$'; i++; continue; }

        if (triple) {
          if (ch === q && src[i + 1] === q && src[i + 2] === q) { i += 3; closed = true; break; }
        } else if (ch === q) { i++; closed = true; break; }

        buf += ch;
        i++;
      }
      flush();

      const raw = src.slice(start, i);
      const inner = closed
        ? raw.slice(openLen, raw.length - (triple ? 3 : 1))
        : raw.slice(openLen);

      out.push({ start, end: i, raw, inner, segments, isRaw, quote: q, triple, closed });
      continue;
    }

    i++;
  }
  return out;
}

function isTrivia(s) {
  let i = 0;
  while (i < s.length) {
    if (/\s/.test(s[i])) { i++; continue; }
    if (s[i] === '/' && s[i + 1] === '/') { while (i < s.length && s[i] !== '\n') i++; continue; }
    if (s[i] === '/' && s[i + 1] === '*') {
      let d = 1; i += 2;
      while (i < s.length && d > 0) {
        if (s[i] === '/' && s[i + 1] === '*') { d++; i += 2; }
        else if (s[i] === '*' && s[i + 1] === '/') { d--; i += 2; }
        else i++;
      }
      continue;
    }
    return false;
  }
  return true;
}

/**
 * 相邻字面量合成一组（Dart 编译期会拼起来）。
 * 拆开包 `tr()` 会把一句话断成两半，所以必须先合成整句。
 */
export function groupAdjacent(src, strs) {
  const groups = [];
  let cur = null;
  for (const s of strs) {
    if (cur && isTrivia(src.slice(cur.end, s.start))) {
      cur.parts.push(s);
      cur.end = s.end;
      cur.segments.push(...s.segments);
      cur.inner += s.inner;
    } else {
      if (cur) groups.push(cur);
      cur = { start: s.start, end: s.end, parts: [s], segments: [...s.segments], inner: s.inner };
    }
  }
  if (cur) groups.push(cur);
  return groups;
}

/**
 * 一组字面量 → 翻译用的 key（插值转 `{0}`）+ 实参表达式。
 * 注意 key 是**源码级**文本（保留 `\n` 这类转义），表里的 key 必须逐字相同。
 */
export function toKey(group) {
  const args = [];
  let key = '';
  for (const seg of group.segments) {
    if (seg.type === 'text') key += seg.text;
    else { key += `{${args.length}}`; args.push(seg.expr); }
  }
  return { key, args };
}

/** 扫描一个文件，返回待翻译的组 */
export function scanFile(file) {
  const src = fs.readFileSync(file, 'utf8');
  const groups = groupAdjacent(src, scanStrings(src));
  const res = [];
  for (const g of groups) {
    const { key, args } = toKey(g);
    if (!CN.test(key)) continue;
    if (shouldSkip(file, key)) continue;
    // 已经被 tr() 包过的跳过 —— 有这一步脚本才能重复跑（否则第二次会包成
    // `context.tr(context.tr('设置'))`，而那是能编译通过的，肉眼极难发现）。
    const before = src.slice(Math.max(0, g.start - 24), g.start);
    if (/(?:context\.)?tr\(\s*$/.test(before)) continue;
    const line = src.slice(0, g.start).split('\n').length;
    res.push({ file, start: g.start, end: g.end, key, args, line });
  }
  return res;
}

export function walkDart(dir, acc = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walkDart(p, acc);
    else if (e.name.endsWith('.dart')) acc.push(p);
  }
  return acc;
}

export function collect(root) {
  const files = walkDart(root).filter((f) => !f.includes(`${path.sep}i18n${path.sep}`));
  return files.flatMap(scanFile);
}

// ── CLI
const isMain = process.argv[1] && import.meta.url.endsWith(path.basename(process.argv[1]));
if (isMain) {
  const cmd = process.argv[2] || 'report';
  const root = process.argv[3] || 'lib';
  const all = collect(root);

  if (cmd === 'list') {
    const uniq = [...new Set(all.map((x) => x.key))].sort();
    for (const u of uniq) console.log(u);
    process.exit(0);
  }

  const uniq = [...new Set(all.map((x) => x.key))];
  const withVar = uniq.filter((t) => /\{\d+\}/.test(t) || /\$/.test(t));
  console.log(`命中 ${all.length} 处 · 唯一串 ${uniq.length} · 含占位符 ${withVar.length}`);
  const byFile = {};
  for (const a of all) byFile[a.file] = (byFile[a.file] || 0) + 1;
  console.log('\n每个文件：');
  for (const [f, c] of Object.entries(byFile).sort((a, b) => b[1] - a[1])) {
    console.log(`  ${String(c).padStart(4)}  ${f}`);
  }
  fs.writeFileSync('/tmp/i18n-uniq.json', JSON.stringify(uniq, null, 1));
  fs.writeFileSync('/tmp/i18n-all.json', JSON.stringify(all, null, 1));
  console.log('\n已写出 /tmp/i18n-uniq.json、/tmp/i18n-all.json');
}
