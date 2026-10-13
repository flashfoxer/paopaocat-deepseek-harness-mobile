#!/usr/bin/env node
// 把翻译结果写成 Dart const 表。
//
// 转义规则必须与源码侧一致：
//   · key 是**源码级**文本（从字面量里原样取出）——但注意：**三引号字面量里的
//     换行在源码里就是真实换行**，不是 `\n` 两个字符，必须转义掉；否则生成的字面量
//     会真的跨行，一个这样的 key 就能让整张表报上千个语法错误（第一版正是如此）；
//   · value 是译者给的**真实文本**（可能含真换行）—— 一律转成 Dart 转义。
// 两边都包单引号，运行时得到的字符串就与代码里 tr('...') 的实参一致。
import fs from 'node:fs';

const keys = JSON.parse(fs.readFileSync('/tmp/i18n-keys.json', 'utf8'));
const items = [];
for (let i = 0; i < 10; i++) {
  const p = `/tmp/i18n-out/chunk-${String(i).padStart(2, '0')}.json`;
  items.push(...JSON.parse(fs.readFileSync(p, 'utf8')).items);
}
const byKey = new Map(items.map((it) => [it.key, it]));

/** 源码级内容 → Dart 单引号字面量 */
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

/** 真实文本 → Dart 单引号字面量 */
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

const spec = [
  { field: 'en', table: 'kEnTable', file: 'en_table_data.dart', part: 'en_table.dart', name: '英语' },
  { field: 'ja', table: 'kJaTable', file: 'ja_table_data.dart', part: 'ja_table.dart', name: '日语' },
  { field: 'ko', table: 'kKoTable', file: 'ko_table_data.dart', part: 'ko_table.dart', name: '韩语' },
];

for (const s of spec) {
  const lines = keys.map((k) => {
    const it = byKey.get(k);
    if (!it) throw new Error(`缺翻译：${k}`);
    return `  ${litSourceLevel(k)}: ${litPlain(it[s.field])},`;
  });
  const body = `part of '${s.part}';\n\n/// key = 中文原文（与源码逐字一致），value = ${s.name}。\n///\n/// 由 install/i18n/gen-tables.mjs 生成，可手改（改完跑 check-tables 复核）。\nconst Map<String, String> ${s.table} = <String, String>{\n${lines.join('\n')}\n};\n`;
  fs.writeFileSync(`/root/办公/dsh-mobile/app/lib/i18n/tables/${s.file}`, body);
  console.log(`${s.file}  ${keys.length} 条  ${(body.length / 1024).toFixed(0)} KB`);
}
