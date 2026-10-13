import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/ui/widgets/workspace_entry.dart';

/// 「工作区」入口（共用组件）的单测。
///
/// 为什么值得单独钉住：用户要求「会话页右上角那个按钮改成工作区，
/// **和首页右上角一个功能**」—— 现在两处共用同一个 [WorkspaceEntryButton]。
/// 这个测试把三件事固定下来：
///   1. 图标后面**必须有「工作区」三个字** —— 上一版首页只有个列表图标 +
///      角标数字，用户原话"不知道是干嘛的"；
///   2. 点一下**真的回调**（不是摆着看的装饰）；
///   3. 语义标签是「工作区」（读屏与自动化按名字找得到）；
///   4. 紧凑版（会话页顶栏用）**只收横向留白**，不缩字号/图标 ——
///      缩了就不像首页那一个了。
void main() {
  testWidgets('图标 + 文字「工作区」，点一下回调一次', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: WorkspaceEntryButton(onTap: () => taps++)),
        ),
      ),
    );

    expect(find.text('工作区'), findsOneWidget);
    expect(find.byIcon(Icons.folder_open), findsOneWidget);

    await tester.tap(find.byType(WorkspaceEntryButton));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('语义标签是「工作区」（读屏/自动化找得到）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WorkspaceEntryButton(onTap: () {})),
      ),
    );

    // 直接查我们自己包的那层 Semantics 的属性：语义树怎么合并、有没有开
    // semantics handle，都不该让这条断言变成看运气的测试。
    final wrapper = find
        .ancestor(of: find.byType(InkWell), matching: find.byType(Semantics))
        .first;
    final sem = tester.widget<Semantics>(wrapper);
    expect(sem.properties.label, '工作区');
    expect(sem.properties.button, true);
  });

  testWidgets('紧凑版只收留白：字号与图标尺寸和普通版一致', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              WorkspaceEntryButton(onTap: () {}),
              WorkspaceEntryButton(onTap: () {}, compact: true),
            ],
          ),
        ),
      ),
    );

    final texts = find.text('工作区');
    expect(texts, findsNWidgets(2));
    final sizes =
        texts.evaluate().map((e) => (e.widget as Text).style?.fontSize).toSet();
    expect(sizes, {12.0});

    final icons = find.byIcon(Icons.folder_open);
    final iconSizes =
        icons.evaluate().map((e) => (e.widget as Icon).size).toSet();
    expect(iconSizes, {15.0});

    // 收窄是真的：紧凑版比普通版窄（左右各少 2dp）
    final normal = tester.getSize(find.byType(WorkspaceEntryButton).at(0));
    final compact = tester.getSize(find.byType(WorkspaceEntryButton).at(1));
    expect(compact.width, lessThan(normal.width));
    expect(compact.height, normal.height);
  });
}
