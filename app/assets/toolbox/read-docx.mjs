/**
 * read-docx.mjs —— 读**真正的 `.docx`**，输出 Markdown / 纯文本 / JSON。
 *
 * ## 为什么要有它
 *
 * 0.71 先做了「写」的那一半（`make-docx.mjs`：Markdown → 真 .docx），
 * 内置技能里也如实写着「**读不了 .docx**，请把正文粘贴过来或另存为 .txt」——
 * 那条限制来自**手机上没有 python**。但 docx 的本质就是 **ZIP + XML**，
 * 而 node 自带 `node:zlib`，所以这条限制现在可以撤了（和 `read-xlsx.mjs` 同一个理由）。
 *
 * 它和 `make-docx.mjs` 是**一对**：那边写出来的东西，这边能原样读回来
 * （`test/office_docx_test.dart` 里有一条"往返一致"的测试钉住这件事）。
 *
 * ## 用法
 *
 *   node read-docx.mjs <输入.docx> [选项]
 *
 *   --format <md|txt|json>   输出格式，默认 md
 *   --out <路径>             写到文件（默认打到 stdout）
 *   --extract-images <目录>  把文档里的图片抽出来，并在 Markdown 里指向它们
 *
 * 成功标记：
 *   `[docx] ok op=read paragraphs=<段数> tables=<表数> images=<图数> out=<路径|->`
 *
 * ## 诚实边界（写清楚，别让下游以为它能干更多）
 *
 *   * **只读正文**（`word/document.xml`）：页眉 / 页脚 / 脚注 / 尾注 / 批注
 *     **不读**（那些在各自的部件里）。
 *   * **修订与批注**：`w:ins` / `w:del` 的原样文本会被读出来（不区分"这是删除的"）；
 *     批注锚点被忽略。
 *   * **图片默认不抽**，只在 Markdown 里留一行 HTML 注释标明"这里有一张图、
 *     它在包里的哪个路径"（渲染时看不见，但模型读得到，知道少了东西）。
 *     给了 `--extract-images` 才真写出来。
 *   * **文本框里的文字**（`w:txbxContent`）会按外面那一段一起读到，但**顺序可能与
 *     视觉位置不一致**（它是"段落里嵌的块"）。
 *   * **合并单元格**（`gridSpan`）会**按占位列补空**，`vMerge`（纵向合并）
 *     的续格按空处理 —— 也就是说表格形状保得住，但"哪些格是合并的"这个信息会丢。
 *   * **编号**：`bullet` 输出成 `- `，其余编号格式（罗马数字 / 字母 / 中文数字）
 *     一律按**顺序号**输出成 `1. 2. 3.`；有序列表的原始序号由 Word 算，
 *     所以读出来的是**顺序**，不是文件里写死的数字。
 *   * **代码块的语言标记**（```sh 里的 `sh`）不保留 —— docx 里没有它的位置。
 *   * **粗体/斜体/等宽**靠 `w:b` / `w:i` / 等宽字体名还原；等宽判断用的是一张
 *     常见等宽字体名清单（Consolas / Courier New / Menlo / monospace…），
 *     清单外的等宽字体会被当成普通文本。
 *   * 没有样式表的老文件：**加粗 + 字号 ≥ 26 半磅**会被当成标题（按字号猜层级）——
 *     这是**兜底**，不是标准；能认出样式时一律以样式为准。
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { xmlUnescape, zipRead } from './office-zip.mjs';

const HELP = `用法: node read-docx.mjs <输入.docx> [选项]

选项:
  --format <md|txt|json>   输出格式，默认 md
  --out <路径>             写到文件（默认打到 stdout）
  --extract-images <目录>  把文档里的图片抽出来（默认只在 Markdown 里标注位置）

读 .docx（ZIP + XML）的**正文**并输出 Markdown / 纯文本 / JSON。
不读页眉页脚、脚注、批注；合并单元格会被按列补空；代码块的语言标记不保留。
`;

function fail(message, code) {
  process.stderr.write(`错误：${message}\n`);
  process.exit(code === undefined ? 1 : code);
}

// ─────────────────────────────────────────────────────────── 小工具

/** 取一个标签串里的属性值（`<w:ind w:left="720"/>` → 720）。 */
function attr(tag, name) {
  const m = new RegExp(`\\b${name.replace(':', ':')}="([^"]*)"`).exec(tag);
  return m ? xmlUnescape(m[1]) : '';
}

