---
name: make-slides
description: "做 PPT / 幻灯片 / 演示文稿"
---

# 做一份幻灯片（生成真正的 .pptx）

本技能负责：把主题或材料变成可交付的 `.pptx`（16:9，封面 + 每页标题/要点，可选演讲者备注）。
什么时候用：用户说「做 PPT / 幻灯片 / 演示文稿 / 把这份材料讲一讲」。

不要用 HTML 幻灯片顶替 PPT，除非用户明确说要 HTML。

## 0. 先问清关键缺口（一次问完）
- 主题是什么？讲给谁听（工作汇报 / 教学 / 路演）？大概几页？
- 有没有现成材料（工作区里的文件名，或直接把正文贴过来）？
- 要不要演讲者备注？

主题明确、其余缺口无关紧要时，按合理默认先做，做完明确写出你的假设。

## 1. 收集材料
工作区里的材料用 node 读，不要用 `cat` 猜编码：

```sh
node -e "const t=require('node:fs').readFileSync('材料.md','utf8');console.log('字符数',t.length);console.log(t.slice(0,2000))"
```

## 2. 写大纲文件 outline.json
用**写文件工具**直接落盘，**不要用 heredoc / echo**（中文和引号会被 shell 吃掉）。

JSON 形状（各字段都能省略，但 `slides` 必须有内容）：

```json
{
  "title": "封面标题",
  "subtitle": "可选副标题",
  "author": "可选作者",
  "slides": [
    { "title": "为什么现在做这件事", "bullets": ["要点一", "要点二", "要点三"], "notes": "讲这页时要说的话（可选）" },
    { "title": "数据表现", "bullets": [{ "text": "主结论", "level": 0 }, { "text": "支撑细节", "level": 1 }] }
  ]
}
```

写作要求：
- 一页一个观点；每页 `bullets` 3–5 条，单条不超过 40 字。
- 封面由 `title` + `subtitle` 自动生成，**不要**自己再写一页「封面」。
- `notes` 只给需要口述的页写，不用每页都写。
- 用半角双引号、不要尾随逗号。

## 3. 生成 .pptx

```sh
node "$DSH_ANDROID_TOOLBOX/make-pptx.mjs" outline.json "输出.pptx"
```

成功时最后一行形如：
`[make-pptx] ok slides=7 notes=3 parts=38 bytes=24512 out=/.../输出.pptx`

## 4. 自检（别跳过）

```sh
node -e "const f=require('node:fs');const b=f.readFileSync('输出.pptx');console.log('字节',b.length,'头两字节',b.subarray(0,2).toString())"
```

- 大小应达到几十 KB；头两字节必须是 `PK`（pptx 就是 ZIP 包）。
- 不对就回第 2 步改大纲重跑，**不要**在对话里贴一个没生成的假路径。

## 5. 交付
最终回复里给到：产物**路径原样**、页数、一句话大纲摘要。提示用户可在「资料库」里预览和分享。

## 诚实约束
- 命令失败就把**真实报错原文**贴出来并解释原因（最常见是 `大纲文件不是合法 JSON` 与路径找不到）。
- 这台设备上**没有** python / pandoc / libreoffice，也不能 npm install；不要调 `python-pptx`、不要试 `soffice`。
- 用户要 .docx 时**能做了**（`make-docx.mjs`，见 AGENTS.md 的本机环境说明）；要 .pdf 等本机做不出的格式时如实说做不到，替代路径是给 .pptx 或 Markdown。
- 不编造路径，不假装已生成。

## 常见错误
- 大纲里混进中文引号或尾逗号 → 脚本报 `不是合法 JSON`，改回半角并删尾逗号。
- 路径没加引号且含空格/中文 → 用双引号把整个路径包住。
- 同一页改两轮仍不满意 → 把大纲贴给用户确认，别自己猜。
