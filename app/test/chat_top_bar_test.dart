import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/ui/pages/chat_page.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';
import 'package:dsh_mobile/ui/widgets/workspace_entry.dart';

/// 会话页顶栏（[ChatTopBar]）的单测。
///
/// 为什么值得钉住：用户要求把右上角那个（进「模型设置」的齿轮）**换成工作区入口**，
/// 而顶栏右边在"会话正在跑 + 已经有产物"时会同时挂三个东西
/// （停止 / 产物 N / 工作区）。横向一旦放不下，Flutter 会直接把
/// `RenderFlex overflowed` 画在界面上 —— 在 widget 测试里这是**抛异常**，
/// 所以"窄屏不溢出"是一条真实可跑回归网，不是靠肉眼。
void main() {
  /// 造一块手机形态的屏面。默认取 360dp 宽（比大多数真机还窄一点，
  /// 是故意的：最坏情况先过，真机上就不会溢出）。
  Future<void> setScreen(WidgetTester tester,
      {double width = 360, double height = 800}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpTopBar(
    WidgetTester tester, {
    bool running = false,
    int artifactCount = 0,
    String? workspaceLabel = '默认工作区',
    VoidCallback? onOpenWorkspaces,
    VoidCallback? onCancel,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDshTheme(),
        home: Scaffold(
          body: ChatTopBar(
            title: '画一张橘猫趴在书桌上打瞌睡，午后阳光斜射进来',
            running: running,
            onCancel: onCancel ?? () {},
            onOpenWorkspaces: onOpenWorkspaces,
            workspaceLabel: workspaceLabel,
            artifactCount: artifactCount,
            onOpenArtifacts: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('最挤的情况不溢出：会话在跑 + 有产物 + 工作区入口同时在场', (tester) async {
    await setScreen(tester);
    await pumpTopBar(tester,
        running: true, artifactCount: 7, onOpenWorkspaces: () {});

    expect(tester.takeException(), isNull);
    expect(find.text('工作区'), findsOneWidget);
    expect(find.byType(WorkspaceEntryButton), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    expect(find.text('产物 7'), findsOneWidget);
  });

  testWidgets('更窄的屏也不溢出（320dp，老机型）', (tester) async {
    await setScreen(tester, width: 320);
    await pumpTopBar(tester,
        running: true, artifactCount: 128, onOpenWorkspaces: () {});

    expect(tester.takeException(), isNull);
    expect(find.byType(WorkspaceEntryButton), findsOneWidget);
  });

  testWidgets('点工作区入口真的回调（不是摆着看的）', (tester) async {
    await setScreen(tester);
    var taps = 0;
    await pumpTopBar(tester, onOpenWorkspaces: () => taps++);

    await tester.tap(find.byType(WorkspaceEntryButton));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('没有工作区回调时：不摆一个点不动的按钮，也不影响其它东西', (tester) async {
    await setScreen(tester);
    await pumpTopBar(tester,
        running: true, artifactCount: 2, onOpenWorkspaces: null);

    expect(tester.takeException(), isNull);
    expect(find.byType(WorkspaceEntryButton), findsNothing);
    expect(find.text('停止'), findsOneWidget);
    expect(find.text('产物 2'), findsOneWidget);
  });

  testWidgets('第二行写明这条会话站在哪个工作区：本机 · <名字>', (tester) async {
    await setScreen(tester);
    await pumpTopBar(tester, workspaceLabel: 'moni-ws');
    expect(find.text('本机 · moni-ws'), findsOneWidget);
  });

  testWidgets('拿不到工作区名就退回「本机」——不编名字', (tester) async {
    await setScreen(tester);
    await pumpTopBar(tester, workspaceLabel: null);
    expect(find.text('本机'), findsOneWidget);
  });

  testWidgets('没有产物时也常驻「产物」入口（点进去是空态），没在跑就没有「停止」', (tester) async {
    await setScreen(tester);
    await pumpTopBar(tester, running: false, artifactCount: 0);
    expect(find.text('停止'), findsNothing);
    // 用户要求：产物入口常驻（每个会话产生的文件都能从这里看到）
    expect(find.text('产物'), findsOneWidget);
    expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
  });
}