/**
 * OOXML 的"开关型"属性：`<w:b/>` 是开，`<w:b w:val="0"/>` 是**显式关**。
 *
 * ⚠️ 显式关必须认：Word 存"在加粗样式里取消加粗"就是这么写的（`w:val="0"`），
 *    只判断"标签在不在"会把这类 run 全读成加粗。
 */
function toggleOn(tag) {
  const val = attr(tag, 'w:val');
  if (val === '') return true;
  return !['0', 'false', 'off'].includes(val.toLowerCase());
}

const MONO_FONTS = [
  'consolas', 'courier new', 'courier', 'monospace', 'menlo', 'monaco',
  'sfmono', 'fira code', 'jetbrains mono', 'dejavu sans mono', 'source code pro',
  'lucida console', 'liberation mono', 'cascadia mono', 'roboto mono',
];

function isMonoFonts(tag) {
  const fonts = (attr(tag, 'w:ascii') + ' ' + attr(tag, 'w:hAnsi') + ' '
    + attr(tag, 'w:cs') + ' ' + attr(tag, 'w:eastAsia')).toLowerCase();
  return MONO_FONTS.some((f) => fonts.includes(f));
}

/** 去掉所有标签，只留文字（单元格这种"不关心行内格式"的地方用）。 */
function textOnly(xml) {
  return xmlUnescape(String(xml).replace(/<[^>]*>/g, ''));
}

// ─────────────────────────────────────────────────────────── styles.xml

/**
 * 解析 `word/styles.xml` → `Map<styleId, {name, outlineLvl, basedOn}>`。
 *
 * 为什么要它：**标题是靠样式认的**（Word 写 `Heading1` + 名字 `heading 1` +
 * `outlineLvl 0`；WPS 可能写中文名 `标题 1`；Google Docs 导出又是另一种）。
 * 只认 `styleId` 字面量会漏掉一大片真实文件。
 */
export function parseStyles(xml) {
  const styles = new Map();
  if (!xml) return styles;
  const re = /<w:style\b([^>]*)>([\s\S]*?)<\/w:style>/g;
  let m;
  while ((m = re.exec(xml)) !== null) {
    const id = attr(m[1], 'w:styleId');
    if (!id) continue;
    const body = m[2];
    const nameTag = /<w:name\b[^>]*\/?>/.exec(body);
    const outline = /<w:outlineLvl\b[^>]*\/?>/.exec(body);
    styles.set(id, {
      name: nameTag ? attr(nameTag[0], 'w:val') : '',
      outlineLvl: outline ? Number(attr(outline[0], 'w:val')) : -1,
      basedOn: attr((/<w:basedOn\b[^>]*\/?>/.exec(body) || [''])[0], 'w:val'),
    });
  }
  return styles;
}

/** 样式 → 标题层级（1..9）；不是标题返回 0。 */
export function headingLevelOf(styleId, styles) {
  if (!styleId) return 0;
  const st = styles.get(styleId);
  // ① styleId 本身就叫 Heading1 / 标题1
  let m = /^(?:heading|标题)\s*([1-9])$/i.exec(styleId.replace(/[-_]?\d*$/, ''))
    || /^(?:Heading|标题)([1-9])$/i.exec(styleId);
  if (m) return Number(m[1]);
  if (!st) return 0;
  // ② 样式的显示名（Word 写 "heading 1"、WPS 写 "标题 1"、也可能是 "Titre 1" 之类）
  const name = (st.name || '').trim();
  m = /^(?:heading|标题|título|titulo|titre|überschrift)\s*([1-9])$/i.exec(name);
  if (m) return Number(m[1]);
  // ③ outlineLvl（0 起）= 真正的"大纲级别"，最可靠的一种
  if (st.outlineLvl >= 0 && st.outlineLvl < 9) return st.outlineLvl + 1;
  return 0;
}

// ─────────────────────────────────────────────────────────── numbering.xml

/**
 * 解析 `word/numbering.xml` → `Map<numId, {numFmtByLevel: Map<ilvl, numFmt>}>`。
 *
 * `w:num` 把 numId 指到一个 abstractNum；真正的格式在 abstractNum 的 `w:lvl` 里。
 * 段落里只写 `numId` + `ilvl`，所以要经过这两跳才知道是"项目符号"还是"数字"。
 */
