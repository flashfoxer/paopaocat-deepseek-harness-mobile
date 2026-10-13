#!/usr/bin/env node
'use strict';
/**
 * make-pptx.mjs —— 用**纯 Node 内置模块**生成真正的 .pptx（OOXML）。
 *
 * 用法：
 *   node make-pptx.mjs <outline.json> <out.pptx>
 *   node make-pptx.mjs --help
 *
 * outline.json（字段缺省都有合理默认，"宽进"）：
 *   {
 *     "title": "封面标题",            // 缺省 "演示文稿"
 *     "subtitle": "副标题",           // 可选，无则不画副标题
 *     "author": "可选",               // 写进 docProps/core.xml
 *     "slides": [
 *       { "title": "小节标题",
 *         "bullets": ["要点1", "要点2"],   // 也可以是 [{"text":"要点","level":1}] 或单个字符串
 *         "notes": "演讲者备注（可选）" }
 *     ]
 *   }
 *
 * 为什么要自己写而不是用 npm 包 / 外部命令：
 *   Android 上没有 pandoc、没有 python、也不方便装 node_modules，App 只能是
 *   "随包带一个 .mjs，用随包的 node 跑"。所以压缩、加密哈希以外的所有东西
 *   （ZIP 容器、CRC32、OOXML 序列化）都得自己实现，而且必须完全离线。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * OOXML/OPC 的最低要求（少了哪一块会怎样）
 * ══════════════════════════════════════════════════════════════════════════
 * 一个 .pptx 本质是一个 ZIP，里面是一堆 XML 部件 + 关系（rels）图：
 *
 *   [Content_Types].xml
 *        **必须在包根目录**，声明每个部件的内容类型。缺了它或漏一个部件，
 *        PowerPoint 直接判定"文件已损坏"。
 *   _rels/.rels
 *        包级关系：指向 ppt/presentation.xml（officeDocument 类型）与
 *        docProps/core.xml。缺了它 PowerPoint 找不到主部件。
 *   ppt/presentation.xml
 *        主部件：幻灯片尺寸（本例 16:9 = 12192000 x 6858000 EMU）、幻灯片的
 *        顺序（p:sldIdLst）、引用的母版。
 *   ppt/slideMasters/slideMaster1.xml
 *        **必须有**。母版定义配色映射（clrMap）、版式清单（sldLayoutIdLst）、
 *        文字默认样式（txStyles）。缺了它 PowerPoint 无法解析任何一张幻灯片的
 *        继承链 → 报"需要修复"。
 *   ppt/slideLayouts/slideLayoutN.xml
 *        **每张 slide 都必须通过 rels 关到一个版式**。版式里放占位符的位置与
 *        字号，slide 上的占位符通过 `p:ph type/idx` 匹配它继承几何。
 *        缺了版式关联，PowerPoint 打开就报修复。
 *   ppt/slides/slideN.xml
 *        幻灯片本体（这里用占位符：type="title" / idx="1"），
 *        `<p:spPr/>` 故意留空 —— 位置尺寸继承自版式，和 python-pptx 产物一致。
 *   ppt/theme/theme1.xml
 *        **必须有**（母版必须 rel 到它）。themeElements 里的 clrScheme /
 *        fontScheme / fmtScheme 三个都是必需项；fmtScheme 的填充/线/效果/
 *        背景四个列表各要至少 3 项。中文字体就是在这里（ea typeface）生效的。
 *   ppt/notesSlides/notesSlideN.xml（可选）
 *        演讲者备注。一旦有 notesSlide，就还要有 ppt/notesMasters/notesMaster1.xml
 *        （notesSlide 必须 rel 到它），并且它自己 rel 到 theme。
 *
 * 本实现严格按上面的最小合法集生成，不做任何"想当然的省略"。
 */

import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { deflateRawSync } from 'node:zlib';

// ─────────────────────────────────────────────────────────── 常量

const XML_DECL = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';

/** 16:9：12192000 x 6858000 EMU（1 英寸 = 914400 EMU，即 13.333in x 7.5in） */
const SLIDE_W = 12192000;
const SLIDE_H = 6858000;

/** 版心：左右各留 838200 EMU（0.9167 in），够放 16:9 的标题与正文 */
const MARGIN_X = 838200;
const CONTENT_W = SLIDE_W - MARGIN_X * 2;
const TITLE_Y = 457200;
const TITLE_H = 1143000;
const BODY_Y = 1600200;
const BODY_H = 4525963;

/** 中英文字体：Calibri 是 OOXML 的通用西文字体，等线是 Windows/WPS 自带的中文黑体 */
const FONT_LATIN = 'Calibri';
const FONT_EA = '等线';

const NS_A = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const NS_P = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const NS_R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const NS_CT = 'http://schemas.openxmlformats.org/package/2006/content-types';
const NS_REL = 'http://schemas.openxmlformats.org/package/2006/relationships';

const RT = {
  officeDocument: NS_R + '/officeDocument',
  coreProps: 'http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties',
  slideMaster: NS_R + '/slideMaster',
  slideLayout: NS_R + '/slideLayout',
  slide: NS_R + '/slide',
  theme: NS_R + '/theme',
  notesMaster: NS_R + '/notesMaster',
  notesSlide: NS_R + '/notesSlide',
};

const CT = {
  presentation: 'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml',
  slideMaster: 'application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml',
  slideLayout: 'application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml',
  slide: 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml',
  theme: 'application/vnd.openxmlformats-officedocument.theme+xml',
  notesMaster: 'application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml',
  notesSlide: 'application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml',
  coreProps: 'application/vnd.openxmlformats-package.core-properties+xml',
};

