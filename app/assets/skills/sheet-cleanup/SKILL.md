---
name: sheet-cleanup
description: "CSV 去重、统一格式、补字段、分组汇总"
---

# 表格整理

本技能负责：把一份脏 CSV（或用制表符分隔的表）清洗成能用的表，并给出改了什么。
什么时候用：用户说「这表太乱 / 帮我合并去重 / 手机号格式统一一下 / 按城市汇总一下 / 去掉空行」。

产物（原文件**绝不动**，全部另存新文件）：
- `clean-<原名>.csv`：清洗后的表
- `清洗说明.md`：改了什么、每列含义、剩下的可疑数据
- `图表.html`（可选，要汇总对比时给）：离线自包含的内联 SVG

## 0. 先看清表，再一次问完关键问题
```sh
node -e "const t=require('node:fs').readFileSync('表.csv','utf8').split(/\r?\n/);console.log('总行数',t.length);console.log(t.slice(0,8).join('\n'))"
```
一次问清：**每列含义与单位**、哪列是唯一标识（去重按哪列）、日期格式目标是哪种、
金额/数量要不要合并求和、空值怎么处理（留空还是填 `-`）。

## 1. 写清洗脚本 clean.mjs
用**写文件工具**建 `clean.mjs`，用 node 内置模块读写；把规则写成**代码里的显式配置**，
方便用户之后自己改。**不要**用 `sed -i` / `awk` 原地改表。

CSV 解析与写回（最小可靠实现）：
```js
import { readFileSync, writeFileSync } from 'node:fs';
function parseCsv(text) {
  const rows = []; let row = [], cell = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"' && text[i + 1] === '"') { cell += '"'; i++; }
      else if (c === '"') q = false;
      else cell += c;
    } else if (c === '"') q = true;
    else if (c === ',') { row.push(cell); cell = ''; }
    else if (c === '\n') { row.push(cell); rows.push(row); row = []; cell = ''; }
    else if (c !== '\r') cell += c;
  }
  if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
  return rows.filter((r) => r.some((v) => v.trim() !== ''));
}
function toCsv(rows) {
  return rows.map((r) => r.map((v) => {
    const s = String(v ?? '');
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }).join(',')).join('\n') + '\n';
}

// 读入并转成「对象数组」（表头去空格，值先 trim）——后面所有清洗都改 data
const rows = parseCsv(readFileSync('表.csv', 'utf8'));
const head = rows[0].map((h) => h.trim());
const data = rows.slice(1).map((r) => Object.fromEntries(head.map((h, i) => [h, (r[i] ?? '').trim()])));
console.log('读入', data.length, '行；列：', head.join(' / '));

// 清洗完成后写回（data 是对象数组，按表头顺序取回；文件名换成 clean-<原名>.csv）
// writeFileSync('clean-表.csv', toCsv([head, ...data.map((o) => head.map((h) => o[h]))]));
```
把 `'表.csv'` 换成用户给的真实文件名。清洗动作按这个顺序做，每步都记数（写进说明文件）：
1. 去空行、去完全重复的行（记：删了几行）。
2. 每个单元格 `trim`、全角空格与全角数字转半角、连续空格压成一个。
3. 去重：按用户指定的唯一标识列去重，保留**后出现**的那条（保留哪条要问清，记：删了几条、保留了几条）。
4. 规范格式：日期统一 `YYYY-MM-DD`；手机号去掉空格与 `-`；金额去掉 `¥`、`元`、千分位逗号后转数字。
5. 补算列（用户要时）：分组汇总、行内求和、占比。
6. 校验：明显异常的行（日期早于 1990、数字列出现文字）单独列进说明文件，**不要静默删掉**。

## 2. 分组汇总与图（用户要时）
把这两个**自包含函数**追加进 `clean.mjs`，调用时把两个列名换成表里的真实列名：

```js
// 把 '1,200.50 元' / '138-0000-0001' 这类文本凑成数字（只留数字、小数点与开头的负号）
function toNum(s) {
  const t = String(s).trim().replace(/[^0-9.\-]/g, '');
  return Number(t.replace(/(?!^)-/g, '')) || 0;
}
// data 是第 1 步的对象数组；keyCol 分组列，valCol 求和列（必须是数值列）
function groupSum(data, keyCol, valCol) {
  const byKey = new Map();
  for (const r of data) {
    const k = r[keyCol] || '(空)';
    byKey.set(k, (byKey.get(k) || 0) + toNum(r[valCol]));
  }
  return [...byKey].map(([label, value]) => ({ label, value })).sort((a, b) => b.value - a.value);
}
// 用法示例（别照抄这一行：列名换成真实列名，data 换成你清洗后的数组）
// const items = groupSum(recs, '城市', '金额');
```
**别拿手机号、订单号这类列去求和**：它们没有数值含义，求出来是没意义的大数（`toNum` 之所以能处理
`138-0000-0001` 只是不想让分隔符把数字变成 0）。汇总列不确定是哪一个，就先问用户。

把 `items` 拼成内联 SVG 柱状图写进 `图表.html`：只允许内联 `<style>` 与 `<svg>`，**不要出现任何 `http://` / `https://` 的 script、link、图片引用**（手机可能没网，外链会空白）。

## 3. 自检
```sh
node clean.mjs
node -e "const t=require('node:fs').readFileSync('clean-表.csv','utf8').split(/\r?\n/);console.log('清洗后行数',t.length);console.log(t.slice(0,4).join('\n'))"
```
行数对不上预期的差距，要在说明里解释清楚（例如「删掉 12 条重复、3 条空行」）。

## 4. 交付
回复里给：原行数 → 清洗后行数、删改条数、**产物路径原样**、1–3 个汇总后的关键数字。

## 诚实约束
- 数字全部来自脚本输出，**不要心算、不要估**；逻辑不清就先问，别猜列的含义。
- 脚本报错（列名不存在、行长度不齐）就把**真实报错**贴出来并指出是哪一列的问题。
- 这台设备上**没有** python / pandas / Excel / libreoffice —— 但 **`.xlsx` 现在能直接读**：
  它是 ZIP + XML，随包带了 `read-xlsx.mjs`（纯 node）。先直接读，**不要**一上来就让用户另存为 CSV：
  ```sh
  node "$DSH_ANDROID_TOOLBOX/read-xlsx.mjs" 表.xlsx --format csv --out 表.csv
  ```
  处理完要交付时，用 `make-xlsx.mjs` 把它写回真 `.xlsx`（用户拿到的是能直接打开的表格）。
  如实说明边界：不解析公式、日期会显示成序列号、不读合并单元格。
- 不要为了「让结果好看」而悄悄丢弃数据；所有删除都要在说明文件里计数。
