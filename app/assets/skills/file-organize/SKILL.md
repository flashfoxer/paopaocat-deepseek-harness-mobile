---
name: file-organize
description: "整理、归档、批量重命名工作区文件（先出方案再动手）"
---

# 文件整理归档

本技能负责：把工作区里乱放的文件按用户认可的规则**分类归档 / 批量重命名**。
什么时候用：用户说「文件太乱 / 帮我按类型分好 / 批量改个名字 / 归档一下」。

**最重要的规矩：动手之前先把方案列给用户确认，确认后才执行。**不要先斩后奏。

## 0. 先问清（一次问完）
- 范围：整个工作区，还是某个子目录？（子目录更安全，默认建议只整理子目录）
- 规则：按扩展名分类？按日期前缀重命名？按内容/关键词分？还是只去重？
- 命名规范：`2024-05-01_标题.ext` 这类？要保留原文件名还是完全重排？
- 要不要保留未识别类型的文件原位不动？**默认：不删任何文件，不确定的原地不动。**

## 1. 扫描现状（只读，不改任何东西）
```sh
node -e "const f=require('node:fs'),p=require('node:path');const out=[];(function walk(d){for(const e of f.readdirSync(d,{withFileTypes:true})){const q=p.join(d,e.name);if(e.isDirectory()){if(e.name!=='.git')walk(q)}else{const s=f.statSync(q);out.push([q,s.size,new Date(s.mtimeMs).toISOString().slice(0,10)])}}})('.');out.sort();for(const r of out)console.log(r.join('\t'));console.log('共',out.length,'个文件')"
```

## 2. 产出方案清单（这一步是给用户看的，别跳过）
用**写文件工具**写一份 `整理方案.md`：

| # | 原路径 | 新路径 | 理由 |
|---|---|---|---|
| 1 | `下载/IMG_2031.jpg` | `图片/2024-05-01_IMG_2031.jpg` | 按类型归档 + 日期前缀 |
| 2 | `报告 (1).md` | `文档/报告-1.md` | 去空格与括号 |

规则：同名冲突加 `-2`、`-3` 后缀；未识别的扩展名放「其他/」或原地不动。
把这份清单**完整贴在回复里**给用户看，然后明确问一句「按这个执行吗？要改哪一条？」。
用户没确认前，**不要移动、不要改名、更不要删除**。

## 3. 用户确认后：写计划文件再执行
建 `organize-plan.json`（机器可读的计划）：
```json
{ "root": ".", "moves": [ { "from": "下载/IMG_2031.jpg", "to": "图片/2024-05-01_IMG_2031.jpg" } ] }
```

执行脚本 `organize.mjs`（用**写文件工具**建，只用 node 内置模块）：
```js
import { readFileSync, writeFileSync, mkdirSync, renameSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
const plan = JSON.parse(readFileSync('organize-plan.json', 'utf8'));
const log = [];
for (const { from, to } of plan.moves) {
  if (!existsSync(from)) { log.push({ from, to, status: 'skipped-missing' }); continue; }
  if (existsSync(to)) { log.push({ from, to, status: 'skipped-conflict' }); continue; }
  mkdirSync(dirname(to), { recursive: true });
  renameSync(from, to);
  log.push({ from, to, status: 'moved' });
}
writeFileSync('organize-log.json', JSON.stringify({ at: new Date().toISOString(), log }, null, 2));
const moved = log.filter((l) => l.status === 'moved').length;
console.log(`[organize] 移动 ${moved} 个，跳过 ${log.length - moved} 个 → organize-log.json`);
```
```sh
node organize.mjs
```

## 4. 回退（必须留好这条后路）
```sh
node -e "const f=require('node:fs'),p=require('node:path');const {log}=JSON.parse(f.readFileSync('organize-log.json','utf8'));let n=0;for(const r of log){if(r.status!=='moved')continue;if(!f.existsSync(r.to)||f.existsSync(r.from))continue;f.mkdirSync(p.dirname(r.from),{recursive:true});f.renameSync(r.to,r.from);n++}console.log('[restore] 已还原',n,'个文件')"
```

## 5. 交付
回复里给：移动/重命名了多少个、跳过多少个及原因、`organize-log.json` 与方案文件的**路径原样**，
以及回退命令（上面那条）。

## 诚实约束
- **不删除任何文件**。用户明确要求删也要先列清单二次确认，并且先移进 `回收/` 目录而不是真删。
- 中途报错（权限、路径冲突、中文名）就把**真实报错**贴出来，说明哪一条失败、已成功的是哪些，
  然后让用户决定是继续还是回退。
- 这台设备上没有 python / `rsync` / `find` 的高级用法可用；一切用 node 做，别写 `find ... -exec`。
- 只整理工作区里的文件，不要碰工作区之外、也不要碰 `.git`、隐藏配置文件与 `skills`/`.dsh` 目录。