const HELP = `make-pptx.mjs —— 纯 Node 内置模块生成真正的 .pptx（离线可用，无 npm 依赖）

用法:
  node make-pptx.mjs <outline.json> <out.pptx>
  node make-pptx.mjs --help

outline.json 结构（字段缺省都有默认值）:
  {
    "title": "封面标题",          // 缺省 "演示文稿"
    "subtitle": "副标题",         // 可选
    "author": "作者",             // 可选，写进文档属性
    "slides": [
      {
        "title": "小节标题",
        "bullets": ["要点1", "要点2"],
        "notes": "演讲者备注（可选）"
      }
    ]
  }

  * bullets 也可以是字符串（单条），或 [{ "text": "要点", "level": 0 }]，
    level 0/1/2 对应三级缩进。
  * slides 为空时只生成封面页。
  * 尺寸固定 16:9（12192000 x 6858000 EMU）。

退出码: 0 成功；1 生成失败（文件不存在 / JSON 不合法 / 写不进去）；2 参数用法错误。
`;

// ─────────────────────────────────────────────────────────── 小工具

function fail(message) {
  process.stderr.write('错误：' + message + '\n');
  process.exit(1);
}

function usageFail(message) {
  process.stderr.write('错误：' + message + '\n\n' + HELP);
  process.exit(2);
}

