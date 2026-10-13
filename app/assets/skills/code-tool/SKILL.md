---
name: code-tool
description: "写小脚本/小工具、批处理文件：用 node 真跑一遍并贴真实输出"
---

# 代码小工具

本技能负责：把一个小需求写成能跑的 node 脚本，并**当场跑通、贴出真实输出**。
什么时候用：用户说「帮我写个脚本处理这些文件 / 做个命令行小工具 / 批量改点东西 / 算一下」。

边界：做的是**单个自包含的 node 脚本**（`.mjs`），不是 App、不是网页前端工程、不是需要依赖的服务。

## 0. 先确认输入输出（一次问完）
- 输入是什么：哪个文件 / 哪批文件 / 命令参数 / 标准输入？
- 要输出什么：文件？打印到屏幕？改原文件（**默认不改，另存新文件**）？
- 边界情况：文件很多、很大？有不合规的行怎么处理（跳过、报错、还是照抄）？

## 1. 写脚本
用**写文件工具**建 `工具名.mjs`（ASCII 文件名，避免 shell 转义问题）。硬规矩：
- **只能用 node 内置模块**：`node:fs` / `node:path` / `node:zlib` / `node:http` / `node:https` /
  `node:child_process` / `node:url` / `node:crypto` / `node:readline` …。**不能 npm install**，不要 `import` 任何第三方包。
- 参数用 `process.argv.slice(2)` 自己解析；无参数时打印用法并 `process.exit(2)`。
- 大文件用流（`createReadStream` / `node:readline`）逐行处理，不要一次 `readFileSync` 几百 MB。
- 输出路径默认与输入同目录、加后缀，**不要默认覆盖原文件**。
- 编码固定 `utf8`。

骨架：
```js
#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';
const [, , input, output] = process.argv;
if (!input) {
  console.error('用法：node 工具名.mjs <输入文件> [输出文件]');
  process.exit(2);
}
const out = output || input.replace(/(\.[^.]*)?$/, '.out$1');
const text = readFileSync(input, 'utf8');
// …处理…
writeFileSync(out, text);
console.log('[ok] 输入', input, text.length, '字符 → 输出', out);
```

## 2. 必须真的跑一次
先用一个小的真输入跑（工作区里的文件，或先用脚本生成一个样例）：
```sh
node 工具名.mjs 输入.txt 输出.txt
node -e "console.log(require('node:fs').readFileSync('输出.txt','utf8').slice(0,800))"
```
- 把**真实 stdout / stderr 原样**贴进回复里，包括报错。
- 报错就改脚本重跑，直到跑通；**不要**只给代码说「你保存成文件运行即可」。
- 无输入文件时，生成一个最小样例（如 `样例.txt`）来验证，然后告诉用户样例在哪。

## 3. 交付
回复里包含：脚本**路径原样**、输入输出**路径原样**、一段真实运行输出、怎么改参数再用。
脚本开头写一行注释说明用法，脚本本身能 `node 工具名.mjs --help` 之外也可以只看首行注释。

## 4. 要不要做成界面
用户要界面时：可以生成一份离线自包含 HTML（内联 `<style>` 与内联 `<script>`，
**不引用任何 CDN / 外部资源**），逻辑用页面内的 JS 重写一遍。
不要为此引入框架、不要联网加载任何东西。

## 诚实约束
- 跑不通就贴**真实报错**，说清是脚本逻辑问题还是环境缺东西；不要假装修好了。
- 这台设备上没有 python / pip / npm / npx / tsc / gcc / make，也不能安装任何依赖；
  用户要 Python 脚本时如实说明，并给等价的 node 版本。
- 有网络请求需求时先确认用户是否真有网络；不能联网就把失败原文说清楚，改成本地文件方案。
- 脚本只能在工作区内读写；不要尝试访问系统目录。
