/// 「记忆」页的**冒烟测试**：真的把它点一遍，确认不会炸。
///
/// ## 为什么单独要这一条（它不是重复测试）
///
/// 0.75 把记忆做成了完整功能：分类 / 重要度 / 作用范围 / 搜索 / 置顶 /
/// 导入导出 / **从最近会话自动提炼候选**。其中「提炼」这条路要**起一次 headless
/// DSH 进程**去问模型 —— 在那条链路里最容易出的是"环境不对就整个页面炸掉"，
/// 而那恰恰是真机（没配 Key / 没装运行时 / 网络不通）最常见的状态。
///
/// 所以这条测试故意把运行时指向一个**不存在的** `bin.js`：
/// 提炼必然起不来，页面**必须如实显示错误、而不是抛异常**。
/// 断言用的是 `tester.takeException() == null`（真异常会被抓住），
/// 而不是"打印一行看看" —— 只打印的检查在 CI 里等于没有。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/ui/pages/memory_page.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('记忆页：加一条 → 打开提炼入口 → 起不来也要如实显示、不抛异常', (tester) async {
    // ⚠️ 默认的测试窗口是 800×600，而这页是有分类/重要度/范围之后**变长**了的
    //    —— 不设视口的话「添加」按钮会落在屏幕外，`tap` 会打空
    //    （报 "derived an Offset ... outside the bounds of the root of the render tree"）。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    DshColors.applySkin(DshPalettes.dark);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final tmp = Directory.systemTemp.createTempSync('dsh-mem-smoke-');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    // 运行时**故意指向不存在的文件**：提炼那条链路必然起不来。
    final runtime = DshRuntime(<String, dynamic>{
      'nativeLibDir': tmp.path,
      'filesDir': tmp.path,
      'dshBin': '${tmp.path}/nope/bin.js',
      'nodeHome': '${tmp.path}/dshhome',
      'fsShim': '${tmp.path}/nope-fs.cjs',
      'nodeBinary': '${tmp.path}/libnode.so',
    });

    await tester.pumpWidget(MaterialApp(
      theme: buildDshTheme(),
      home: MemoryPage(
        dshHome: '${tmp.path}/dshhome',
        workspacePath: tmp.path,
        runtime: runtime,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    // 1) 先加一条（让条目卡也渲染出来）
    await tester.enterText(find.byType(TextField).first, '我是中文用户');
    await tester.pump();
    final addBtn = find.widgetWithText(FilledButton, '添加');
    await tester.ensureVisible(addBtn);
    await tester.pump();
    await tester.tap(addBtn);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('我是中文用户'), findsWidgets,
        reason: '写进去的那一条没有出现在列表里');
    expect(tester.takeException(), isNull, reason: '加一条就把页面搞炸了');

    // 2) 打开提炼入口：运行时不在了，必须**如实报错**而不是崩。
    final extractBtn = find.widgetWithText(OutlinedButton, '选择一条会话');
    await tester.ensureVisible(extractBtn);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(extractBtn);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull,
        reason: '提炼入口起不来时抛异常了 —— 真机上"没配 Key / 没装运行时"就是这个状态');

    // 3) 页面必须还活着（没有整页塌成空白）
    expect(find.text('记忆'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