/** XML 文本转义 + 丢掉 XML 1.0 不允许的控制字符（模型给的字里偶尔会有） */
function esc(value) {
  return String(value == null ? '' : value)
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/** 关系文件（.rels） */
function relsXml(items) {
  const body = items
    .map((it) => `<Relationship Id="${it.id}" Type="${it.type}" Target="${esc(it.target)}"/>`)
    .join('');
  return `${XML_DECL}<Relationships xmlns="${NS_REL}">${body}</Relationships>`;
}

// ─────────────────────────────────────────────────────────── 文本/段落

/** 字体三件套：西文 + 东亚 + 复杂文种，中文能不能正常显示就看 ea */
function typefaces() {
  return `<a:latin typeface="${FONT_LATIN}"/><a:ea typeface="${FONT_EA}"/><a:cs typeface="${FONT_LATIN}"/>`;
}

/** 一个文本段（换行拆成 <a:br/>，保证不丢字也不串行） */
function runsXml(text, opts) {
  const o = opts || {};
  const rPr =
    `<a:rPr lang="zh-CN" altLang="en-US"${o.size ? ` sz="${o.size}"` : ''}${o.bold ? ' b="1"' : ''} dirty="0">` +
    `<a:solidFill><a:schemeClr val="${o.color || 'tx1'}"/></a:solidFill>` +
    typefaces() +
    '</a:rPr>';
  return String(text == null ? '' : text)
    .split('\n')
    .map((line) => `<a:r>${rPr}<a:t>${esc(line)}</a:t></a:r>`)
    .join('<a:br/>');
}

/** 无项目符号的段落（标题、副标题、备注） */
function plainPara(text, opts) {
  return `<a:p>${runsXml(text, opts)}</a:p>`;
}

/** 带项目符号的段落，level 0/1/2 依次缩进 */
function bulletPara(text, level, size) {
  const lv = Math.max(0, Math.min(4, Number(level) || 0));
  const marL = 342900 * (lv + 1);
  const chars = ['•', '–', '·', '•', '–'];
  const pPr =
    `<a:pPr marL="${marL}" indent="-342900">` +
    `<a:buFont typeface="Arial"/><a:buChar char="${chars[lv]}"/>` +
    '</a:pPr>';
  return `<a:p>${pPr}${runsXml(text, { size })}</a:p>`;
}

/** 空段落（占位符里必须至少有一个 a:p） */
function emptyPara() {
  return '<a:p><a:endParaRPr lang="zh-CN" dirty="0"/></a:p>';
}

function txBodyXml(paras, bodyPr) {
  const attrs = bodyPr === undefined
    ? ' wrap="square" lIns="91440" tIns="45720" rIns="91440" bIns="45720" anchor="t"'
    : bodyPr;
  return `<p:txBody><a:bodyPr${attrs}/><a:lstStyle/>${paras.join('')}</p:txBody>`;
}

/** 非占位符的普通文本框（封面用的自由度更大的那种，这里也走占位符，见下） */
function spXml(id, name, phXml, xfrmXml, txBody) {
  return (
    '<p:sp>' +
    '<p:nvSpPr>' +
    `<p:cNvPr id="${id}" name="${esc(name)}"/>` +
    '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>' +
    `<p:nvPr>${phXml}</p:nvPr>` +
    '</p:nvSpPr>' +
    `<p:spPr>${xfrmXml}</p:spPr>` +
    txBody +
    '</p:sp>'
  );
}

/** 只有占位符、没有 txBody 的形状（备注页里的"幻灯片图像"之类） */
function spNoTextXml(id, name, phXml, xfrmXml) {
  return (
    '<p:sp>' +
    '<p:nvSpPr>' +
    `<p:cNvPr id="${id}" name="${esc(name)}"/>` +
    '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>' +
    `<p:nvPr>${phXml}</p:nvPr>` +
    '</p:nvSpPr>' +
    `<p:spPr>${xfrmXml}</p:spPr>` +
    '</p:sp>'
  );
}

function xfrmXml(x, y, cx, cy) {
  return `<a:xfrm><a:off x="${x}" y="${y}"/><a:ext cx="${cx}" cy="${cy}"/></a:xfrm>`;
}

const GROUP_SHAPE =
  '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>' +
  '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>' +
  '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';

/** clrMap：12 个属性一个都不能少（母版/备注母版都要） */
const CLR_MAP =
  '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" ' +
  'accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>';

// ─────────────────────────────────────────────────────────── 固定部件

function contentTypesXml(slideCount, hasNotes) {
  const overrides = [
    ['/ppt/presentation.xml', CT.presentation],
    ['/ppt/slideMasters/slideMaster1.xml', CT.slideMaster],
    ['/ppt/slideLayouts/slideLayout1.xml', CT.slideLayout],
    ['/ppt/slideLayouts/slideLayout2.xml', CT.slideLayout],
    ['/ppt/theme/theme1.xml', CT.theme],
    ['/docProps/core.xml', CT.coreProps],
  ];
  for (let i = 1; i <= slideCount; i += 1) overrides.push([`/ppt/slides/slide${i}.xml`, CT.slide]);
  if (hasNotes && hasNotes.size > 0) {
    overrides.push(['/ppt/notesMasters/notesMaster1.xml', CT.notesMaster]);
    for (let i = 1; i <= slideCount; i += 1) {
      // 只有真的有备注的页才注册（buildParts 里也只为这些页生成 notesSlide）
      if (hasNotes.has(i)) overrides.push([`/ppt/notesSlides/notesSlide${i}.xml`, CT.notesSlide]);
    }
  }
  const body =
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
    '<Default Extension="xml" ContentType="application/xml"/>' +
    overrides.map(([part, ct]) => `<Override PartName="${part}" ContentType="${ct}"/>`).join('');
  return `${XML_DECL}<Types xmlns="${NS_CT}">${body}</Types>`;
}

function rootRelsXml() {
  return relsXml([
    { id: 'rId1', type: RT.officeDocument, target: 'ppt/presentation.xml' },
    { id: 'rId2', type: RT.coreProps, target: 'docProps/core.xml' },
  ]);
}

function coreXml(meta) {
  const now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  const author = meta.author || 'DSH toolbox';
  return (
    XML_DECL +
    '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"' +
    ' xmlns:dc="http://purl.org/dc/elements/1.1/"' +
    ' xmlns:dcterms="http://purl.org/dc/terms/"' +
    ' xmlns:dcmitype="http://purl.org/dc/dcmitype/"' +
    ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
    `<dc:title>${esc(meta.title)}</dc:title>` +
    '<dc:subject/>' +
    `<dc:creator>${esc(author)}</dc:creator>` +
    '<cp:keywords/>' +
    `<dc:description>${esc(meta.subtitle || '')}</dc:description>` +
    `<cp:lastModifiedBy>${esc(author)}</cp:lastModifiedBy>` +
    '<cp:revision>1</cp:revision>' +
    `<dcterms:created xsi:type="dcterms:W3CDTF">${now}</dcterms:created>` +
    `<dcterms:modified xsi:type="dcterms:W3CDTF">${now}</dcterms:modified>` +
    '<cp:category/><cp:contentStatus/>' +
    '</cp:coreProperties>'
  );
}

function presentationXml(slideCount, hasNotes) {
  // rId1 = 母版；rId2 = theme；rId3..N+2 = 幻灯片；最后 = notesMaster
  const slideIds = [];
  for (let i = 1; i <= slideCount; i += 1) {
    slideIds.push(`<p:sldId id="${255 + i}" r:id="rId${2 + i}"/>`);
  }
  return (
    XML_DECL +
    `<p:presentation xmlns:a="${NS_A}" xmlns:r="${NS_R}" xmlns:p="${NS_P}" saveSubsetFonts="1">` +
    '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>' +
    `<p:sldIdLst>${slideIds.join('')}</p:sldIdLst>` +
    `<p:sldSz cx="${SLIDE_W}" cy="${SLIDE_H}"/>` +
    '<p:notesSz cx="6858000" cy="9144000"/>' +
    '<p:defaultTextStyle>' +
    '<a:defPPr><a:defRPr lang="zh-CN" dirty="0"/></a:defPPr>' +
    '<a:lvl1pPr marL="0" algn="l" defTabSz="457200" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">' +
    '<a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>' +
    typefaces() +
    '</a:defRPr></a:lvl1pPr>' +
    '</p:defaultTextStyle>' +
    '</p:presentation>'
  );
}

function presentationRelsXml(slideCount, hasNotes) {
  const items = [
    { id: 'rId1', type: RT.slideMaster, target: 'slideMasters/slideMaster1.xml' },
    { id: 'rId2', type: RT.theme, target: 'theme/theme1.xml' },
  ];
  for (let i = 1; i <= slideCount; i += 1) {
    items.push({ id: `rId${2 + i}`, type: RT.slide, target: `slides/slide${i}.xml` });
  }
  if (hasNotes.size > 0) {
    items.push({ id: `rId${3 + slideCount}`, type: RT.notesMaster, target: 'notesMasters/notesMaster1.xml' });
  }
  return relsXml(items);
}

function slideMasterXml() {
  const title = spXml(
    2,
    '标题占位符 1',
    '<p:ph type="title"/>',
    xfrmXml(MARGIN_X, TITLE_Y, CONTENT_W, TITLE_H),
    txBodyXml([plainPara('单击此处编辑母版标题样式', { size: 3600 })]),
  );
  const body = spXml(
    3,
    '正文占位符 2',
    '<p:ph type="body" idx="1"/>',
    xfrmXml(MARGIN_X, BODY_Y, CONTENT_W, BODY_H),
    txBodyXml([plainPara('单击此处编辑母版文本样式', { size: 1800 })]),
  );
  return (
    XML_DECL +
    `<p:sldMaster xmlns:a="${NS_A}" xmlns:r="${NS_R}" xmlns:p="${NS_P}">` +
    '<p:cSld>' +
    '<p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>' +
    `<p:spTree>${GROUP_SHAPE}${title}${body}</p:spTree>` +
    '</p:cSld>' +
    CLR_MAP +
    '<p:sldLayoutIdLst>' +
    '<p:sldLayoutId id="2147483649" r:id="rId1"/>' +
    '<p:sldLayoutId id="2147483650" r:id="rId2"/>' +
    '</p:sldLayoutIdLst>' +
    '<p:txStyles>' +
    '<p:titleStyle>' +
    '<a:lvl1pPr algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">' +
    '<a:defRPr sz="3600" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>' +
    typefaces() +
    '</a:defRPr></a:lvl1pPr>' +
    '</p:titleStyle>' +
    '<p:bodyStyle>' +
    '<a:lvl1pPr marL="342900" indent="-342900" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">' +
    '<a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>' +
    typefaces() +
    '</a:defRPr></a:lvl1pPr>' +
    '<a:lvl2pPr marL="685800" indent="-342900" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">' +
    '<a:defRPr sz="1600" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>' +
    typefaces() +
    '</a:defRPr></a:lvl2pPr>' +
    '</p:bodyStyle>' +
    '<p:otherStyle><a:defPPr><a:defRPr lang="zh-CN" dirty="0"/></a:defPPr>' +
    '<a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">' +
    '<a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>' +
    typefaces() +
    '</a:defRPr></a:lvl1pPr></p:otherStyle>' +
    '</p:txStyles>' +
    '</p:sldMaster>'
  );
}

function slideMasterRelsXml() {
  return relsXml([
    { id: 'rId1', type: RT.slideLayout, target: '../slideLayouts/slideLayout1.xml' },
    { id: 'rId2', type: RT.slideLayout, target: '../slideLayouts/slideLayout2.xml' },
    { id: 'rId3', type: RT.theme, target: '../theme/theme1.xml' },
  ]);
}

/** 版式 1：标题幻灯片（ctrTitle + subTitle） */
function slideLayout1Xml() {
  const title = spXml(
    2,
    '标题 1',
    '<p:ph type="ctrTitle"/>',
    xfrmXml(MARGIN_X, 2130425, CONTENT_W, 1524000),
    txBodyXml([emptyPara()], ' wrap="square" anchor="ctr"'),
  );
  const subtitle = spXml(
    3,
    '副标题 2',
    '<p:ph type="subTitle" idx="1"/>',
    xfrmXml(MARGIN_X + 457200, 3810000, CONTENT_W - 914400, 1470025),
    txBodyXml([emptyPara()], ' wrap="square" anchor="t"'),
  );
  return (
    XML_DECL +
    `<p:sldLayout xmlns:a="${NS_A}" xmlns:r="${NS_R}" xmlns:p="${NS_P}" type="title" preserve="1">` +
    `<p:cSld name="标题幻灯片"><p:spTree>${GROUP_SHAPE}${title}${subtitle}</p:spTree></p:cSld>` +
    '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>' +
    '</p:sldLayout>'
  );
}

/** 版式 2：标题和内容（title + 正文占位符 idx=1） */
function slideLayout2Xml() {
  const title = spXml(
    2,
    '标题 1',
    '<p:ph type="title"/>',
    xfrmXml(MARGIN_X, TITLE_Y, CONTENT_W, TITLE_H),
    txBodyXml([emptyPara()]),
  );
  const body = spXml(
    3,
    '正文占位符 2',
    '<p:ph idx="1"/>',
    xfrmXml(MARGIN_X, BODY_Y, CONTENT_W, BODY_H),
    txBodyXml([
      '<a:p><a:pPr marL="342900" indent="-342900"><a:buFont typeface="Arial"/><a:buChar char="•"/></a:pPr>' +
        '<a:endParaRPr lang="zh-CN" dirty="0"/></a:p>',
    ]),
  );
  return (
    XML_DECL +
    `<p:sldLayout xmlns:a="${NS_A}" xmlns:r="${NS_R}" xmlns:p="${NS_P}" type="obj" preserve="1">` +
    `<p:cSld name="标题和内容"><p:spTree>${GROUP_SHAPE}${title}${body}</p:spTree></p:cSld>` +
    '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>' +
    '</p:sldLayout>'
  );
}

function slideLayoutRelsXml() {
  return relsXml([{ id: 'rId1', type: RT.slideMaster, target: '../slideMasters/slideMaster1.xml' }]);
}

/**
 * 主题。三个必需块：clrScheme / fontScheme / fmtScheme。
 * fmtScheme 的四类列表（filling/line/effect/background）各至少 3 项，
 * 少一项 PowerPoint 就判定主题非法。
 * 中文靠 fontScheme 的 `<a:ea typeface="等线"/>` + `<a:font script="Hans"/>`。
 */
function themeXml() {
  const solid = '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>';
  const grad1 =
    '<a:gradFill rotWithShape="1"><a:gsLst>' +
    '<a:gs pos="0"><a:schemeClr val="phClr"><a:tint val="50000"/><a:satMod val="300000"/></a:schemeClr></a:gs>' +
    '<a:gs pos="35000"><a:schemeClr val="phClr"><a:tint val="37000"/><a:satMod val="300000"/></a:schemeClr></a:gs>' +
    '<a:gs pos="100000"><a:schemeClr val="phClr"><a:tint val="15000"/><a:satMod val="350000"/></a:schemeClr></a:gs>' +
    '</a:gsLst><a:lin ang="16200000" scaled="1"/></a:gradFill>';
  const grad2 =
    '<a:gradFill rotWithShape="1"><a:gsLst>' +
    '<a:gs pos="0"><a:schemeClr val="phClr"><a:shade val="51000"/><a:satMod val="130000"/></a:schemeClr></a:gs>' +
    '<a:gs pos="80000"><a:schemeClr val="phClr"><a:shade val="93000"/><a:satMod val="130000"/></a:schemeClr></a:gs>' +
    '<a:gs pos="100000"><a:schemeClr val="phClr"><a:shade val="94000"/><a:satMod val="135000"/></a:schemeClr></a:gs>' +
    '</a:gsLst><a:lin ang="16200000" scaled="0"/></a:gradFill>';
  const grad3 =
    '<a:gradFill rotWithShape="1"><a:gsLst>' +
    '<a:gs pos="0"><a:schemeClr val="phClr"><a:tint val="40000"/><a:satMod val="350000"/></a:schemeClr></a:gs>' +
    '<a:gs pos="40000"><a:schemeClr val="phClr"><a:tint val="45000"/><a:shade val="99000"/><a:satMod val="350000"/></a:schemeClr></a:gs>' +
    '<a:gs pos="100000"><a:schemeClr val="phClr"><a:shade val="20000"/><a:satMod val="255000"/></a:schemeClr></a:gs>' +
    '</a:gsLst><a:path path="circle"><a:fillToRect l="50000" t="-80000" r="50000" b="180000"/></a:path></a:gradFill>';
  const line = (w) =>
    `<a:ln w="${w}" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>` +
    '<a:prstDash val="solid"/><a:miter lim="800000"/></a:ln>';
  return (
    XML_DECL +
    `<a:theme xmlns:a="${NS_A}" name="DSH 主题">` +
    '<a:themeElements>' +
    '<a:clrScheme name="Office">' +
    '<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>' +
    '<a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>' +
    '<a:dk2><a:srgbClr val="1F497D"/></a:dk2>' +
    '<a:lt2><a:srgbClr val="EEECE1"/></a:lt2>' +
    '<a:accent1><a:srgbClr val="4F81BD"/></a:accent1>' +
    '<a:accent2><a:srgbClr val="C0504D"/></a:accent2>' +
    '<a:accent3><a:srgbClr val="9BBB59"/></a:accent3>' +
    '<a:accent4><a:srgbClr val="8064A2"/></a:accent4>' +
    '<a:accent5><a:srgbClr val="4BACC6"/></a:accent5>' +
    '<a:accent6><a:srgbClr val="F79646"/></a:accent6>' +
    '<a:hlink><a:srgbClr val="0000FF"/></a:hlink>' +
    '<a:folHlink><a:srgbClr val="800080"/></a:folHlink>' +
    '</a:clrScheme>' +
    '<a:fontScheme name="Office">' +
    `<a:majorFont><a:latin typeface="${FONT_LATIN}"/><a:ea typeface="${FONT_EA}"/><a:cs typeface=""/>` +
    `<a:font script="Hans" typeface="${FONT_EA}"/><a:font script="Hant" typeface="新細明體"/>` +
    '<a:font script="Jpan" typeface="ＭＳ Ｐゴシック"/><a:font script="Hang" typeface="맑은 고딕"/></a:majorFont>' +
    `<a:minorFont><a:latin typeface="${FONT_LATIN}"/><a:ea typeface="${FONT_EA}"/><a:cs typeface=""/>` +
    `<a:font script="Hans" typeface="${FONT_EA}"/><a:font script="Hant" typeface="新細明體"/>` +
    '<a:font script="Jpan" typeface="ＭＳ Ｐゴシック"/><a:font script="Hang" typeface="맑은 고딕"/></a:minorFont>' +
    '</a:fontScheme>' +
    '<a:fmtScheme name="Office">' +
    `<a:fillStyleLst>${solid}${grad1}${grad2}</a:fillStyleLst>` +
    `<a:lnStyleLst>${line(9525)}${line(25400)}${line(38100)}</a:lnStyleLst>` +
    '<a:effectStyleLst>' +
    '<a:effectStyle><a:effectLst/></a:effectStyle>' +
    '<a:effectStyle><a:effectLst/></a:effectStyle>' +
    '<a:effectStyle><a:effectLst><a:outerShdw blurRad="57150" dist="19050" dir="5400000" rotWithShape="0">' +
    '<a:srgbClr val="000000"><a:alpha val="63000"/></a:srgbClr></a:outerShdw></a:effectLst></a:effectStyle>' +
    '</a:effectStyleLst>' +
    '<a:bgFillStyleLst>' +
    solid +
    '<a:solidFill><a:schemeClr val="phClr"><a:tint val="95000"/><a:satMod val="170000"/></a:schemeClr></a:solidFill>' +
    grad3 +
    '</a:bgFillStyleLst>' +
    '</a:fmtScheme>' +
    '</a:themeElements>' +
    '<a:objectDefaults/><a:extraClrSchemeLst/>' +
    '</a:theme>'
  );
}

/** 备注母版：notesSlide 必须 rel 到它，它自己 rel 到 theme（可共用 theme1） */
function notesMasterXml() {
  const sp = (id, name, ph, xfrm, tx) =>
    tx === undefined ? spNoTextXml(id, name, ph, xfrm) : spXml(id, name, ph, xfrm, tx);
  const shapes = [
    sp(2, '幻灯片图像占位符 1', '<p:ph type="sldImg" idx="2"/>', xfrmXml(1143000, 685800, 4572000, 3429000)),
    sp(
      3,
      '备注占位符 2',
      '<p:ph type="body" sz="quarter" idx="3"/>',
      xfrmXml(685800, 4343400, 5486400, 4114800),
      txBodyXml([plainPara('', { size: 1200 })]),
    ),
    sp(4, '页码占位符 3', '<p:ph type="sldNum" sz="quarter" idx="5"/>', xfrmXml(3884613, 8685213, 2971800, 457200)),
  ];
  return (
    XML_DECL +
    `<p:notesMaster xmlns:a="${NS_A}" xmlns:r="${NS_R}" xmlns:p="${NS_P}">` +
    '<p:cSld>' +
    '<p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>' +
    `<p:spTree>${GROUP_SHAPE}${shapes.join('')}</p:spTree>` +
    '</p:cSld>' +
    CLR_MAP +
    '<p:notesStyle>' +
    '<a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">' +
    '<a:defRPr sz="1200" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>' +
    typefaces() +
    '</a:defRPr></a:lvl1pPr>' +
    '</p:notesStyle>' +
    '</p:notesMaster>'
  );
}

function notesMasterRelsXml() {
  return relsXml([{ id: 'rId1', type: RT.theme, target: '../theme/theme1.xml' }]);
}

/** 备注页：正文占位符 idx=3（python-pptx / PowerPoint 都按这个找备注正文） */
function notesSlideXml(notesText) {
  const sldImg = spNoTextXml(2, '幻灯片图像占位符 1', '<p:ph type="sldImg" idx="2"/>', '');
  const bodyText = String(notesText || '')
    .split('\n')
    .map((line) => plainPara(line, { size: 1200 }))
    .join('');
  const body = spXml(
    3,
    '备注占位符 2',
    '<p:ph type="body" idx="3" sz="quarter"/>',
    '',
    txBodyXml([bodyText || emptyPara()]),
  );
  const sldNum = spNoTextXml(4, '页码占位符 3', '<p:ph type="sldNum" idx="5" sz="quarter"/>', '');
  return (
    XML_DECL +
    `<p:notes xmlns:a="${NS_A}" xmlns:p="${NS_P}" xmlns:r="${NS_R}">` +
    `<p:cSld><p:spTree>${GROUP_SHAPE}${sldImg}${body}${sldNum}</p:spTree></p:cSld>` +
    '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>' +
    '</p:notes>'
  );
}

function notesSlideRelsXml(slideIndex) {
  return relsXml([
    { id: 'rId1', type: RT.notesMaster, target: '../notesMasters/notesMaster1.xml' },
    { id: 'rId2', type: RT.slide, target: `../slides/slide${slideIndex}.xml` },
  ]);
}

/** 幻灯片。isCover=true 时用 ctrTitle/subTitle 占位符（对应版式 1） */
function slideXml(slide, isCover) {
  const shapes = [];
  if (isCover) {
    shapes.push(
      spXml(2, '标题 1', '<p:ph type="ctrTitle"/>', '', txBodyXml([plainPara(slide.title, { size: 4000, bold: true })], ' wrap="square" anchor="ctr"')),
    );
    if (slide.subtitle) {
      shapes.push(
        spXml(3, '副标题 2', '<p:ph type="subTitle" idx="1"/>', '', txBodyXml([plainPara(slide.subtitle, { size: 2000 })], ' wrap="square" anchor="t"')),
      );
    }
  } else {
    shapes.push(spXml(2, '标题 1', '<p:ph type="title"/>', '', txBodyXml([plainPara(slide.title, { size: 3200, bold: true })])));
    if (slide.bullets.length > 0) {
      const size = bulletSize(slide.bullets.length);
      const paras = slide.bullets.map((b) => bulletPara(b.text, b.level, size));
      shapes.push(spXml(3, '正文占位符 2', '<p:ph idx="1"/>', '', txBodyXml(paras)));
    }
  }
  return (
    XML_DECL +
    `<p:sld xmlns:a="${NS_A}" xmlns:p="${NS_P}" xmlns:r="${NS_R}">` +
    `<p:cSld><p:spTree>${GROUP_SHAPE}${shapes.join('')}</p:spTree></p:cSld>` +
    '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>' +
    '</p:sld>'
  );
}

function slideRelsXml(isCover, notesIndex) {
  const items = [
    { id: 'rId1', type: RT.slideLayout, target: isCover ? '../slideLayouts/slideLayout1.xml' : '../slideLayouts/slideLayout2.xml' },
  ];
  if (notesIndex) {
    items.push({ id: 'rId2', type: RT.notesSlide, target: `../notesSlides/notesSlide${notesIndex}.xml` });
  }
  return relsXml(items);
}

/** 条目多的时候把正文字号收小，避免溢出方框（PowerPoint 打开时不重排） */
function bulletSize(count) {
  if (count <= 6) return 1800;
  if (count <= 8) return 1600;
  if (count <= 11) return 1400;
  return 1200;
}

// ─────────────────────────────────────────────────────────── ZIP 写入器

/** CRC-32（IEEE 802.3，多项式 0xEDB88320 反射），自己实现，不引三方库 */
const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i += 1) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

