// make-pptx.mjs + pptx-design.mjs（node 排版引擎）的测试。
//
// ## 为什么这些断言必须存在
//
// 生成 .pptx 的代码**错了不会当场报错**：它只会产出一个"打开时说文件已损坏"、
// 或者"能打开但字压出版心"的文件 —— 前者用户装不上，后者用户看不下去。
// 所以这里的断言分三层：
//
//   ① **容器/部件层**：ZIP 合法、每段 XML 能被解析、每个关系都有目标、
//      Content_Types 覆盖了每一个部件、形状不越界 —— 这一层决定"能不能打开"；
//   ② **排版层**：字号随内容单调收缩、放不下会拆续页且**不丢不重**、
//      卡片分栏数与条数对得上 —— 这一层决定"看不看得清"；
//   ③ **设计层**：版式选择、主题配色真的写进了 XML、页码不在封面上 ——
//      这一层决定"像不像一份做过的 PPT"。
//
// 跑法：node install/test-make-pptx.mjs   （不需要设备、不需要网络、不装任何包）
// 退出码：0 全过；1 有失败。

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync } from 'node:zlib';

import { zipRead } from '../app/assets/toolbox/office-zip.mjs';
import {
  countLines,
  fitBullets,
  inferLayout,
  measureTextEmu,
  resolveTheme,
  splitBullets,
} from '../app/assets/toolbox/pptx-design.mjs';
import { buildParts, normalizeOutline } from '../app/assets/toolbox/make-pptx.mjs';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const REPO = resolve(HERE, '..');
const SCRIPT = join(REPO, 'app', 'assets', 'toolbox', 'make-pptx.mjs');

let passed = 0;
const failures = [];

async function test(name, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`  ok   ${name}`);
  } catch (e) {
    failures.push([name, e]);
    console.log(`  FAIL ${name}\n       ${(e && e.message) || e}`);
  }
}

function section(t) { console.log(`\n== ${t} ==`); }

const work = mkdtempSync(join(tmpdir(), 'make-pptx-test-'));
process.on('exit', () => { try { rmSync(work, { recursive: true, force: true }); } catch {} });

// ─────────────────────────────────────────────────────────── 生成与读取

/** 直接调引擎生成（不走子进程）—— 拿到的是包内各部件的内容。 */
function generate(outline) {
  const normalized = normalizeOutline(outline);
  const built = buildParts(normalized);
  return { normalized, built };
}

/** 走 CLI 生成一个真文件（验命令行那一层 + 能拿到 zip 字节）。 */
function generateFile(outline, name) {
  const dir = join(work, name);
  mkdirSync(dir, { recursive: true });
  const outlinePath = join(dir, 'outline.json');
  const outPath = join(dir, 'out.pptx');
  writeFileSync(outlinePath, JSON.stringify(outline), 'utf8');
  const r = spawnSync(process.execPath, [SCRIPT, outlinePath, outPath], { encoding: 'utf8' });
  assert.equal(r.status, 0, `make-pptx 退出码 ${r.status}：${r.stderr}`);
  assert.ok(existsSync(outPath), '没生成文件');
  return { outPath, stdout: r.stdout, stderr: r.stderr, buf: readFileSync(outPath) };
}

// ─────────────────────────────────────────────────────────── ① 容器层校验

/**
 * 极简 XML 良构检查（不引依赖）。
 *
 * 只做这几件事：标签成对/自闭合、属性有引号、不出现裸 `&`、根元素唯一。
 * 这已经足够抓住"少一个 `</p:sp>`、把 `&` 写成裸的、引号漏了"这类会让人
 * 打不开文件的错 —— 而这正是生成器最容易犯的错。
 */