export function parseNumbering(xml) {
  const byNumId = new Map();
  if (!xml) return byNumId;
  const abstracts = new Map();
  const absRe = /<w:abstractNum\b([^>]*)>([\s\S]*?)<\/w:abstractNum>/g;
  let m;
  while ((m = absRe.exec(xml)) !== null) {
    const id = attr(m[1], 'w:abstractNumId');
    const fmt = new Map();
    const lvlRe = /<w:lvl\b([^>]*)>([\s\S]*?)<\/w:lvl>/g;
    let lm;
    while ((lm = lvlRe.exec(m[2])) !== null) {
      const ilvl = Number(attr(lm[1], 'w:ilvl') || 0);
      const f = /<w:numFmt\b[^>]*\/?>/.exec(lm[2]);
      fmt.set(ilvl, f ? attr(f[0], 'w:val') : 'decimal');
    }
    abstracts.set(id, fmt);
  }
  const numRe = /<w:num\b([^>]*)>([\s\S]*?)<\/w:num>/g;
  while ((m = numRe.exec(xml)) !== null) {
    const numId = attr(m[1], 'w:numId');
    const ref = /<w:abstractNumId\b[^>]*\/?>/.exec(m[2]);
    const absId = ref ? attr(ref[0], 'w:val') : '';
    byNumId.set(numId, abstracts.get(absId) || new Map());
  }
  return byNumId;
}

// ─────────────────────────────────────────────────────────── 关系（超链接 / 图片）

/**
 * 解析 `word/_rels/document.xml.rels` → `Map<rId, {target, external}>`。
 *
 * 超链接的目标 URL 与图片的真实路径**都不在 document.xml 里**，只在关系文件里
 * （正文里只有一个 `r:id`）。所以想输出可点的链接、想抽图片，都必须读它。
 */
export function parseRels(xml) {
  const rels = new Map();
  if (!xml) return rels;
  const re = /<Relationship\b([^>]*)\/?>/g;
  let m;
  while ((m = re.exec(xml)) !== null) {
    rels.set(attr(m[1], 'Id'), {
      target: attr(m[1], 'Target'),
      external: attr(m[1], 'TargetMode') === 'External',
    });
  }
  return rels;
}

// ─────────────────────────────────────────────────────────── 行内

/**
 * 一个段落（或单元格）里的"run 序列" → 带格式的文字片段。
 *
 * 扫描而不是引 XML 库：`<w:r\b` 的 `\b` 让 `w:rPr` 不会误匹配（`P` 是词字符），
 * 而超链接是**包着 run 的**（`<w:hyperlink><w:r>…`），所以要单独跟踪它的边界。
 */
export function inlineSpans(xml, rels) {
  const spans = [];
  let link = null;
  const re = /<w:hyperlink\b([^>]*)>|<\/w:hyperlink>|<w:r\b[^>]*>([\s\S]*?)<\/w:r>|<w:r\b[^>]*\/>/g;
  let m;
  while ((m = re.exec(xml)) !== null) {
    const tag = m[0];
    if (tag.startsWith('<w:hyperlink')) {
      const rid = attr(m[1], 'r:id');
      const rel = rels.get(rid);
      // 只有外链才给 Markdown 链接；包内链接（书签/其它部件）没有可输出的 URL
      link = rel && rel.external ? rel.target : null;
      continue;
    }
    if (tag === '</w:hyperlink>') { link = null; continue; }

    const inner = m[2] || '';
    // 文字：多个 <w:t> 拼起来；<w:tab/> 当制表符；<w:br/> 当一个空格
    let text = '';
    const tRe = /<w:t\b[^>]*>([\s\S]*?)<\/w:t>|<w:tab\b[^>]*\/>|<w:br\b[^>]*\/>|<w:cr\b[^>]*\/>/g;
    let tm;
    while ((tm = tRe.exec(inner)) !== null) {
      if (tm[1] !== undefined) text += xmlUnescape(tm[1]);
      else if (tm[0].startsWith('<w:tab')) text += '\t';
      else text += ' ';
    }
    if (text === '') continue;

    const rPr = (/<w:rPr\b[^>]*>([\s\S]*?)<\/w:rPr>/.exec(inner) || [, ''])[1];
    const b = /<w:b\b[^>]*\/?>/.exec(rPr);
    const i = /<w:i\b[^>]*\/?>/.exec(rPr);
    const fonts = /<w:rFonts\b[^>]*\/?>/.exec(rPr);
    const sz = /<w:sz\b[^>]*\/?>/.exec(rPr);
    spans.push({
      text,
      bold: !!(b && toggleOn(b[0])),
      italic: !!(i && toggleOn(i[0])),
      mono: !!(fonts && isMonoFonts(fonts[0])),
      size: sz ? Number(attr(sz[0], 'w:val') || 0) : 0,
      link,
    });
  }
  return spans;
}