/** DOS 时间戳（ZIP 用，1980 年起算） */
function dosDateTime(date) {
  const year = Math.min(2107, Math.max(1980, date.getFullYear()));
  return {
    date: ((year - 1980) << 9) | ((date.getMonth() + 1) << 5) | date.getDate(),
    time: (date.getHours() << 11) | (date.getMinutes() << 5) | Math.floor(date.getSeconds() / 2),
  };
}

/**
 * 最小 ZIP 写入器：local file header + data，收尾写 central directory + EOCD。
 * 只支持 deflate(8) 与 store(0)，不加密、不 zip64（pptx 不会到 4GB）。
 */
class ZipWriter {
  constructor() {
    this.entries = [];
    this.chunks = [];
    this.offset = 0;
  }

  /** 追加一个文件；名字用 UTF-8（这里全是 ASCII），内容 UTF-8 文本或 Buffer */
  add(name, content) {
    const raw = Buffer.isBuffer(content) ? content : Buffer.from(String(content), 'utf8');
    const deflated = deflateRawSync(raw, { level: 9 });
    const useDeflate = deflated.length < raw.length;
    const data = useDeflate ? deflated : raw;
    const method = useDeflate ? 8 : 0;
    const nameBuf = Buffer.from(name, 'utf8');
    const { date, time } = dosDateTime(new Date());

    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0); // local file header 签名
    header.writeUInt16LE(20, 4); // 需要的解压版本 2.0
    header.writeUInt16LE(0, 6); // 通用标志位（文件名按 ASCII/UTF-8 一致，无需 bit11）
    header.writeUInt16LE(method, 8);
    header.writeUInt16LE(time, 10);
    header.writeUInt16LE(date, 12);
    header.writeUInt32LE(crc32(raw), 14);
    header.writeUInt32LE(data.length, 18); // 压缩后大小
    header.writeUInt32LE(raw.length, 22); // 原始大小
    header.writeUInt16LE(nameBuf.length, 26);
    header.writeUInt16LE(0, 28); // extra field 长度