function assertXmlWellFormed(xml, label) {
  const stack = [];
  let i = 0;
  let roots = 0;
  while (i < xml.length) {
    const lt = xml.indexOf('<', i);
    if (lt < 0) break;
    // 标签之间的文本里不能出现裸 '&'
    const text = xml.slice(i, lt);
    const amp = text.indexOf('&');
    if (amp >= 0) {
      const rest = text.slice(amp);
      assert.ok(/^&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);/.test(rest),
        `${label}：文本里有没转义的 &（…${text.slice(Math.max(0, amp - 20), amp + 20)}…）`);
    }
    if (xml.startsWith('<?', lt) || xml.startsWith('<!', lt)) {
      const gt = xml.indexOf('>', lt);
      i = gt + 1;
      continue;
    }
    const gt = xml.indexOf('>', lt);
    assert.ok(gt > 0, `${label}：第 ${lt} 个字符处标签没有闭合的 >`);
    const raw = xml.slice(lt + 1, gt);
    // 属性值必须是引号包起来的（漏引号 = 文件损坏）
    const attrRe = /[\w:.-]+\s*=\s*("[^"]*"|'[^']*')/g;
    let m;
    let consumed = '';
    while ((m = attrRe.exec(raw))) consumed += m[0];
    if (raw.includes('=')) {
      assert.ok(consumed.length > 0, `${label}：<${raw}> 的属性写得不合法`);
    }
    if (raw.startsWith('/')) {
      const name = raw.slice(1).trim();
      const top = stack.pop();
      assert.equal(top, name, `${label}：</${name}> 对不上（栈顶是 ${top}）`);
    } else if (raw.endsWith('/')) {
      // 自闭合
    } else {
      const name = raw.split(/[\s/]/)[0];
      if (stack.length === 0) roots += 1;
      stack.push(name);
    }
    i = gt + 1;
  }
  assert.equal(stack.length, 0, `${label}：有标签没闭合（还剩 ${stack.join(',')}）`);
  assert.equal(roots, 1, `${label}：根元素应当只有一个，实际 ${roots}`);
}