/** 把相邻的**同格式**片段合并（否则会输出 `**a****b**` 这种碎片）。 */
function mergeSpans(spans) {
  const out = [];
  for (const s of spans) {
    const last = out[out.length - 1];
    if (last && last.bold === s.bold && last.italic === s.italic
        && last.mono === s.mono && last.link === s.link) {
      last.text += s.text;
      last.size = Math.max(last.size, s.size);
      continue;
    }
    out.push({ ...s });
  }
  return out;
}

/** 片段 → Markdown 行内（`**粗**` / `*斜*` / `` `等宽` `` / `[文字](URL)`）。 */
export function spansToMarkdown(spans, { suppressAllBold = false } = {}) {
  const merged = mergeSpans(spans);
  const allBold = merged.length > 0 && merged.every((s) => s.bold || s.text.trim() === '');
  let out = '';
  for (const s of merged) {
    let t = s.text;
    // 标题靠样式就已经是粗体了，这里再套一层 `**` 会变成 `# **标题**`
    const bold = s.bold && !(suppressAllBold && allBold);
    if (s.mono) t = `\`${t}\``;
    if (s.italic) t = `*${t}*`;
    if (bold) t = `**${t}**`;
    if (s.link) t = `[${t}](${s.link})`;
    out += t;
  }
  return out;
}

/** 片段 → 纯文本（去掉所有标记）。 */
function spansToPlain(spans) {
  return mergeSpans(spans).map((s) => s.text).join('');
}

// ─────────────────────────────────────────────────────────── 块切分

/**
 * 把 `word/document.xml` 的 body 切成**顶层块**：`p`（段落）与 `tbl`（表格）。
 *
 * 为什么不能用一条正则扫 `<w:p>…</w:p>`：**表格里也有段落**（每个单元格里至少一个），
 * 直接扫会把单元格里的段落当成正文段落。所以这里先认 `<w:tbl>` 并**整块吃掉**
 * （含嵌套），再认段落。
 */
export function tokenizeBlocks(xml) {
  const blocks = [];
  let i = 0;
  while (i < xml.length) {
    const pIdx = xml.indexOf('<w:p', i);
    const tIdx = xml.indexOf('<w:tbl', i);
    let start = -1;
    let isTable = false;
    if (pIdx < 0 && tIdx < 0) break;
    if (tIdx >= 0 && (pIdx < 0 || tIdx < pIdx)) { start = tIdx; isTable = true; }
    else { start = pIdx; isTable = false; }

    // 标签必须真的结束在 `>`（`<w:pPr` / `<w:tblPr` 不算块开始）
    const gt = xml.indexOf('>', start);
    if (gt < 0) break;
    const head = xml.slice(start, gt + 1);
    if (!/^<w:(p|tbl)[\s/>]/.test(`${head}`) || /^<w:(pPr|tblPr|pStyle)/.test(head)) {
      i = gt + 1;
      continue;
    }

    const name = isTable ? 'w:tbl' : 'w:p';
    // 段落不会嵌套段落（`<w:p/>` 是空段落）；表格会嵌套（单元格里可能有表）
    let depth = 0;
    let j = start;
    let end = -1;
    const openRe = new RegExp(`<${name}\\b`, 'g');
    const closeRe = new RegExp(`</${name}>`, 'g');
    while (j < xml.length) {
      openRe.lastIndex = j;
      closeRe.lastIndex = j;
      const o = openRe.exec(xml);
      const c = closeRe.exec(xml);
      if (!c) break;
      if (o && o.index < c.index) { depth += 1; j = o.index + name.length + 1; continue; }
      depth -= 1;
      j = c.index + name.length + 3;
      if (depth === 0) { end = j; break; }
    }
    if (end < 0) end = xml.length;

    const raw = xml.slice(start, end);
    const gt2 = raw.indexOf('>');
    if (raw.slice(gt2 - 1, gt2 + 1) === '/>') {
      blocks.push({ type: isTable ? 'tbl' : 'p', inner: '' });
    } else {
      blocks.push({
        type: isTable ? 'tbl' : 'p',
        inner: raw.slice(gt2 + 1, raw.lastIndexOf(`</${name}>`)),
      });
    }
    i = end;
  }
  return blocks;
}