    const localOffset = this.offset;
    this.chunks.push(header, nameBuf, data);
    this.offset += header.length + nameBuf.length + data.length;
    this.entries.push({
      name: nameBuf,
      method,
      crc: crc32(raw),
      compSize: data.length,
      rawSize: raw.length,
      time,
      date,
      localOffset,
    });
    return this;
  }

  finish() {
    const cdStart = this.offset;
    const cdChunks = [];
    let cdSize = 0;
    for (const e of this.entries) {
      const h = Buffer.alloc(46);
      h.writeUInt32LE(0x02014b50, 0); // central directory header 签名
      h.writeUInt16LE(20, 4); // 创建版本
      h.writeUInt16LE(20, 6); // 需要的解压版本
      h.writeUInt16LE(0, 8); // 标志位
      h.writeUInt16LE(e.method, 10);
      h.writeUInt16LE(e.time, 12);
      h.writeUInt16LE(e.date, 14);
      h.writeUInt32LE(e.crc, 16);
      h.writeUInt32LE(e.compSize, 20);
      h.writeUInt32LE(e.rawSize, 24);
      h.writeUInt16LE(e.name.length, 28);
      h.writeUInt16LE(0, 30); // extra
      h.writeUInt16LE(0, 32); // comment
      h.writeUInt16LE(0, 34); // 起始磁盘号
      h.writeUInt16LE(0, 36); // 内部属性
      h.writeUInt32LE(0, 38); // 外部属性
      h.writeUInt32LE(e.localOffset, 42);
      cdChunks.push(h, e.name);
      cdSize += h.length + e.name.length;
    }
    const eocd = Buffer.alloc(22);
    eocd.writeUInt32LE(0x06054b50, 0); // EOCD 签名
    eocd.writeUInt16LE(0, 4);
    eocd.writeUInt16LE(0, 6);
    eocd.writeUInt16LE(this.entries.length, 8);
    eocd.writeUInt16LE(this.entries.length, 10);
    eocd.writeUInt32LE(cdSize, 12);
    eocd.writeUInt32LE(cdStart, 16);
    eocd.writeUInt16LE(0, 20); // 注释长度
    return Buffer.concat([...this.chunks, ...cdChunks, eocd]);
  }
}

