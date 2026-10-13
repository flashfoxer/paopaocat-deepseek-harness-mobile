/// `closeThenStart` 的**顺序**测试。
///
/// ## 为什么专门测这个顺序
///
/// 2026-10-12 真机反馈第 6/7/8 条（画图表 / 小说改游戏 / AI 角色）表现都是
/// 「点了就跳到专家技能页、没法往下走」，而日志里**没有任何错误**：
/// 只有 `open chat page` 之后 2 毫秒又出现专家页加载。
///
/// 根因是两行的顺序 —— 壳层的 `onStart` 会**同步**把会话页推入栈，
/// 所以紧接着的 `Navigator.pop()` 弹掉的正是**刚推上去的那个会话页**，
/// 于是壳层的 `await push` 立刻返回，继续执行它后面的动作（推专家页）。
///
/// 这条测试复刻的就是那个形状：假 `onStart` 像真壳层一样**推一个假会话页**，
/// 然后断言"会话页还在最上面"。把 `closeThenStart` 里的两行**调换顺序**，
/// 这条测试就会红 —— 这是它能证明自己有用的方式。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/ui/session_start.dart';

void main() {
  testWidgets('先关自己、再开会话：推上去的会话页**不会被自己弹掉**', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    final started = <String>[];

    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (inner) => Scaffold(
                    body: Center(
                      child: ElevatedButton(
                        onPressed: () => closeThenStart(inner, (prompt) {
                          started.add(prompt);
                          // ↓ 这一段就是真壳层干的事：把「会话页」推入栈。
                          //   真实现见 `app_shell.dart` 的 `_openChat`（`Navigator.push` 同步入栈）。
                          navKey.currentState!.push(
                            MaterialPageRoute<void>(
                              builder: (_) => const Scaffold(
                                body: Center(child: Text('CHAT-PAGE')),
                              ),
                            ),
                          );
                        }, 'PROMPT-1'),
                        child: const Text('开始'),
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('打开详情页'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开详情页'));
    await tester.pumpAndSettle();
    expect(find.text('开始'), findsOneWidget, reason: '没进到详情页');

    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();

    expect(started, <String>['PROMPT-1'], reason: 'onStart 没收到首句');
    // 核心断言：会话页必须在最上面。顺序写反时它会**被弹掉**，这里就找不到了。
    expect(find.text('CHAT-PAGE'), findsOneWidget,
        reason: '会话页被自己 pop 掉了 —— 说明 closeThenStart 里"先 pop 再 onStart"的顺序被改反了');
    expect(find.text('开始'), findsNothing, reason: '自己那一层没关掉');
  });

  testWidgets('没有上层可关时也不炸（maybePop 而不是 pop）', (tester) async {
    final started = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              // 直接在最外层页面上调用：此时没有"自己那一层"可以关。
              onPressed: () => closeThenStart(context, started.add, 'P'),
              child: const Text('直接开始'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('直接开始'));
    await tester.pumpAndSettle();
    expect(started, <String>['P']);
    expect(find.text('直接开始'), findsOneWidget, reason: '不该把根页面弹掉');
  });
}
