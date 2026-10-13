---
name: doc-processing
description: "文档摘要/改写/纠错/转格式（Markdown、HTML）"
---

# 文档处理

本技能负责：对**工作区里真实存在的文件**做摘要 / 改写 / 纠错 / 结构化 / 转格式，并把结果写成新文件。
什么时候用：用户说「帮我处理这份文档 / 精炼一下 / 改通顺 / 改成 Markdown / 转成网页」。

## 0. 先定位文件并确认要做什么（一次问完）
- 文件在哪（工作区路径）？要哪种处理：摘要 / 改写 / 纠错 / 转换格式 / 提取结构（标题层级、表格）？
- 输出语言与语气（原文语体保持，还是改成口语/正式）？要不要保留原文？

工作区里有哪些文件（先看一眼再问）：
```sh
node -e "const f=require('node:fs');for(const d of f.readdirSync('.',{withFileTypes:true}))console.log(d.isDirectory()?'[目录] '+d.name:d.name,f.statSync(d.name).size)"
```

## 1. 读文件（必须真的读）
```sh
node -e "const t=require('node:fs').readFileSync('原文.md','utf8');console.log('字符数',t.length);console.log(t.slice(0,3000))"
```
超过几万字符时**不要**一次全部打印，分段看：
```sh
node -e "const t=require('node:fs').readFileSync('原文.txt','utf8');console.log(t.slice(0,4000))"
node -e "const t=require('node:fs').readFileSync('原文.txt','utf8');console.log(t.slice(4000,8000))"
```

能处理的格式：`.md` / `.txt` / `.csv` / `.json` / `.html` / 源码文件（都是纯文本），
以及 `.docx`（**有现成脚本读**，见下）。
**不能**处理：`.pdf`、`.doc`（老式二进制 Word）、`.xls`、扫描件图片（这台设备上没有 PDF/OCR 库）。
`.docx` / `.xlsx` 本质是 ZIP + XML，本机随包带了读它们的脚本 —— **不要自己手写解析**，
直接调（第 6 节有命令）。`.doc`（没有 `x`）是另一种二进制格式，读不了，如实说并请用户另存为 `.docx`。

## 2. 写处理脚本（推荐）或直接改写
- 只做「抽取 + 结构化」时写脚本，产出可复现的文件：
  ```sh
  node 处理.mjs 原文.md > 处理后.md
  ```
  脚本用 node 内置模块读写，**不要**用 `sed -i`、`awk` 之类去改文件（mksh 上行为不一致，也容易毁原文）。
- 需要语言层面的改写（通顺、去口语、纠错）时，由你自己改写文本，再用**写文件工具**落盘。

## 3. 产物
默认产出（都落在工作区，原文件**不改动**）：
- `处理后-<原名>.md`：处理结果
- `处理说明.md`（可选，改动多时给）：改了什么、依据是什么、哪些地方没把握

需要 HTML 时生成**离线自包含**的一份（内联 `<style>`，**不引用任何外部 CDN/字体/图片**）：
```sh
node -e "const t=require('node:fs').readFileSync('处理后.md','utf8');const esc=(s)=>s.replace(/[&<>]/g,(c)=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));const html='<!doctype html><meta charset=\"utf-8\"><title>文档</title><style>body{font:16px/1.7 system-ui;max-width:44em;margin:2em auto;padding:0 1em}</style><pre style=\"white-space:pre-wrap\">'+esc(t)+'</pre>';require('node:fs').writeFileSync('文档.html',html);console.log('已写 文档.html',html.length,'字节')"
```

## 4. 自检与交付
```sh
node -e "const f=require('node:fs');for(const p of process.argv.slice(1))console.log(p,f.statSync(p).size,'字节')" 处理后-原文.md
```
回复里给产物**路径原样** + 一段改动摘要（做了什么、原文哪几处动过）。长文档要给「摘要 + 前 10 行成品」让用户先看效果。

## 5. 替代路径（做不了的时候怎么说）
- `.pdf`：如实说这台设备上没有 PDF 解析；让用户复制正文粘贴过来，或用系统分享成文本再存进工作区。
- `.doc`（老二进制 Word）读不了：请用户用 WPS/Word 另存为 `.docx` 再放进工作区。
- 要 `.docx` 输出：**能做了**（本机 `make-docx.mjs`，见下），也可以给 `.md`，或（用户同意时）改走别的方式排版。

## 6. 文档工具（本机随包，路径 = `$DSH_ANDROID_TOOLBOX`）
- **读 `.docx`**（正文 → Markdown，可以直接接着处理、不必让用户粘贴）：
  ```sh
  node "$DSH_ANDROID_TOOLBOX/read-docx.mjs" 合同.docx --out 合同.md
  node "$DSH_ANDROID_TOOLBOX/read-docx.mjs" 合同.docx --format json   # 要结构化字段时
  ```
  它能认出标题层级、项目符号/编号、超链接、表格。**只读正文**（页眉页脚/脚注/批注不读）；
  图片默认只标注不抽取（要图给 `--extract-images 目录`）。
- **写 `.docx`**：`node "$DSH_ANDROID_TOOLBOX/make-docx.mjs" 处理后.md 成品.docx`
- **读 `.xlsx`**：`node "$DSH_ANDROID_TOOLBOX/read-xlsx.mjs" 表.xlsx --format csv`
- **写 `.xlsx`**：`node "$DSH_ANDROID_TOOLBOX/make-xlsx.mjs" 数据.csv 表.xlsx`

## 诚实约束
- 命令失败、文件读不到、编码乱码 → 把**真实报错原文**贴出来。
- 这台设备上**没有** python / pandoc / libreoffice / soffice，也不能 npm install；
  不要写「用 pandoc 转一下」这种本机做不到的命令。
- 改写要保留原意：不确定的句子标注「原句可能有歧义，我按 X 理解」，不要凭空补事实。
- 不要编造文件内容；没读到的部分不要写进产物。
