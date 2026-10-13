---
name: study-cards
description: "记忆卡 / 问答卡 / 自测题"
---

# 生成学习卡片

本技能负责：把材料变成**问 / 答成对**的卡片，能直接背、也能导入复习工具。
什么时候用：用户说「做成学习卡片 / 记忆卡 / 帮我出题自测 / 这个知识点拆成问答」。

产物：
- `卡片-<主题>.md`：人能读的卡片（正面 / 背面 / 标签 / 出处）
- `卡片-<主题>.csv`：三列 `front,back,tags`，供 Anki 等工具导入
- 可选 `卡片-<主题>.html`：离线自包含翻卡页面（内联 `<style>` + 内联 `<script>`，**不引用任何外部资源**）

## 0. 先确认（一次问完）
- 材料在哪（工作区文件路径）？还是只有主题、要你按常识出题？
- 卡片数量与深度（考试速记 / 理解型 / 概念辨析）？
- 语言（中文 / 英文 / 双语）；要不要出处标注？
- 只要问答，还是要填空、选择题、简答混合？

**只有主题没有材料时**：明确告诉用户「我会按通用知识出题，可能和你教材口径不同」，
并在 CSV 的 `tags` 里加 `通用知识` 以便区分。

## 1. 读材料
```sh
node -e "const t=require('node:fs').readFileSync('教材.md','utf8');console.log('字符数',t.length,'段落',t.split(/\n\s*\n/).length);console.log(t.slice(0,3000))"
```
先列出材料的章节/小节清单（用脚本抽标题）：
```sh
node -e "const t=require('node:fs').readFileSync('教材.md','utf8');console.log(t.split(/\r?\n/).filter(l=>/^#{1,4} /.test(l)).join('\n'))"
```
**这份清单就是第 4 步覆盖度检查的对照表**，先存下来。

## 2. 写卡片
每张卡片必须满足：
- **正面只问一件事**（不要「以下哪几个是…」堆在一起）；问法具体，不看答案也能懂在问什么。
- **背面答完整但不啰嗦**：定义类给一句定义 + 一个关键限定；区分类必须同时给两边的判据。
- 不写「见上」「同上」这种脱离语境看不懂的内容。
- 顺序：一张卡片 = 一个知识点；同一知识点的多面拆成多张。

卡片格式：
```markdown
### 卡片 1
- **正面**：什么情况下必须用 TCP 而不是 UDP？
- **背面**：需要可靠、有序、可重传的字节流时（文件传输、网页、邮件）；UDP 用于能容忍丢包的实时场景。
- **标签**：网络 传输层
- **出处**：教材 3.2 节
```

写文件用**写文件工具**；CSV 由脚本从你写好的 md 抽取生成，避免手抄出错。
卡片必须严格用 `### 卡片 N` 开头、字段用 `- **正面**：` / `- **背面**：` / `- **标签**：`，脚本靠这个切分：
```js
// cards2csv.mjs
import { readFileSync, writeFileSync } from 'node:fs';
const blocks = readFileSync(process.argv[2], 'utf8')
  .split(/\n(?=### 卡片 )/)
  .filter((b) => /\*\*正面\*\*/.test(b));
const esc = (s) => '"' + String(s).replace(/\s+/g, ' ').trim().replace(/"/g, '""') + '"';
const rows = blocks.map((b) => {
  const get = (k) => (b.match(new RegExp('\\*\\*' + k + '\\*\\*：(.+)')) || [, ''])[1];
  return [esc(get('正面')), esc(get('背面')), esc(get('标签'))].join(',');
});
writeFileSync(process.argv[3], '\ufefffront,back,tags\n' + rows.join('\n') + '\n');
console.log('[cards] 写出', rows.length, '张 →', process.argv[3]);
```
```sh
node cards2csv.mjs "卡片-主题.md" "卡片-主题.csv"
```

## 3. 可选：离线翻卡页面
生成 `卡片-主题.html`：卡片正面先显示、点一下显示背面，加「记住了 / 再来」两个原地切换的按钮。
全部用内联 `<style>` 与内联 `<script>` 实现，**不要引用任何 CDN、字体、图片外链**。
写完后用 node 抽查没有外部引用：
```sh
node -e "const h=require('node:fs').readFileSync('卡片-主题.html','utf8');console.log('字节',h.length,'外部引用',/https?:\/\//.test(h.replace(/xmlns=\"[^\"]+\"/g,''))?'有(要删)':'无')"
```

## 4. 覆盖度检查（必做）
对照第 1 步抽出的章节清单，逐节确认有没有卡片；缺的补上，或在回复里说明「某一节我没出题，原因是…」。
```sh
node -e "const t=require('node:fs').readFileSync('卡片-主题.md','utf8');console.log('卡片数',(t.match(/^### 卡片 /gm)||[]).length)"
```

## 5. 交付
回复里给：卡片数量、覆盖了哪些章节、**产物路径原样**，并贴 2–3 张示例卡片正文。

## 诚实约束
- 卡片内容只能来自材料，或明确标注为「通用知识」的常识；**不要编造条款、数字、引用页码**。
- 材料里说法有歧义时，背面写清「按材料口径」并把歧义列在文件末尾的「待确认」一节。
- 读不到文件就贴**真实报错**；这台设备上没有 python、没有 Anki，`.pdf` 读不了，
  需要 PDF 时如实说明并改请用户提供 `.txt`/`.md`/**`.docx`**。
  `.docx` 现在**能读**：`node "$DSH_ANDROID_TOOLBOX/read-docx.mjs" 材料.docx --out 材料.md`
  （只读正文；图片不抽、页眉页脚不读）。`.xlsx` 同类：`read-xlsx.mjs`。