// ─────────────────────────────────────────────────────────── 段落 → 块

/** 取段落的 pPr（含 `numPr` / `pStyle` / `pBdr`）。 */
function pPrOf(inner) {
  return (/<w:pPr\b[^>]*>([\s\S]*?)<\/w:pPr>/.exec(inner) || [, ''])[1];
}

const QUOTE_STYLES = new Set(['quote', 'intensequote', 'blocktext', '引用', 'blockquote']);
const CODE_STYLES = new Set([
  'codeblock', 'code', 'sourcecode', 'htmlpreformatted', 'preformatted',
  'plaintext', '代码', '代码块',
]);

/**
 * 段落 → 结构化块（或 null：没有内容的段落被丢掉）。
 *
 * @param {object} ctx `{styles, numbering, rels, counters}`
 */
export function paragraphToBlock(inner, ctx) {
  const pPr = pPrOf(inner);
  const styleTag = /<w:pStyle\b[^>]*\/?>/.exec(pPr);
  const styleId = styleTag ? attr(styleTag[0], 'w:val') : '';
  const spans = inlineSpans(inner, ctx.rels);
  const text = spansToPlain(spans).trim();

  // 图片（在段落里）—— 记下包内路径，正文里留个记号
  const images = [];
  const imgRe = /<w:(?:drawing|pict)\b[\s\S]*?<\/w:(?:drawing|pict)>/g;
  let im;
  while ((im = imgRe.exec(inner)) !== null) {
    const embed = /r:(?:embed|link)="([^"]+)"/.exec(im[0]);
    if (!embed) continue;
    const rel = ctx.rels.get(embed[1]);
    if (rel && !rel.external) images.push(rel.target);
  }

  // ① 列表（编号）
  const numPr = /<w:numPr\b[^>]*>([\s\S]*?)<\/w:numPr>/.exec(pPr);
  if (numPr && text) {
    const ilvlTag = /<w:ilvl\b[^>]*\/?>/.exec(numPr[1]);
    const numIdTag = /<w:numId\b[^>]*\/?>/.exec(numPr[1]);
    const ilvl = ilvlTag ? Number(attr(ilvlTag[0], 'w:val') || 0) : 0;
    const numId = numIdTag ? attr(numIdTag[0], 'w:val') : '';
    const fmt = (ctx.numbering.get(numId) || new Map()).get(ilvl) || 'decimal';
    const ordered = fmt !== 'bullet';
    let n = 0;
    if (ordered) {
      const key = `${numId}:${ilvl}`;
      n = (ctx.counters.get(key) || 0) + 1;
      ctx.counters.set(key, n);
      // 回到浅层时，深层计数要重置（否则 1.1 之后回到 1 级会变成 2.）
      for (const k of [...ctx.counters.keys()]) {
        const [id, lv] = k.split(':');
        if (id === numId && Number(lv) > ilvl) ctx.counters.delete(k);
      }
    }
    return { type: 'list', ordered, level: ilvl, marker: ordered ? `${n}. ` : '- ', spans };
  }
  ctx.counters.clear();

  // ② 标题（样式优先；认不出才按"全粗 + 大字号"兜底）
  let level = headingLevelOf(styleId, ctx.styles);
  if (!level && spans.length) {
    const allBold = spans.every((s) => s.bold || s.text.trim() === '');
    const maxSize = spans.reduce((a, s) => Math.max(a, s.size), 0);
    if (allBold && maxSize >= 40) level = 1;
    else if (allBold && maxSize >= 32) level = 2;
    else if (allBold && maxSize >= 28) level = 3;
    else if (allBold && maxSize >= 26) level = 4;
  }
  if (level && text) return { type: 'heading', level, spans };

  // ③ 引用
  const styleName = (styleId || '').toLowerCase();
  const isQuoteStyle = QUOTE_STYLES.has(styleName)
    || (() => {
      const st = ctx.styles.get(styleId);
      return !!(st && QUOTE_STYLES.has((st.name || '').trim().toLowerCase()));
    })();
  const allItalic = spans.length > 0 && spans.every((s) => s.italic || s.text.trim() === '');
  if (text && (isQuoteStyle || (allItalic && /<w:ind\b/.test(pPr)))) {
    return { type: 'quote', spans };
  }

  // ④ 代码块
  const isCodeStyle = CODE_STYLES.has(styleName)
    || (() => {
      const st = ctx.styles.get(styleId);
      return !!(st && CODE_STYLES.has((st.name || '').trim().toLowerCase()));
    })();
  const allMono = spans.length > 0 && spans.every((s) => s.mono || s.text.trim() === '');
  const shaded = /<w:shd\b[^>]*w:fill="(?!auto|FFFFFF)/.test(pPr + inner);
  if (text && (isCodeStyle || (allMono && shaded))) {
    return { type: 'code', lines: spansToPlain(spans).split('\n') };
  }

  // ⑤ 分隔线（下边框 + 没有文字）
  if (!text && /<w:pBdr\b[\s\S]*?<w:bottom\b/.test(pPr)) return { type: 'rule' };

  // ⑥ 图片（可能带一句图注）
  if (images.length) {
    return { type: 'image', images, caption: text };
  }

  if (!text) return null; // 空段落 / 只带 sectPr 的收尾段落
  return { type: 'paragraph', spans };
}

