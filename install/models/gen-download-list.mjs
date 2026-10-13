#!/usr/bin/env node
/**
 * 从「随包模型清单」生成**可在另一台机器上直接用的下载清单**。
 *
 * 为什么要有它：手机上下 1–3 GB 不现实，实际做法是"在电脑/服务器上下好，再传进手机"。
 * 那就必须给出：精确文件名、精确字节数、以及每个模型的所有可用源（含国内快源）。
 *
 * 用法：
 *   node install/models/gen-download-list.mjs
 * 产出（默认写到仓库外的工作区根，方便直接拿走）：
 *   <out>/端侧模型-下载清单.md    人看的：表格 + 全部直链
 *   <out>/端侧模型-aria2.txt      aria2c -i 用的输入文件（自带断点续传/多线程）
 *   <out>/端侧模型-urls.txt       纯 URL，一行一个（wget/curl/迅雷都能吃）
 *
 * 之后在下载目录里跑 `node install/models/hash-models.mjs <目录>`，
 * 把算出来的 sha256 回填进清单 —— 手机端导入时就会逐字节校验。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const MANIFEST = path.join(REPO, 'app/assets/models/model_manifest.json');
const OUT = process.env.OUT_DIR || path.resolve(REPO, '..'); // 默认 /root/办公
const onlyId = process.argv[2]; // 可选：只导出某个 id

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const models = manifest.models.filter((m) => !onlyId || m.id === onlyId);
if (models.length === 0) {
  console.error(`清单里没有匹配的模型${onlyId ? `：${onlyId}` : ''}`);
  process.exit(1);
}

const mb = (n) => `${(n / 1048576).toFixed(1)} MB`;
const kindZh = { text: '文本', vision: '多模态', image: '生图', video: '生视频' };

// ---- 人看的清单 ----
const lines = [];
lines.push('# 端侧模型 · 下载清单');
lines.push('');
lines.push(`> 从 \`app/assets/models/model_manifest.json\` 生成（清单版本 ${manifest.version}，更新于 ${manifest.updatedAt}）。`);
lines.push('> 下载完把文件放进同一个目录，文件名**不要改** —— 手机端按"文件名 + 字节数"匹配，改名就认不出。');
lines.push('');
lines.push('| 模型 | 用途 | 引擎/格式 | 大小 | 文件名 | sha256 |');
lines.push('|---|---|---|---|---|---|');
for (const m of models) {
  lines.push(
    `| ${m.name} | ${kindZh[m.kind] || m.kind} | ${m.engine} / ${m.format} (${m.quant}) | ${mb(m.bytes)} | \`${m.fileName}\` | ${m.sha256 ? '`' + m.sha256.slice(0, 12) + '…`' : '**待回填**'} |`,
  );
}
lines.push('');
lines.push('---');
lines.push('');
lines.push('## 直链（每个模型按推荐顺序列出）');
lines.push('');
for (const m of models) {
  lines.push(`### ${m.name}`);
  lines.push('');
  lines.push(`- 文件名：\`${m.fileName}\``);
  lines.push(`- 精确大小：**${m.bytes} 字节**（${mb(m.bytes)}）`);
  lines.push(`- 许可：${m.license}　最低内存：${m.minRamGb} GB${m.socMatch?.length ? `　机型专属：${m.socMatch.join(' / ')}` : ''}`);
  if (m.note) lines.push(`- 说明：${m.note}`);
  lines.push('');
  const sorted = [...m.sources].sort((a, b) => a.priority - b.priority);
  for (const s of sorted) {
    lines.push(`${s.priority === 0 ? '🥇' : s.priority === 1 ? '🥈' : '🥉'} **${s.label}**`);
    lines.push('');
    lines.push('```');
    lines.push(s.url);
    lines.push('```');
    lines.push('');
  }
}
lines.push('## 一次性全下（推荐）');
lines.push('');
lines.push('在下载目录里这样跑，自带断点续传 + 多线程，失败重跑不会从头来：');
lines.push('');
lines.push('```bash');
lines.push('# 只用国内快源（ModelScope 优先，实测 4.4–5.0 MB/s）');
lines.push(`aria2c -i ${path.basename(path.join(OUT, '端侧模型-aria2.txt'))} -c -x4 -s4 -j3 \\`);
lines.push('  --file-allocation=none --console-log-level=warn');
lines.push('');
lines.push('# 或者一条条来（把 URL 换成清单里的）');
lines.push('curl -L -C - -o <文件名> "<URL>"');
lines.push('```');
lines.push('');
lines.push('下完在**同一个目录**里跑一次哈希回填脚本，生成可校验数据：');
lines.push('');
lines.push('```bash');
lines.push('node install/models/hash-models.mjs .   # 输出 sha256 结果，粘回清单即可');
lines.push('```');
lines.push('');
lines.push('## 体积参考（全下）');
lines.push('');
const total = models.reduce((a, m) => a + m.bytes, 0);
lines.push(`- 全部 ${models.length} 个：**${mb(total)}**（${(total / 1073741824).toFixed(2)} GB）`);
lines.push(`- 只下"能用"的推荐档（Qwen2.5-1.5B + SD1.5 + Wan2.1-1.3B）：约 **${mb(models.filter((m) => ['qwen2.5-1.5b-instruct-q4_k_m', 'sd15-q4_0', 'wan2.1-t2v-1.3b-q3_k_s'].includes(m.id)).reduce((a, m) => a + m.bytes, 0))}**`);
lines.push('');

const mdPath = path.join(OUT, '端侧模型-下载清单.md');
fs.writeFileSync(mdPath, lines.join('\n'));

// ---- aria2c 输入：只收优先级最高的那个源（避免下重复）----
const aria = [];
for (const m of models) {
  const best = [...m.sources].sort((a, b) => a.priority - b.priority)[0];
  aria.push(best.url);
  aria.push(`  dir=.`);
  aria.push(`  out=${m.fileName}`);
}
fs.writeFileSync(path.join(OUT, '端侧模型-aria2.txt'), aria.join('\n') + '\n');

// ---- 纯 URL ----
const urls = models.map((m) => [...m.sources].sort((a, b) => a.priority - b.priority)[0].url);
fs.writeFileSync(path.join(OUT, '端侧模型-urls.txt'), urls.join('\n') + '\n');

console.log(`✅ 生成完毕（${models.length} 个模型，合计 ${mb(total)}）：`);
console.log(`   ${mdPath}`);
console.log(`   ${path.join(OUT, '端侧模型-aria2.txt')}`);
console.log(`   ${path.join(OUT, '端侧模型-urls.txt')}`);