// ─────────────────────────────────────────────────────────── 组装 pptx

/** 把 outline.json 抹平成内部结构（宽进：类型不对就取默认，不炸） */
function normalizeOutline(raw) {
  const obj = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const warn = [];
  const str = (v) => (typeof v === 'string' ? v : v == null ? '' : String(v));

  let slides = obj.slides;
  if (slides === undefined || slides === null) slides = [];
  if (!Array.isArray(slides)) {
    warn.push('slides 不是数组，已按空处理');
    slides = [];
  }

  const normSlides = slides.map((s, index) => {
    const o = s && typeof s === 'object' && !Array.isArray(s) ? s : {};
    let bullets = o.bullets !== undefined ? o.bullets : o.content;
    if (bullets === undefined || bullets === null) bullets = [];
    if (typeof bullets === 'string') bullets = bullets.split('\n');
    if (!Array.isArray(bullets)) {
      warn.push(`第 ${index + 1} 页的 bullets 不是数组/字符串，已忽略`);
      bullets = [];
    }
    const normBullets = [];
    for (const b of bullets) {
      if (b === null || b === undefined) continue;
      if (typeof b === 'object') {
        const text = str(b.text !== undefined ? b.text : b.content).trim();
        if (!text) continue;
        normBullets.push({ text, level: Number.isFinite(Number(b.level)) ? Number(b.level) : 0 });
      } else {
        const text = str(b).trim();
        if (!text) continue;
        normBullets.push({ text, level: 0 });
      }
    }
    return {
      title: str(o.title).trim() || `第 ${index + 1} 节`,
      bullets: normBullets,
      notes: str(o.notes).trim(),
    };
  });

  return {
    title: str(obj.title).trim() || '演示文稿',
    subtitle: str(obj.subtitle).trim(),
    author: str(obj.author).trim(),
    slides: normSlides,
    warn,
  };
}