/** 表格 → `string[][]`（按 `gridSpan` 补空列；行按最宽的行对齐）。 */
export function tableToRows(inner, ctx) {
  const rows = [];
  const trRe = /<w:tr\b[^>]*>([\s\S]*?)<\/w:tr>/g;
  let m;
  while ((m = trRe.exec(inner)) !== null) {
    const cells = [];
    const tcRe = /<w:tc\b[^>]*>([\s\S]*?)<\/w:tc>/g;
    let cm;
    while ((cm = tcRe.exec(m[1])) !== null) {
      const cellXml = cm[1];
      // 单元格里可能有多个段落 → 用空格连起来（Markdown 单元格里换行会破表格）
      const texts = [];
      const pRe = /<w:p\b[^>]*>([\s\S]*?)<\/w:p>/g;
      let pm;
      while ((pm = pRe.exec(cellXml)) !== null) {
        const t = spansToPlain(inlineSpans(pm[1], ctx.rels)).replace(/\s+/g, ' ').trim();
        if (t) texts.push(t);
      }
      if (texts.length === 0) texts.push(textOnly(cellXml).replace(/\s+/g, ' ').trim());
      cells.push(texts.join(' '));
      // gridSpan=2 的格子占两列 → 后面补一个空格子，保住表格形状
      const gs = /<w:gridSpan\b[^>]*\/?>/.exec(cellXml);
      const span = gs ? Number(attr(gs[0], 'w:val') || 1) : 1;
      for (let k = 1; k < span; k += 1) cells.push('');
    }
    if (cells.length) rows.push(cells);
  }
  return rows;
}

// ─────────────────────────────────────────────────────────── 渲染

function escapeCell(s) {
  return String(s).replace(/\|/g, '\\|').replace(/\n+/g, ' ').trim();
}

