// Build the expert-catalog asset used by the mobile app.
//
// SOURCE OF TRUTH: the real "The Agency" expert roster that ships with the DSH
// plugin `@michengai/dsh-agency-agents` (Apache-2.0). We parse its Chinese
// asset tree (`assets/agency-agents-zh/<division>/<slug>.md`) and emit a compact
// JSON snapshot. Nothing here is invented: every name/description/brief below
// comes from the plugin's own Markdown frontmatter and body.
//
// Usage:
//   node install/build-expert-catalog.mjs [pluginRoot] [outFile]
//
// Defaults assume this machine's DSH web profile install location.

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const DEFAULT_PLUGIN_ROOT =
  'C:\\Users\\25894\\AppData\\Roaming\\PaopaocatDSH\\profiles\\web\\node_modules\\@michengai\\dsh-agency-agents';

const pluginRoot = process.argv[2] || DEFAULT_PLUGIN_ROOT;
const outFile =
  process.argv[3] ||
  path.join(process.cwd(), 'app', 'assets', 'experts', 'agency_catalog.json');

// Chinese division labels copied from the plugin source (`ZH_DIVISION` in
// lib/src-*.js). Kept in the plugin's own order so the UI can present the same
// ordering the plugin does.
const ZH_DIVISION = {
  academic: '学术',
  company: '公司经营',
  design: '设计',
  engineering: '工程',
  finance: '金融',
  'game-development': '游戏开发',
  gis: '地理信息',
  healthcare: '医疗健康',
  hr: '人力资源',
  legal: '法务',
  marketing: '市场营销',
  'paid-media': '付费媒体',
  product: '产品',
  'project-management': '项目管理',
  research: '研究',
  sales: '销售',
  security: '安全',
  'spatial-computing': '空间计算',
  specialized: '专业',
  support: '支持',
  'supply-chain': '供应链',
  testing: '测试',
};

const DIVISION_ORDER = Object.keys(ZH_DIVISION);
const BRIEF_MAX = 420;

function fail(message) {
  console.error(`[catalog] ${message}`);
  process.exit(1);
}

if (!fs.existsSync(pluginRoot)) fail(`plugin root not found: ${pluginRoot}`);

const zhRoot = path.join(pluginRoot, 'assets', 'agency-agents-zh');
if (!fs.existsSync(zhRoot)) fail(`zh asset root not found: ${zhRoot}`);

const pkg = JSON.parse(fs.readFileSync(path.join(pluginRoot, 'package.json'), 'utf8'));

/** Parse the tiny YAML frontmatter the agency files use (flat scalar keys only). */
function parseFrontmatter(text) {
  const norm = text.replace(/^\uFEFF/, '');
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(norm);
  if (!m) return { meta: {}, body: norm };
  const meta = {};
  for (const rawLine of m[1].split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const i = line.indexOf(':');
    if (i < 0) continue;
    const key = line.slice(0, i).trim();
    let value = line.slice(i + 1).trim();
    // strip matching quotes; keep the rest verbatim
    if (
      (value.startsWith('"') && value.endsWith('"') && value.length > 1) ||
      (value.startsWith("'") && value.endsWith("'") && value.length > 1)
    ) {
      value = value.slice(1, -1);
    }
    meta[key] = value;
  }
  return { meta, body: norm.slice(m[0].length) };
}

/** Pull one `## <heading>` section out of the persona body. */
function section(body, headingIncludes) {
  const lines = body.split(/\r?\n/);
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (/^##\s+/.test(l) && l.includes(headingIncludes)) {
      start = i + 1;
      break;
    }
  }
  if (start < 0) return '';
  const out = [];
  for (let i = start; i < lines.length; i++) {
    if (/^##\s+/.test(lines[i])) break;
    out.push(lines[i]);
  }
  return out.join('\n').trim();
}

/** Compact "what this expert actually does" text for system-prompt injection. */
function makeBrief(body) {
  let text = section(body, '核心使命') || section(body, '核心职责') || section(body, '角色定位');
  if (!text) {
    // Fallback: everything after the leading H1, minus headings/emoji noise.
    text = body
      .split(/\r?\n/)
      .filter((l) => !/^#\s+/.test(l))
      .join('\n')
      .trim();
  }
  text = text
    .replace(/^[-*]\s+/gm, '· ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  if (text.length > BRIEF_MAX) text = `${text.slice(0, BRIEF_MAX - 1)}…`;
  return text;
}

const divisions = [];
const experts = [];

for (const division of DIVISION_ORDER) {
  const dir = path.join(zhRoot, division);
  if (!fs.existsSync(dir)) continue;
  const files = fs
    .readdirSync(dir)
    .filter((f) => f.toLowerCase().endsWith('.md'))
    .sort();
  let kept = 0;
  for (const file of files) {
    const slug = file.replace(/\.md$/i, '');
    const text = fs.readFileSync(path.join(dir, file), 'utf8');
    const { meta, body } = parseFrontmatter(text);
    const name = (meta.name || slug).trim();
    const description = (meta.description || '').trim();
    if (!name || !description) continue; // skip README/index files without real metadata
    experts.push({
      slug,
      division,
      name,
      description,
      emoji: (meta.emoji || '').trim(),
      color: (meta.color || '').trim(),
      brief: makeBrief(body),
    });
    kept++;
  }
  if (kept > 0) divisions.push({ slug: division, name: ZH_DIVISION[division], count: kept });
}

if (experts.length === 0) fail('no experts parsed');

const catalog = {
  source: {
    package: pkg.name,
    version: pkg.version,
    license: pkg.license || 'Apache-2.0',
    repository: (pkg.repository && pkg.repository.url) || '',
    assetRoot: 'assets/agency-agents-zh',
    snapshotAt: new Date().toISOString().slice(0, 10),
    note:
      '内置快照：由 install/build-expert-catalog.mjs 从本机已安装的 DSH 插件 ' +
      '@michengai/dsh-agency-agents 的中文资产目录解析而来（名称/简介/摘要均为插件原文）。' +
      '手机运行时并不包含该插件，因此本 App 的专家开关不经过该插件的召唤引擎，' +
      '而是把已开启专家的摘要写入 $DSH_HOME/AGENTS.md（DSH 内置 agent-instructions 通道）。',
  },
  divisions,
  experts,
};

fs.mkdirSync(path.dirname(outFile), { recursive: true });
const json = JSON.stringify(catalog);
fs.writeFileSync(outFile, json, 'utf8');

const sha = createHash('sha256').update(fs.readFileSync(outFile)).digest('hex').toUpperCase();
console.log(`[catalog] plugin      : ${pkg.name}@${pkg.version}`);
console.log(`[catalog] divisions   : ${divisions.length}`);
console.log(`[catalog] experts     : ${experts.length}`);
console.log(`[catalog] out         : ${outFile}`);
console.log(`[catalog] bytes       : ${json.length}`);
console.log(`[catalog] sha256      : ${sha}`);
