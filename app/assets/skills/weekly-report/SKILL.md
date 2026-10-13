---
name: weekly-report
description: "把这段时间做的事汇总成周报"
---

# 汇总一份周报

本技能负责：扫工作区里这段时间真的变过/新增的文件，读它们的内容，汇总成一份周报。
什么时候用：用户说「写个周报 / 这周做了啥 / 汇总一下最近的工作 / 给领导交个总结」。

产物：`周报-YYYY-MM-DD.md`（日期用报告当天），需要时再给一份自包含 `周报.html`。

## 0. 先确定时间范围（不清楚就问，别默认）
- 时间范围是哪段（本周一至今 / 上周 / 指定 5 月 1–7 日）？
- 工作区就是全部来源吗？有没有工作区之外的事要写进去（这部分只能靠用户口述）？
- 汇报对象与颗粒度（给自己 / 给领导 / 给客户）；要不要写「下一步计划」。

范围不明时**必须问一句**再动手；用户说「就这周」时按「本周一 00:00 到今天」算，并把这个口径写进报告头部。

## 1. 扫描工作区（先只读，不改任何东西）
```sh
node -e "const f=require('node:fs'),p=require('node:path');const start=new Date(process.argv[1]).getTime();const out=[];(function w(d){for(const e of f.readdirSync(d,{withFileTypes:true})){const q=p.join(d,e.name);if(e.isDirectory()){if(!/^\.|^node_modules$/.test(e.name))w(q)}else{const s=f.statSync(q);if(s.mtimeMs>=start)out.push([new Date(s.mtimeMs).toISOString().slice(0,16),s.size,q])}}})('.');out.sort();for(const r of out)console.log(r.join('\t'));console.log('共',out.length,'个文件在范围内')" "2024-05-01T00:00:00"
```
（把最后那个日期换成第 0 步确定的起点。）

## 2. 在第 3 步的产物里，先写明「本次读了哪些文件」（这是硬要求）
报告开头必须有这一节：

```markdown
## 本次汇总读取的文件
| 文件 | 修改时间 | 大小 | 读了什么 |
|---|---|---|---|
| 报告/方案.md | 2024-05-03 14:20 | 12 KB | 方案正文与结论 |
| 数据/销售.csv | 2024-05-04 09:10 | 3 KB | 行数与合计 |
```
- **只列你真读过的文件**；扫描到但没读的（例如二进制、图片）单独列一行说明「未读，非文本」。
- 没读到内容就不要在正文里替它编一句功绩。

## 3. 读文件并抽事实
```sh
node -e "const t=require('node:fs').readFileSync('报告/方案.md','utf8');console.log(t.slice(0,1500))"
```
对每个文本文件抽取：做了什么、结论是什么、有哪些数字、有没有未完成项。
CSV 类的算一下行数/合计（用真算，别估）：
```sh
node -e "const t=require('node:fs').readFileSync('数据/销售.csv','utf8').split(/\r?\n/).filter(Boolean);console.log('行数',t.length-1);console.log(t.slice(0,3).join('\n'))"
```

## 4. 写周报
结构（没有内容的小节就删掉，不要留空标题）：
1. **本周概览**：一句话 + 3–5 条要点。
2. **本次汇总读取的文件**（第 2 步那张表）。
3. **已完成**：每条写「做了什么 + 产出文件路径 + 结果/数字」。
4. **进行中**：进度百分比或「差 X 没做」，以及卡在哪。
5. **问题与风险**：需要别人配合的事、需要拍板的事。
6. **下一步计划**：3 条以内，写清验收标准。
7. **口径说明**：时间范围、哪些内容来自用户口述（标注「（用户口述）」）、哪些没核实。

要求：所有事实都能追溯到工作区里的文件或用户原话；**不要凑字数、不要写「持续跟进中」这类空话**。

## 5. 自检与交付
```sh
node -e "const f=require('node:fs');const p=process.argv[1];const t=f.readFileSync(p,'utf8');console.log(p,f.statSync(p).size,'字节','小节数',(t.match(/^## /gm)||[]).length,'路径引用',(t.match(/[^\s|（）()]+\.(md|csv|html|pptx|png|mp4|mjs)/g)||[]).length)" "周报-2024-05-10.md"
```
- 检查：每个「已完成」条目是否都带文件路径或可验证的数字；有没有把未读文件写成成绩。
- 回复里给「本周概览」正文 + 产物**路径原样** + 读取文件数。

## 诚实约束
- 时间范围、口径不确定就问；**不要默认「本周 = 最近 7 天」**。
- 工作区里读不出的事，宁可写「（用户口述，未核实）」也不编。
- 扫描/读取失败就把**真实报错**贴出来，说明少统计了哪些文件。
- 这台设备上没有 python / jq / git 的可靠历史（如果工作区不是 git 仓库就别假设有 git log）；
  需要更长的历史记录时如实说做不到，只能按文件修改时间推。