/** 生成所有部件（路径 → 内容），路径用 `/`，符合 OPC 包内命名 */
function buildParts(outline) {
  const parts = new Map();
  // 第 1 页是封面；后面每页对应 outline.slides 的一项
  const total = 1 + outline.slides.length;
  const notesByIndex = new Map(); // slideIndex → 备注文本
  for (let i = 1; i <= total; i += 1) {
    const s = i === 1 ? null : outline.slides[i - 2];
    if (s && s.notes) notesByIndex.set(i, s.notes);
  }

  parts.set('[Content_Types].xml', contentTypesXml(total, notesByIndex));
  parts.set('_rels/.rels', rootRelsXml());
  parts.set('docProps/core.xml', coreXml(outline));
  parts.set('ppt/presentation.xml', presentationXml(total, notesByIndex));
  parts.set('ppt/_rels/presentation.xml.rels', presentationRelsXml(total, notesByIndex));
  parts.set('ppt/slideMasters/slideMaster1.xml', slideMasterXml());
  parts.set('ppt/slideMasters/_rels/slideMaster1.xml.rels', slideMasterRelsXml());
  parts.set('ppt/slideLayouts/slideLayout1.xml', slideLayout1Xml());
  parts.set('ppt/slideLayouts/slideLayout2.xml', slideLayout2Xml());
  parts.set('ppt/slideLayouts/_rels/slideLayout1.xml.rels', slideLayoutRelsXml());
  parts.set('ppt/slideLayouts/_rels/slideLayout2.xml.rels', slideLayoutRelsXml());
  parts.set('ppt/theme/theme1.xml', themeXml());

  for (let i = 1; i <= total; i += 1) {
    const isCover = i === 1;
    const slide = isCover
      ? { title: outline.title, subtitle: outline.subtitle, bullets: [] }
      : { title: outline.slides[i - 2].title, bullets: outline.slides[i - 2].bullets };
    parts.set(`ppt/slides/slide${i}.xml`, slideXml(slide, isCover));
    parts.set(`ppt/slides/_rels/slide${i}.xml.rels`, slideRelsXml(isCover, notesByIndex.get(i) ? i : null));
  }

  if (notesByIndex.size > 0) {
    parts.set('ppt/notesMasters/notesMaster1.xml', notesMasterXml());
    parts.set('ppt/notesMasters/_rels/notesMaster1.xml.rels', notesMasterRelsXml());
    for (const [i, text] of notesByIndex) {
      parts.set(`ppt/notesSlides/notesSlide${i}.xml`, notesSlideXml(text));
      parts.set(`ppt/notesSlides/_rels/notesSlide${i}.xml.rels`, notesSlideRelsXml(i));
    }
  }
  return parts;
}