/** 结构化块 → Markdown（列表项之间**不空行**，这样和 make-docx 的输入格式对得上）。 */
export function blocksToMarkdown(blocks) {
  const out = [];
  /** 上一个块如果是列表项，这里记着它是"项目符号"还是"数字"（null = 不是列表）。 */
  let prevList = null;
  for (const b of blocks) {
    // 每一块**自带前导分隔符**：块之间一个空行，同一串列表项之间只换行。
    // （先前的写法把分隔符漏在了 `join('')` 上，结果列表项和标题直接粘成一串。）
    const first = out.length === 0;
    if (b.type === 'list') {
      // 空行的规则：上一个也是列表项、而且**换了种类**（`-` 变 `1.`）时，那是
      // Markdown 里的**两个列表**，中间要有空行；同种类的连续项只换行。
      const sameList = prevList !== null && prevList.ordered === b.ordered;
      const sep = first ? '' : (sameList ? '\n' : '\n\n');
      out.push(sep + '  '.repeat(b.level || 0) + b.marker
        + spansToMarkdown(b.spans).trim());
      prevList = { ordered: b.ordered };
      continue;
    }
    const sep = first ? '' : '\n\n';
    prevList = null;
    if (b.type === 'heading') {
      out.push(`${sep}${'#'.repeat(Math.min(9, b.level))} ${spansToMarkdown(b.spans, { suppressAllBold: true }).trim()}`);
    } else if (b.type === 'paragraph') {
      out.push(`${sep}${spansToMarkdown(b.spans).trim()}`);
    } else if (b.type === 'quote') {
      out.push(`${sep}${spansToMarkdown(b.spans).trim().split('\n').map((l) => `> ${l}`).join('\n')}`);
    } else if (b.type === 'code') {
      out.push(`${sep}\`\`\`\n${b.lines.join('\n')}\n\`\`\``);
    } else if (b.type === 'rule') {
      out.push(`${sep}---`);
    } else if (b.type === 'image') {
      const lines = b.images.map((p) => (b.extracted && b.extracted[p])
        ? `![](${b.extracted[p]})`
        : `<!-- 图片未提取：${p} -->`);
      if (b.caption) lines.push(b.caption);
      out.push(sep + lines.join('\n\n'));
    } else if (b.type === 'table') {
      const rows = b.rows;
      const width = rows.reduce((a, r) => Math.max(a, r.length), 0);
      const pad = (r) => {
        const c = r.map(escapeCell);
        while (c.length < width) c.push('');
        return `| ${c.join(' | ')} |`;
      };
      out.push(`${sep}${pad(rows[0])}\n|${'---|'.repeat(width)}\n${rows.slice(1).map(pad).join('\n')}`);
    }
  }
  return `${out.join('')}\n`;
}

/** 结构化块 → 纯文本。 */
export function blocksToText(blocks) {
  const out = [];
  let prevWasList = false;
  for (const b of blocks) {
    const first = out.length === 0;
    if (b.type === 'list') {
      const sep = first ? '' : (prevWasList ? '\n' : '\n\n');
      out.push(sep + '  '.repeat(b.level || 0) + b.marker + spansToPlain(b.spans).trim());
      prevWasList = true;
      continue;
    }
    const sep = first ? '' : '\n\n';
    prevWasList = false;
    if (b.type === 'heading' || b.type === 'paragraph') {
      out.push(sep + spansToPlain(b.spans).trim());
    } else if (b.type === 'quote') {
      out.push(`${sep}${spansToPlain(b.spans).trim().split('\n').map((l) => `> ${l}`).join('\n')}`);
    } else if (b.type === 'code') {
      out.push(sep + b.lines.join('\n'));
    } else if (b.type === 'rule') {
      out.push(`${sep}---`);
    } else if (b.type === 'image') {
      out.push(`${sep}${b.images.map((p) => `（图片：${p}）`).join('\n')}`);
    } else if (b.type === 'table') {
      out.push(`${sep}${b.rows.map((r) => r.join('\t')).join('\n')}`);
    }
  }
  return `${out.join('')}\n`;
}

/** 结构化块 → JSON（给下游程序用，所以字段名一律英文、结构稳定）。 */
export function blocksToJson(blocks, stats) {
  return `${JSON.stringify({
    paragraphs: stats.paragraphs,
    tables: stats.tables,
    images: stats.images,
    blocks: blocks.map((b) => {
      const base = { type: b.type };
      if (b.type === 'heading') return { ...base, level: b.level, text: spansToPlain(b.spans).trim(), markdown: spansToMarkdown(b.spans, { suppressAllBold: true }).trim() };
      if (b.type === 'paragraph' || b.type === 'quote') return { ...base, text: spansToPlain(b.spans).trim(), markdown: spansToMarkdown(b.spans).trim() };
      if (b.type === 'list') return { ...base, ordered: b.ordered, level: b.level, text: spansToPlain(b.spans).trim() };
      if (b.type === 'code') return { ...base, lines: b.lines };
      if (b.type === 'rule') return base;
      if (b.type === 'image') return { ...base, images: b.images, caption: b.caption || '' };
      if (b.type === 'table') return { ...base, rows: b.rows };
      return base;
    }),
  }, null, 2)}\n`;
}

// ─────────────────────────────────────────────────────────── 主流程

