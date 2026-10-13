import 'package:flutter/material.dart';

/// 「关掉自己这一层，然后带首句开一个新会话」——**顺序只能是这样**。
///
/// ## 为什么值得单独一个函数（真机踩过）
///
/// 工作台里那几处按钮（画图表的示例、小说改游戏的「开始一个改编会话」、
/// AI 角色的「开始这一局」）都是这个形状：**用户在一张卡片/一层弹层里点一下，
/// 关掉它，然后让壳层推入会话页**。
///
/// 2026-10-12 真机反馈第 6/7/8 条的表现是「点了就跳到专家技能页、没法往下走」。
/// 根因不是导航配错，而是**两行的顺序反了**：
///
/// ```dart
/// onStart(prompt);              // 壳层在这一行里 push 会话页（push 是**同步入栈**的）
/// Navigator.of(context).pop();  // ← 于是这一行弹掉的是**刚推上去的会话页本身**
/// ```
///
/// 会话页被弹掉之后，壳层里 `await push` 立刻返回，接着执行它自己的后续动作
/// （比如「用对话生成技能」那条线会再推一次专家页）—— 用户看到的就是"闪一下跑别处"。
/// 这个 bug **不报错、日志里也看不出异常**（只有 `open chat page` 之后 2 毫秒又出现
/// 专家页加载），所以靠一条**顺序测试**把它钉住（`test/session_start_test.dart`）。
///
/// ## 用法
///
/// ```dart
/// closeThenStart(context, onStart, prompt);
/// ```
///
/// [context] 用**按钮所在那一层**的 context（弹层里就是弹层的 context）；
/// [onStart] 由壳层提供（它才知道怎么推会话页）。
void closeThenStart(
  BuildContext context,
  void Function(String prompt) onStart,
  String prompt,
) {
  // ① 先关掉自己这一层（弹层 / 详情页）。用 maybePop：万一已经没有可关的
  //    上层（比如页面被复用成首页），也只是不关，不会把整个 App 弹空。
  Navigator.of(context).maybePop();
  // ② 再让壳层开新会话 —— 此时它在栈顶，不会被误伤。
  onStart(prompt);
}