// ─────────────────────────────────────────────────────────── 入口

function main() {
  const argv = process.argv.slice(2);
  if (argv.length === 0 || argv.includes('--help') || argv.includes('-h')) {
    process.stdout.write(HELP);
    process.exit(argv.length === 0 ? 2 : 0);
  }
  if (argv.length < 2) usageFail('需要两个参数：<outline.json> <out.pptx>');

  const outlinePath = resolve(argv[0]);
  const outPath = resolve(argv[1]);

  if (!existsSync(outlinePath)) fail(`找不到大纲文件：${outlinePath}`);

  let rawText;
  try {
    rawText = readFileSync(outlinePath, 'utf8');
  } catch (e) {
    fail(`读不了大纲文件（${outlinePath}）：${e.message}`);
  }
  // 去掉 BOM，不然 JSON.parse 会报 "Unexpected token"
  if (rawText.charCodeAt(0) === 0xfeff) rawText = rawText.slice(1);

  let parsed;
  try {
    parsed = JSON.parse(rawText);
  } catch (e) {
    fail(`大纲文件不是合法 JSON（${outlinePath}）：${e.message}`);
  }

  const outline = normalizeOutline(parsed);
  for (const w of outline.warn) process.stderr.write('[make-pptx] 警告：' + w + '\n');

  const parts = buildParts(outline);

  const zip = new ZipWriter();
  // [Content_Types].xml 放第一个条目：符合惯例，也方便任何工具第一时间读到
  for (const [name, content] of parts) zip.add(name, content);
  const buf = zip.finish();

  try {
    const dir = dirname(outPath);
    if (dir && !existsSync(dir)) mkdirSync(dir, { recursive: true });
    writeFileSync(outPath, buf);
  } catch (e) {
    fail(`写不了输出文件（${outPath}）：${e.message}`);
  }

  const slideCount = 1 + outline.slides.length;
  const notesCount = outline.slides.filter((s) => s.notes).length;
  // 机器可读的一行，Dart 侧可以按 [make-pptx] 前缀解析
  process.stdout.write(
    `[make-pptx] ok slides=${slideCount} notes=${notesCount} parts=${parts.size} bytes=${buf.length} out=${outPath}\n`,
  );
}

// 只有被直接 `node make-pptx.mjs` 调用时才执行；被 import 时不自动跑（方便单测）
const isDirectRun = (() => {
  if (!process.argv[1]) return false;
  try {
    return pathToFileURL(resolve(process.argv[1])).href === import.meta.url;
  } catch {
    return false;
  }
})();

if (isDirectRun) main();

export { buildParts, normalizeOutline, ZipWriter, crc32, main };
