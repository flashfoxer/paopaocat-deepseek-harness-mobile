#!/usr/bin/env node
// 修 README 的语言版里那些**指向中文锚点**的目录链接。
//
// 为什么会坏：翻译时标题变成了目标语言，但 Markdown 的 `#anchor` 是按**标题文字**
// 生成的。于是英文版里 `[Screenshots](#-截图)` 点下去什么都不会发生（锚点不存在）。
// 这类链接在编辑器预览里看着完全正常，只有真的点一下才发现 —— 所以用脚本按
// GitHub 的 slug 规则重算，不靠肉眼。
//
// GitHub 规则：转小写 → 去掉"非字母/数字/空格/连字符/下划线"的字符（emoji 在这种
// 情况下被删掉，于是以 emoji 开头的标题会留下一个前导 `-`）→ 空格换成 `-`。
import fs from 'node:fs';

const slug = (s) =>
  s
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s_-]/gu, '')
    // ⚠️ 这里**不能**再 trim：emoji 被删掉后会留下**前导空格**，GitHub 把它变成
    //    前导 `-`（所以 `## ✨ Feature Overview` 的锚点是 `#-feature-overview`，
    //    而不是 `#feature-overview`）。源文件里 `#-功能一览` 就是这么来的。
    .replace(/\s+/g, '-');

for (const file of process.argv.slice(2)) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');

  // ① 收集标题 → slug
  const byText = new Map();
  for (const l of lines) {
    const m = l.match(/^#{2,6}\s+(.*)$/);
    if (!m) continue;
    byText.set(m[1].trim(), slug(m[1]));
    // 同时登记"去掉 emoji 后的纯文字"，TOC 里常只写文字
    const plain = m[1].replace(/[^\p{L}\p{N}\s_-]/gu, '').trim();
    if (plain) byText.set(plain, slug(m[1]));
  }

  // ② 修 TOC 行的锚点
  let fixed = 0;
  const out = lines.map((l) => {
    const m = l.match(/^(\s*[-*]\s*)\[(.+?)\]\(#(.+?)\)(.*)$/);
    if (!m) return l;
    const [, bullet, text, , tail] = m;
    // ⚠️ 两路查：TOC 文本常常**带 emoji**（`🖼️ Screenshots`）而标题不带
    //    （`## Screenshots`），只查原文会漏掉一半，剩下"看着有链接、点了没反应"。
    const clean = text.replace(/[^\p{L}\p{N}\s_-]/gu, '').trim();
    const want = byText.get(text.trim()) ?? byText.get(clean);
    if (!want) return l;
    const current = m[3];
    if (current === want) return l;
    fixed++;
    return `${bullet}[${text}](#${want})${tail}`;
  });

  fs.writeFileSync(file, out.join('\n'));
  console.log(`${file}: 修锚点 ${fixed} 处`);
}
