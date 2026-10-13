---
name: data-analysis
description: "CSV/JSON/表格 → 结论、关键数字、图表、报告"
---

# 数据分析与可视化

本技能负责：把工作区里的数据文件变成「结论 + 关键数字 + 图」。
什么时候用：用户说「分析一下这份数据 / 看看趋势 / 做个图表 / 这批数据说明什么」。

产物固定两份（都落在工作区）：
- `分析报告.md`：结论、关键数字、口径说明、数据局限
- `图表.html`：**离线自包含**的 HTML（内联 `<svg>`/`<canvas>` + 内联脚本，**不引用任何外部 CDN/网络资源**）

## 0. 先看清数据，再一次问完
```sh
node -e "const t=require('node:fs').readFileSync('数据.csv','utf8').split(/\r?\n/);console.log('行数',t.length);console.log(t.slice(0,6).join('\n'))"
```
把表头和前几行给用户看，一次问清：列的含义、单位、时间列是哪一列、要不要过滤某段时间、
「好」的判定标准是什么。**别一列一列地来回问。**

## 1. 写一个真的会算的脚本 analyze.mjs
用**写文件工具**建 `analyze.mjs`。只能用 node 内置模块。把「读入 → 解析 → 计算 → 写两份产物」
全放进脚本里，**不要心算**，也不要只把数据丢给模型口算。

下面两段都放进**同一个** `analyze.mjs`（第 2 段的 `barSvg` 是自包含函数，直接接在第 1 段后面），
并且把代码里的 `'数据.csv'` 换成用户给的真实文件名。CSV 解析（够用的最小实现，处理引号与逗号）：
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
  return rows.filter((r) => r.some((v) => v !== ''));
}
const rows = parseCsv(readFileSync('数据.csv', 'utf8'));
const head = rows[0], data = rows.slice(1).map((r) => Object.fromEntries(head.map((h, i) => [h, r[i] ?? ''])));
```

必算的统计量（按列类型分别走）：
- 数值列：个数、求和、均值、中位数、最小/最大、缺失个数。
- 类别列：取值个数、Top 5 及其占比。
- 日期列：按天/周/月分组计数或求和（`String.slice` 或 `new Date()` 都行，注意时区别纠结，口径写进报告）。

## 2. 生成图表 HTML（离线，不能引 CDN）
最简单的路径是**直接拼 SVG 字符串**，不依赖任何图表库：

```js
function barSvg(items, w = 640, h = 320) {
  const max = Math.max(...items.map((d) => d.value)) || 1;
  const bw = Math.floor((w - 80) / items.length);
  const bars = items.map((d, i) => {
    const bh = Math.round((d.value / max) * (h - 80));
    const x = 60 + i * bw, y = h - 40 - bh;
    return `<rect x="${x}" y="${y}" width="${bw - 12}" height="${bh}" fill="#4a7cff"/>` +
           `<text x="${x + (bw - 12) / 2}" y="${h - 22}" font-size="12" text-anchor="middle">${d.label}</text>` +
           `<text x="${x + (bw - 12) / 2}" y="${y - 6}" font-size="12" text-anchor="middle">${d.value}</text>`;
  }).join('');
  return `<svg viewBox="0 0 ${w} ${h}" width="100%" xmlns="http://www.w3.org/2000/svg">${bars}</svg>`;
}
```
- 折线图同理：把数据点换算成 `<polyline points="...">`。
- 页面里只写内联 `<style>` 和 `<svg>`，**不要**出现 `http://` / `https://` 的 script/link 引用——
  手机可能没网，引外链等于图表空白。
- 写完后自检：
```sh
node -e "const h=require('node:fs').readFileSync('图表.html','utf8');console.log('字节',h.length,'外部引用',/https?:\/\//.test(h.replace(/xmlns=\"[^\"]+\"/g,''))?'有(要删)':'无')"
```

## 3. 写报告
`分析报告.md` 结构：
1. 一句话结论（最重要的那个数）
2. 关键数字表（指标 / 数值 / 口径）
3. 数据质量：总行数、缺失、异常值、明显的重复
4. 局限与不确定：样本范围、口径假设、不能从数据推出的结论

## 4. 交付
回复里给两份**路径原样**，并把 3–5 个关键数字直接写在回复里。

## 诚实约束
- 数字一律来自脚本输出，**不要估算、不要编造**；口径不确定就在报告里标注。
- 文件读不到、编码乱码、JSON 解析失败，就把**真实报错**贴出来。
- 这台设备上没有 python / pandas / R / jq，也不能 npm install；只能 node 内置模块。
  用户给的是 `.xlsx` 时**先试着直接读**（本机有 `read-xlsx.mjs`，不用麻烦他另存为）：
  ```sh
  node "$DSH_ANDROID_TOOLBOX/read-xlsx.mjs" 表.xlsx --format csv --out 表.csv
  ```
  读不了（文件是加密的、或是老式 `.xls`）才请他另存为 CSV 或粘贴内容。
  要**交付表格**时给真 `.xlsx`（`make-xlsx.mjs`），别只给 CSV。
- 没有可靠的联网抓取能力：不要试图去网上取数据，需要外部数据就请用户提供文件。