/** 读一个 .docx Buffer → `{blocks, stats}`。导出是为了让测试能直接喂字节。 */
export function parseDocx(buf, { extractImagesDir = '' } = {}) {
  const zip = zipRead(buf);
  const doc = zip.get('word/document.xml');
  if (!doc) {
    throw new Error('包里没有 word/document.xml —— 这不像是 .docx（是不是 .doc 老格式？）');
  }
  const styles = parseStyles((zip.get('word/styles.xml') || Buffer.from('')).toString('utf8'));
  const numbering = parseNumbering((zip.get('word/numbering.xml') || Buffer.from('')).toString('utf8'));
  const rels = parseRels((zip.get('word/_rels/document.xml.rels') || Buffer.from('')).toString('utf8'));

  const bodyXml = doc.toString('utf8');
  const body = (/<w:body\b[^>]*>([\s\S]*)<\/w:body>/.exec(bodyXml) || [, bodyXml])[1];
  const ctx = { styles, numbering, rels, counters: new Map() };

  const blocks = [];
  let paragraphs = 0;
  let tables = 0;
  let images = 0;

  for (const blk of tokenizeBlocks(body)) {
    if (blk.type === 'p') {
      const b = paragraphToBlock(blk.inner, ctx);
      if (!b) continue;
      paragraphs += 1;
      if (b.type === 'image') {
        b.extracted = {};
        images += b.images.length;
        if (extractImagesDir) {
          for (const target of b.images) {
            // 关系里的 target 是相对 word/ 的（通常是 media/image1.png）
            const member = zip.get(`word/${target}`) || zip.get(target);
            if (!member) continue;
            const dest = join(extractImagesDir, target.replace(/^\.\//, '').replace(/\//g, '_'));
            mkdirSync(dirname(dest), { recursive: true });
            writeFileSync(dest, member);
            b.extracted[target] = dest;
          }
        }
      }
      blocks.push(b);
    } else {
      const rows = tableToRows(blk.inner, ctx);
      if (rows.length === 0) continue;
      tables += 1;
      blocks.push({ type: 'table', rows });
    }
  }
  return { blocks, stats: { paragraphs, tables, images } };
}

function parseArgs(argv) {
  const out = { positional: [], format: 'md', out: '', extractImages: '' };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--help' || a === '-h') { process.stdout.write(HELP); process.exit(0); }
    else if (a === '--format') out.format = (argv[++i] || '').toLowerCase();
    else if (a === '--out') out.out = argv[++i] || '';
    else if (a === '--extract-images') out.extractImages = argv[++i] || '';
    else if (a.startsWith('--')) fail(`不认识的选项：${a}`, 2);
    else out.positional.push(a);
  }
  if (!['md', 'txt', 'json'].includes(out.format)) {
    fail(`--format 只认 md / txt / json（给的是 ${out.format}）`, 2);
  }
  return out;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.positional.length < 1) { process.stderr.write(HELP); process.exit(2); }
  const inPath = args.positional[0];
  if (!existsSync(inPath)) fail(`输入文件不存在：${inPath}`, 2);

  let parsed;
  try {
    parsed = parseDocx(readFileSync(inPath), { extractImagesDir: args.extractImages });
  } catch (e) {
    fail(`读 docx 失败：${e.message}`, 1);
  }

  const { blocks, stats } = parsed;
  const text = args.format === 'json'
    ? blocksToJson(blocks, stats)
    : (args.format === 'txt' ? blocksToText(blocks) : blocksToMarkdown(blocks));

  const marker = `[docx] ok op=read paragraphs=${stats.paragraphs} tables=${stats.tables}`
    + ` images=${stats.images}`;

  if (args.out) {
    const abs = resolve(args.out);
    try {
      // 抽图时目录可能还不存在（图片自己会建，但"只给目录"的情况下要它存在）
      if (args.extractImages && !existsSync(args.extractImages)) {
        mkdirSync(args.extractImages, { recursive: true });
      }
      if (!existsSync(dirname(abs))) mkdirSync(dirname(abs), { recursive: true });
      writeFileSync(abs, text);
    } catch (e) {
      fail(`写出失败：${e.message}`, 1);
    }
    process.stderr.write(`${marker} out=${abs}\n`);
    return;
  }
  process.stdout.write(text);
  process.stderr.write(`${marker} out=-\n`);
}

const isDirectRun = process.argv[1]
  && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (isDirectRun) main();