/** 整包结构检查：XML、关系目标、Content_Types 覆盖、形状越界。 */
function assertPackageSane(parts, label) {
  const names = [...parts.keys()];
  assert.ok(names.includes('[Content_Types].xml'), `${label}：缺 [Content_Types].xml（必损坏）`);

  for (const name of names) {
    if (!name.endsWith('.xml') && !name.endsWith('.rels')) continue;
    const buf = parts.get(name);
    const xml = Buffer.isBuffer(buf) ? buf.toString('utf8') : String(buf);
    assert.ok(xml.startsWith('<?xml'), `${label}：${name} 没有 XML 声明`);
    assertXmlWellFormed(xml, `${label}/${name}`);
  }

  // 关系目标必须存在（少一个 PowerPoint 就说"需要修复"）
  for (const name of names) {
    if (!name.endsWith('.rels')) continue;
    const xml = parts.get(name).toString('utf8');
    const base = name.replace(/_rels\/[^/]*$/, '');
    const re = /Target="([^"]+)"/g;
    let m;
    while ((m = re.exec(xml))) {
      const target = m[1];
      if (/^https?:/.test(target)) continue;
      const resolved = new URL(target, `file:///${base}`).pathname.slice(1);
      assert.ok(parts.has(resolved),
        `${label}：${name} 指向不存在的部件 ${target}（→ ${resolved}）`);
    }
  }

  // Content_Types 必须覆盖每个部件
  const ct = parts.get('[Content_Types].xml').toString('utf8');
  const overrides = new Set([...ct.matchAll(/PartName="\/([^"]+)"/g)].map((x) => x[1]));
  const defaults = new Set([...ct.matchAll(/Default Extension="([^"]+)"/g)].map((x) => x[1].toLowerCase()));
  for (const name of names) {
    if (name === '[Content_Types].xml') continue;
    if (overrides.has(name)) continue;
    const ext = name.split('.').pop().toLowerCase();
    assert.ok(defaults.has(ext), `${label}：${name} 既没 Override 也没 Default 覆盖（PowerPoint 会判损坏）`);
  }

  // 形状必须落在画布内（否则内容看不见 / 打印被切）
  const slideNames = names.filter((n) => /^ppt\/slides\/slide\d+\.xml$/.test(n));
  assert.ok(slideNames.length > 0, `${label}：一张幻灯片都没有`);
  for (const name of slideNames) {
    // ⚠️ 先摘掉 `<p:grpSpPr>`：它是每个 spTree 都有的"空组"标记（0×0），
    //    不是可见形状。不摘掉就会把每一页都判成"有个 0×0 的形状"。
    const xml = parts.get(name).toString('utf8')
      .replace(/<p:grpSpPr>[\s\S]*?<\/p:grpSpPr>/g, '');
    const re = /<a:off x="(-?\d+)" y="(-?\d+)"\/><a:ext cx="(\d+)" cy="(\d+)"\/>/g;
    let m;
    let count = 0;
    while ((m = re.exec(xml))) {
      count += 1;
      const [x, y, cx, cy] = [m[1], m[2], m[3], m[4]].map(Number);
      assert.ok(cx > 0 && cy > 0, `${label}/${name}：形状尺寸为 0（看不见）`);
      assert.ok(x >= -1 && y >= -1, `${label}/${name}：形状从画布外开始（x=${x}, y=${y}）`);
      assert.ok(x + cx <= 12192001, `${label}/${name}：形状右边超出画布（${x + cx}）`);
      assert.ok(y + cy <= 6858001, `${label}/${name}：形状下边超出画布（${y + cy}）`);
    }
    assert.ok(count > 0, `${label}/${name}：一个形状都没有（空页）`);

    // ⚠️ 真正的文字里**不许出现 `<a:p`**：那说明有人把"拼好的段落 XML"
    //    当成普通字符串又转义了一遍 —— 结构校验全绿，界面上却是一坨标签。
    //    （本轮就踩到过：`shape({ text: para(...) })`。）
    for (const t of xml.matchAll(/<a:t[^>]*>([^<]*)<\/a:t>/g)) {
      assert.ok(!t[1].includes('<a:p') && !t[1].includes('</a:t>'),
        `${label}/${name}：正文里露出了 XML 标签（text/paras 用混了）：${t[1].slice(0, 60)}`);
    }
  }
  return { slideCount: slideNames.length };
}

/** 从一段幻灯片 XML 里取"某个形状"的 XML（按形状名定位）。 */
function shapeByName(xml, name) {
  const idx = xml.indexOf(`name="${name}"`);
  if (idx < 0) return '';
  const start = xml.lastIndexOf('<p:sp>', idx);
  const end = xml.indexOf('</p:sp>', idx);
  return xml.slice(start, end + 7);
}

/** 某个形状里第一个 run 的字号（pt）。 */
function shapeFontPt(xml, name) {
  const m = /sz="(\d+)"/.exec(shapeByName(xml, name));
  return m ? Number(m[1]) / 100 : null;
}

/** 从包里抽出每一页的文字（用于"内容不丢"的断言）。 */
function slideTexts(parts) {
  const names = [...parts.keys()]
    .filter((n) => /^ppt\/slides\/slide\d+\.xml$/.test(n))
    .sort((a, b) => Number(a.match(/(\d+)/)[1]) - Number(b.match(/(\d+)/)[1]));
  return names.map((n) => {
    const xml = parts.get(n).toString('utf8');
    return [...xml.matchAll(/<a:t[^>]*>([^<]*)<\/a:t>/g)].map((x) => x[1]).join('\n');
  });
}

// ─────────────────────────────────────────────────────────── 测试数据

const PNG_1PX = (() => {
  // 一张 2x1 的合法 PNG（自己造，不引任何素材文件）
  const w = 2; const h = 1;
  const raw = Buffer.from([0, 255, 0, 0, 0, 0, 255, 0]); // 每行 filter + RGB
  const chunks = [];
  const crcTable = (() => {
    const t = new Int32Array(256);
    for (let n = 0; n < 256; n += 1) {
      let c = n;
      for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c;
    }
    return t;
  })();
  const crc = (b) => {
    let c = -1;
    for (let i = 0; i < b.length; i += 1) c = crcTable[(c ^ b[i]) & 0xff] ^ (c >>> 8);
    return (c ^ -1) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const t = Buffer.from(type, 'ascii');
    const c = Buffer.alloc(4);
    c.writeUInt32BE(crc(Buffer.concat([t, data])));
    return Buffer.concat([len, t, data, c]);
  };
  chunks.push(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 2;
  chunks.push(chunk('IHDR', ihdr));
  chunks.push(chunk('IDAT', deflateSync(raw)));
  chunks.push(chunk('IEND', Buffer.alloc(0)));
  return Buffer.concat(chunks);
})();

const ALL_LAYOUT_DECK = {
  title: '全版式样例',
  subtitle: '每一个版式各一页',
  author: '测试',
  theme: 'ocean',
  footer: '页脚',
  transition: 'fade',
  slides: [
    { layout: 'toc', title: '目录', items: ['第一项', { title: '第二项', text: '说明' }] },
    { layout: 'section', number: '01', title: '章节', subtitle: '说明' },
    { layout: 'bullets', title: '要点', bullets: ['甲', { text: '乙', level: 1 }], notes: '备注一' },
    { layout: 'cards', title: '卡片', items: [{ title: 'A', text: 'aa' }, { title: 'B', text: 'bb' }, { title: 'C', text: 'cc' }] },
    { layout: 'timeline', title: '时间线', steps: [{ title: '一', text: 'x', date: 'Q1' }, { title: '二', text: 'y' }] },
    { layout: 'compare', title: '对比', left: { title: '左', bullets: ['l1', 'l2'] }, right: { title: '右', bullets: ['r1'] } },
    { layout: 'metrics', title: '数字', metrics: [{ value: '92%', label: '完成度', note: '上周' }] },
    { layout: 'chart', title: '柱状', chart: { kind: 'bar', unit: '%', data: [{ label: 'A', value: 10 }, { label: 'B', value: 40 }] } },
    { layout: 'chart', title: '条形', chart: { kind: 'hbar', data: [{ label: 'A', value: 10 }, { label: 'B', value: 40 }] } },
    { layout: 'chart', title: '堆叠', chart: { kind: 'stacked', data: [{ label: 'A', value: 3 }, { label: 'B', value: 1 }] } },
    { layout: 'quote', text: '一句引用。', cite: '出处' },
    { layout: 'end', title: '谢谢' },
  ],
};

// ─────────────────────────────────────────────────────────── ① 容器层

section('① 容器层：文件能不能打开');
{
  await test('最少输入（只有标题）也能生成合法包', () => {
    const { built } = generate({ title: '就一个标题' });
    const info = assertPackageSane(built.parts, '只有标题');
    assert.equal(info.slideCount, 1, '没写 slides 时应当只有封面');
  });

  await test('v1 老写法（title/subtitle/author + bullets）继续可用', () => {
    const { built, normalized } = generate({
      title: '老写法',
      subtitle: '副标题',
      author: '作者',
      slides: [
        { title: '第一页', bullets: ['一', '二'] },
        { title: '第二页', content: '字符串也可以' },
      ],
    });
    assertPackageSane(built.parts, 'v1');
    assert.equal(built.slides, 3);
    const texts = slideTexts(built.parts);
    assert.ok(texts[0].includes('老写法'), '封面标题丢了');
    assert.ok(texts[0].includes('副标题'), '封面副标题丢了');
    assert.ok(texts[1].includes('第一页') && texts[1].includes('一'), '第一页内容丢了');
    assert.ok(texts[2].includes('字符串也可以'), 'content 字符串没被当要点处理');
    assert.equal(normalized.warn.length, 0, `不该有警告：${normalized.warn}`);
  });

  await test('全版式样例：12 种版式都能出页，且整包结构合法', () => {
    const { built } = generate(ALL_LAYOUT_DECK);
    assertPackageSane(built.parts, '全版式');
    const used = new Set(built.layouts);
    for (const l of ['cover', 'toc', 'section', 'bullets', 'cards', 'timeline', 'compare', 'metrics', 'chart', 'quote', 'end']) {
      assert.ok(used.has(l), `版式 ${l} 没被用到（实际：${[...used].join(',')}）`);
    }
  });

  await test('CLI：生成真文件，stdout 有一行机器可读的摘要', () => {
    const { buf, stdout } = generateFile(ALL_LAYOUT_DECK, 'cli');
    assert.match(stdout, /\[make-pptx\] ok slides=\d+ notes=\d+ media=\d+/,
      `摘要格式变了（Dart 侧按它解析）：${stdout}`);
    const parts = zipRead(buf);
    assertPackageSane(parts, 'CLI');
    // 自己写的 ZIP 也要能被别的解压器读懂（office-zip 是独立实现）
    assert.ok(parts.size >= 10, `部件太少：${parts.size}`);
  });

  await test('确定性：同一份大纲两次生成，除文档属性外**逐字节一致**', () => {
    const a = generate(ALL_LAYOUT_DECK).built.parts;
    const b = generate(ALL_LAYOUT_DECK).built.parts;
    assert.deepEqual([...a.keys()].sort(), [...b.keys()].sort(), '部件清单不一致');
    for (const [name, buf] of a) {
      if (name === 'docProps/core.xml') continue; // 里面带生成时间，允许不同
      assert.ok(Buffer.from(buf).equals(Buffer.from(b.get(name))), `${name} 两次生成不一致`);
    }
  });
}

// ─────────────────────────────────────────────────────────── ② 排版层

section('② 排版层：字会不会压出版心');
{
  await test('测量：CJK 比拉丁宽（用它做缩排的判据）', () => {
    // 同样 12 个字符：中文 ≈ 12 em，拉丁 ≈ 6.4 em（这就是缩排要用 CJK 判据的原因）
    assert.ok(measureTextEmu('中文中文中文中文中文中文', 18) > measureTextEmu('abcdefghijkl', 18) * 1.5,
      '同等字符数下中文应当明显比拉丁宽');
    assert.equal(countLines('a b', 1000 * 12700, 100), 1);
    assert.ok(countLines('一'.repeat(20), 5 * 12700 * 10, 10) > 1, '20 个字塞进 50 宽度的框必须换行');
  });

  await test('自动缩排：内容越多字号越小（单调），且**永不超过框高**', () => {
    const box = { w: 10515600, h: 4240000 };
    const one = fitBullets(['短'], box.w, box.h);
    const many = fitBullets(Array.from({ length: 12 }, (_, i) => `第 ${i + 1} 条要点，长度中等，用来撑高度。`), box.w, box.h);
    assert.equal(one.size, 18, `一条短要点应当用最大字号（实际 ${one.size}）`);
    assert.ok(many.size <= one.size, '内容更多时字号不该变大');
    const few = fitBullets(['第一条', '第二条'], box.w, box.h);
    assert.ok(few.size >= many.size, '条目少时字号不该更小');
  });

  await test('放不下时：拆续页，且**所有条目恰好出现一次**（不丢不重）', () => {
    const box = { w: 10515600, h: 4240000 };
    const bullets = Array.from({ length: 30 }, (_, i) =>
      ({ text: `第 ${i + 1} 条：这是一条足够长的要点，长到一行放不下，需要折行之后才可能塞得进去。`, level: 0 }));
    const fit = fitBullets(bullets, box.w, box.h, { minPt: 12 });
    assert.equal(fit.ok, false, '30 条长要点不该一页放得下（这条是分页测试的前提）');
    const pages = splitBullets(bullets, box.w, box.h, { minPt: 12 });
    assert.ok(pages.length >= 2, `应当拆成多页，实际 ${pages.length}`);
    const flat = pages.flat().map((b) => b.text);
    assert.deepEqual(flat, bullets.map((b) => b.text), '拆页必须按顺序不丢不重');
    // 每一页自己都要放得下（否则等于没拆）
    for (const page of pages) {
      const f = fitBullets(page, box.w, box.h, { minPt: 12 });
      assert.ok(f.ok, `拆出来的某一页仍然放不下（${page.length} 条）`);
    }
  });

  await test('要点页真的会拆出续页，且续页标题带后缀', () => {
    const long = {
      title: '很长的一页',
      slides: [{
        title: '长列表',
        bullets: Array.from({ length: 30 }, (_, i) => `第 ${i + 1} 条：内容足够长，长到必须折行，用来把这一页撑爆。`),
      }],
    };
    const { built } = generate(long);
    assert.ok(built.slides >= 3, `应当至少拆出 2 页正文（含封面至少 3 页），实际 ${built.slides}`);
    const texts = slideTexts(built.parts);
    const joined = texts.join('\n');
    for (let i = 1; i <= 30; i += 1) {
      assert.ok(joined.includes(`第 ${i} 条：`), `第 ${i} 条在多页里丢了`);
    }
    assert.ok(joined.includes('（续）'), '续页标题应当带「（续）」后缀');
  });

  await test('正文再长也不会缩到可读下限以下（12pt）', () => {
    const bullets = Array.from({ length: 8 }, () => '一句中等长度的要点，用来验证字号下限。');
    const fit = fitBullets(bullets, 10515600, 4240000, { minPt: 12 });
    assert.ok(fit.size >= 12, `字号不该低于 12pt（实际 ${fit.size}）`);
  });

  await test('卡片：6 条 → 3 列 2 行（分栏跟条数走）', () => {
    const { built } = generate({
      title: 'x',
      slides: [{ layout: 'cards', title: '六个', items: Array.from({ length: 6 }, (_, i) => ({ title: `T${i}`, text: `t${i}` })) }],
    });
    const slide2 = built.parts.get('ppt/slides/slide2.xml').toString('utf8');
    // 每张卡片一个圆角底 + 一个强调条 + 一个文字框 = 3 个形状
    const cards = (slide2.match(/name="卡片底 \d+"/g) || []).length;
    assert.equal(cards, 6, `应当 6 张卡片，实际 ${cards}`);
    // 第一行 3 张卡片的 x 不同、y 相同；第二行 y 不同
    const boxes = [...slide2.matchAll(/<a:off x="(\d+)" y="(\d+)"\/><a:ext cx="(\d+)" cy="(\d+)"\/>/g)]
      .map((m) => ({ x: +m[1], y: +m[2], cx: +m[3], cy: +m[4] }));
    const xs = new Set(boxes.map((b) => b.x));
    assert.ok(xs.size >= 3, `横向应当至少有 3 个不同位置，实际 ${xs.size}`);
  });
}

// ─────────────────────────────────────────────────────────── ③ 设计层

section('③ 设计层：像不像做过的');
{
  await test('主题：6 套配色都能生成，且颜色真的写进了 XML', () => {
    for (const theme of ['ink', 'ocean', 'forest', 'sunrise', 'berry', 'mono']) {
      const { built } = generate({
        title: 'x', theme, slides: [{ layout: 'metrics', title: 'M', metrics: [{ value: '1', label: 'L' }] }],
      });
      const xml = built.parts.get('ppt/slides/slide2.xml').toString('utf8');
      const palette = resolveTheme(theme);
      assert.ok(xml.includes(palette.accent), `主题 ${theme} 的强调色没出现在页面上`);
      assert.ok(xml.includes(palette.ink), `主题 ${theme} 的标题色没出现`);
    }
    // 名字不认识 → 回默认，不炸
    assert.equal(resolveTheme('不存在的主题').key, 'ink');
  });

  await test('转场可选：写了才有 <p:transition>，不写一个都没有', () => {
    const withT = generate({ title: 'x', transition: 'fade', slides: [{ title: 'a', bullets: ['b'] }] }).built;
    const slide2 = withT.parts.get('ppt/slides/slide2.xml').toString('utf8');
    assert.ok(slide2.includes('<p:transition'), '应当有转场');
    assert.ok(slide2.includes('<p:fade/>'), '应当是我们支持的那种转场');
    const without = generate({ title: 'x', slides: [{ title: 'a', bullets: ['b'] }] }).built;
    assert.ok(!without.parts.get('ppt/slides/slide2.xml').toString('utf8').includes('<p:transition'), '不写就别加转场');
    // 不认识的转场名 → 安静地不加（不能把一个错字变成"文件损坏"）
    const bad = generate({ title: 'x', transition: '彩虹特效', slides: [{ title: 'a', bullets: ['b'] }] }).built;
    assert.ok(!bad.parts.get('ppt/slides/slide2.xml').toString('utf8').includes('<p:transition'));
  });

  await test('页码只画在内容页：封面没有页码', () => {
    const { built } = generate(ALL_LAYOUT_DECK);
    const cover = built.parts.get('ppt/slides/slide1.xml').toString('utf8');
    assert.ok(!cover.includes('name="页码"'), '封面不该有页码');
    // 3 号页是章节页（按设计不画页脚），4 号才是普通内容页
    const content = built.parts.get('ppt/slides/slide4.xml').toString('utf8');
    assert.ok(content.includes('name="页码"'), '内容页应当有页码');
    const section = built.parts.get('ppt/slides/slide3.xml').toString('utf8');
    assert.ok(!section.includes('name="页码"'), '章节页不该有页码');
    // 关掉开关就不画
    const off = generate({ title: 'x', pageNumbers: false, slides: [{ title: 'a', bullets: ['b'] }] }).built;
    assert.ok(!off.parts.get('ppt/slides/slide2.xml').toString('utf8').includes('name="页码"'));
  });

  await test('版式推断：不写 layout 时按内容字段猜', () => {
    assert.equal(inferLayout({ bullets: ['a'] }), 'bullets');
    assert.equal(inferLayout({ items: [{ title: 'a' }] }), 'cards');
    assert.equal(inferLayout({ steps: [{ title: 'a' }] }), 'timeline');
    assert.equal(inferLayout({ chart: { data: [] } }), 'chart');
    assert.equal(inferLayout({ left: {}, right: {} }), 'compare');
    assert.equal(inferLayout({ metrics: [{ value: '1' }] }), 'metrics');
    assert.equal(inferLayout({ quote: 'x' }), 'quote');
    assert.equal(inferLayout({ image: 'a.png' }), 'image');
    // 别名与大小写
    assert.equal(inferLayout({ layout: 'Agenda' }), 'toc');
    assert.equal(inferLayout({ layout: 'KPI', metrics: [] }), 'metrics');
    assert.equal(inferLayout({ layout: '乱七八糟', bullets: ['a'] }), 'bullets');
  });

  await test('备注：写进 notesSlide，并带上 notesMaster', () => {
    const { built } = generate({ title: 'x', slides: [{ title: 'a', bullets: ['b'], notes: '给讲者的话' }] });
    assert.ok(built.parts.has('ppt/notesSlides/notesSlide2.xml'), '缺备注页');
    assert.ok(built.parts.has('ppt/notesMasters/notesMaster1.xml'), '缺备注母版');
    const notes = built.parts.get('ppt/notesSlides/notesSlide2.xml').toString('utf8');
    assert.ok(notes.includes('给讲者的话'), '备注文字丢了');
    // 注册进 Content_Types（否则 PowerPoint 判损坏）
    assert.ok(built.parts.get('[Content_Types].xml').toString('utf8').includes('/ppt/notesSlides/notesSlide2.xml'));
  });

  await test('图片：真图片进包（media + blip 关系对得上），坏路径不炸只警告', () => {
    const img = join(work, 'pic.png');
    writeFileSync(img, PNG_1PX);
    const { built, normalized } = generate({
      title: 'x',
      slides: [{ layout: 'image', title: '图', image: img, caption: '图注', bullets: ['说明'] }],
    });
    assertPackageSane(built.parts, '图片');
    const media = [...built.parts.keys()].filter((n) => n.startsWith('ppt/media/'));
    assert.equal(media.length, 1, `应当只有一张图，实际 ${media.length}`);
    assert.equal(built.media, 1);
    const slide2 = built.parts.get('ppt/slides/slide2.xml').toString('utf8');
    assert.ok(slide2.includes('<p:pic>'), '没画出图片');
    const blip = /r:embed="(rId\d+)"/.exec(slide2);
    assert.ok(blip, '图片没有 r:embed');
    const rels = built.parts.get('ppt/slides/_rels/slide2.xml.rels').toString('utf8');
    assert.ok(rels.includes(`Id="${blip[1]}"`), 'blip 的 rId 在关系里找不到');
    assert.ok(rels.includes('media/image1.png'), '关系没指向图片部件');
    assert.ok(built.parts.get('[Content_Types].xml').toString('utf8').includes('Extension="png"'),
      '图片扩展名没注册进 Content_Types');
    assert.ok(slide2.includes('图注'), '图注丢了');
    assert.equal(normalized.warn.length, 0);

    // 找不到图 → 占位 + 警告，但整包仍合法
    const missing = generate({ title: 'x', slides: [{ layout: 'image', title: '图', image: join(work, 'nope.png') }] });
    assertPackageSane(missing.built.parts, '缺图');
    assert.ok(missing.normalized.warn.some((w) => w.includes('找不到图片')), '缺图应当给警告');
    assert.ok(missing.built.parts.get('ppt/slides/slide2.xml').toString('utf8').includes('图片没找到'),
      '缺图处应当画占位说明');
  });

  await test('同一张图用两次只存一份（包体不翻倍）', () => {
    const img = join(work, 'dup.png');
    writeFileSync(img, PNG_1PX);
    const { built } = generate({
      title: 'x',
      slides: [
        { layout: 'image', title: '一', image: img },
        { layout: 'image', title: '二', image: img },
      ],
    });
    const media = [...built.parts.keys()].filter((n) => n.startsWith('ppt/media/'));
    assert.equal(media.length, 1, `同一张图应当只存一份，实际 ${media.length}`);
  });

  await test('行内 `**粗体**` 会被转成真加粗，而不是把星号印在幻灯片上', () => {
    const { built } = generate({
      title: 'x',
      slides: [{ title: '加粗', bullets: ['这一条里有**几个字要加粗**，其余不加。'] }],
    });
    const xml = built.parts.get('ppt/slides/slide2.xml').toString('utf8');
    const texts = [...xml.matchAll(/<a:t[^>]*>([^<]*)<\/a:t>/g)].map((m) => m[1]).join('');
    assert.ok(!texts.includes('**'), `星号不该出现在幻灯片上：${texts}`);
    assert.ok(texts.includes('几个字要加粗'), '加粗的那几个字丢了');
    assert.ok(texts.includes('其余不加'), '普通部分丢了');
    assert.ok(/<a:r><a:rPr[^>]*b="1"/.test(xml), '应当有真的加粗 run');
  });

  await test('超长封面标题**真的降了字号**（不是靠运气没压出去）', () => {
    const long = '这是一个特别特别长的封面标题，长到一行绝对放不下，需要折成好几行才可能显示完整，而且还要再长一点才够本';
    const { built } = generate({ title: long });
    const cover = built.parts.get('ppt/slides/slide1.xml').toString('utf8');
    const pt = shapeFontPt(cover, '主标题');
    assert.ok(pt != null, '找不到主标题');
    assert.ok(pt < 40, `长标题必须从 40pt 往下降（实际 ${pt}pt）`);
    assert.ok(pt >= 22, `不该降到不体面的字号（实际 ${pt}pt）`);
    // 短标题就该用满 40pt（否则等于所有标题都被缩小了）
    const short = generate({ title: '短标题' }).built.parts.get('ppt/slides/slide1.xml').toString('utf8');
    assert.equal(shapeFontPt(short, '主标题'), 40);
  });

  await test('一条 5000 字的要点会被**切开并接上**（不丢字、顺序不乱）', () => {
    // 每 500 字放一个【块N】标记：既能验"一个字都没丢"，也能验"顺序没被打乱"
    const text = Array.from({ length: 10 }, (_, i) => `${'甲乙丙丁戊己庚辛壬癸'.repeat(50)}【块${i}】`).join('');
    assert.equal(text.length, 10 * 504);
    const { built } = generate({ title: 'x', slides: [{ title: '巨长', bullets: [text] }] });
    assert.ok(built.slides >= 3, `5000 字应当切成多页，实际 ${built.slides} 页`);
    const joined = slideTexts(built.parts).join('');
    const positions = [];
    for (let i = 0; i < 10; i += 1) {
      const at = joined.indexOf(`【块${i}】`);
      assert.ok(at >= 0, `【块${i}】在多页里丢了`);
      positions.push(at);
    }
    for (let i = 1; i < positions.length; i += 1) {
      assert.ok(positions[i] > positions[i - 1], `分页顺序乱了：【块${i}】出现在【块${i - 1}】前面`);
    }
    // 每块之间的 500 个"甲乙丙丁…"也必须在（不能被截断成短块）
    for (let i = 0; i < 10; i += 1) {
      const seg = '甲乙丙丁戊己庚辛壬癸'.repeat(50);
      assert.ok(joined.includes(seg), `第 ${i} 块的正文被截断或丢字了`);
    }
  });

  await test('标题很长也不越界（引擎兜底，不靠模型算坐标）', () => {
    const { built } = generate({
      title: '这是一个特别特别长的封面标题，长到一行绝对放不下，需要折成好几行才可能显示完整，用来验证版心保护',
      slides: [{ title: '同样很长的一个小节标题，长到应当折行，但绝不允许压到正文或页脚上去，否则就白做了', bullets: ['a'] }],
    });
    assertPackageSane(built.parts, '长标题');
  });
}

// ─────────────────────────────────────────────────────────── 容错

section('容错：脏输入不许把整份 PPT 打死');
{
  await test('slides 不是数组 / bullets 是数字 / layout 写错 → 生成 + 警告', () => {
    const { built, normalized } = generate({ title: 'x', slides: 'oops' });
    assertPackageSane(built.parts, 'slides 非数组');
    assert.ok(normalized.warn.some((w) => w.includes('slides 不是数组')));

    const b2 = generate({ title: 'x', slides: [{ title: 'a', bullets: 42 }, { layout: '???', title: 'b', bullets: ['ok'] }] });
    assertPackageSane(b2.built.parts, 'bullets 数字');
    assert.ok(b2.normalized.warn.some((w) => w.includes('bullets 不是数组')));
  });

  await test('空的 slides / 空要点 / 空字符串标题 → 都有兜底', () => {
    assertPackageSane(generate({}).built.parts, '空大纲');
    assertPackageSane(generate({ title: '', slides: [{}] }).built.parts, '空页');
    assertPackageSane(generate({ title: 'x', slides: [{ title: '', bullets: [] }] }).built.parts, '空标题空要点');
  });

  await test('超长单条要点（一条 5000 字）不会撑爆形状', () => {
    const { built } = generate({ title: 'x', slides: [{ title: '巨长', bullets: ['字'.repeat(5000)] }] });
    assertPackageSane(built.parts, '5000 字一条');
  });
}

// ─────────────────────────────────────────────────────────── 汇总

console.log(`\n${'='.repeat(62)}`);
if (failures.length === 0) {
  console.log(`全部通过（${passed} 项）—— 全程本地生成，不碰网络、不装依赖`);
  process.exit(0);
}
console.log(`失败 ${failures.length} 项 / 通过 ${passed} 项`);
for (const [n, e] of failures) {
  console.log(`  · ${n}`);
  if (e && e.stack) console.log(`      ${String(e.stack).split('\n').slice(1, 3).join('\n      ')}`);
}
process.exit(1);
