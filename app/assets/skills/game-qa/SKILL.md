---
name: game-qa
description: "在真实运行环境里验证游戏并留下证据"
---

> **来源与许可**：本技能来自 **NovelToGame v0.4.0**（zenstory.ai 的「有原著依据的小说改编游戏工作流」），
> 以 **MIT** 许可随 App 一起分发（许可全文见同目录下的 `LICENSE.txt`，或
> `assets/skills/novel-to-game/LICENSE.txt`）。
> **本 App 只改了两处**：① 技能**简介**改写成一行中文（这个 App 每轮都要把技能名 + 简介递给模型，
> 长简介是每轮的固定开销）；② 加了这个署名区块。**技能正文与 `references/` 一字未改。**
> 上游仓库里的 `examples/`（13MB 示例游戏，含成人向题材）**没有随包**。
# 游戏质量验证

验证当前候选能否完成最小可玩闭环，不把自动化结果包装成趣味、平衡、权利或发布质量结论。

读取 [qa-contract.md](references/qa-contract.md) 定判据，按
[test-design-method.md](references/test-design-method.md) 设计最少但有区分力的检查。

产物语言由 `PRODUCT_BRIEF.md` 锁定；未锁定时跟随对话语言，不默认产出中文。

## 唯一必需合同

每个候选都必须用真实运行证据覆盖：`launch`、`render`、`input`、`coreLoop`、`outcome`、`restart`。
`targetFinish` 描述成色，不改变这组六项，也不得生成第七道门。

## 执行

1. 读取 `targetRuntime`、`testedRuntime` 和权威 verify；与 PRODUCT_BRIEF/BUILD_BRIEF 冲突时先报错，
   不由 QA 猜值。
2. 运行权威 verify：它在 testedRuntime 从 clean start → 核心动作 → 设计结果 → restart
   完成整条路径，并记录 command、exit code、环境、六项结果、最小证据和实际失败。
3. 对照 GAME_DESIGN 中会改变结果的不变量和结束标记；只验证批准的设计承诺，不遍历所有
   代码路径。
4. 若候选有可执行模型、事件日志、patch 或 `signature_command`，按 test-design-method 的对应合同把
   项目回归嵌入权威 verify；允许定向诊断、修复和复跑，最终六项证据必须来自同一次完整运行。
   失败映射到已有 checks 或 limitation，不新增通用门禁。
5. 记录 limitation 和问题的 product/design/art/build 归属。

优先使用已有可观察状态；只有无法判断结果时才增加最小测试钩子。不要为了 QA 重构游戏或强制某种
框架、测试库或调试接口。

## 输出

- `qa/verification.json`：唯一 QA 事实源；字段与证据要求见 qa-contract.md。

缺口写结构化 limitation，不发明 `PASS_WITH_GAPS`；未运行或失败的必需项不能满足整体 PASS。
