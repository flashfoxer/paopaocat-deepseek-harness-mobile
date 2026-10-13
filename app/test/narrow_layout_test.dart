/// **窄屏不溢出**回归测试（用户 2026-10-11 实测反馈）。
///
/// ## 为什么要有它
///
/// 用户报了两条「入口被挤到屏幕外 / 界面挤出去」：
///   * 影视页「短剧」按钮被挤出屏幕（模式 chip 从 5 个变 6 个）；
///   * 底部导航项在窄屏上顶出去（2026-10-12 撤下「本地大模型」后是 5 项）。
///
/// 这两类问题的共同点是：**在开发用的宽屏视口下完全正常**，只有真机窄屏才炸。
/// Flutter 的 overflow 在测试里不会让测试失败（只打一行红字），所以这里
/// **主动 `takeException()`** —— 只要出现 RenderFlex overflow 就算失败。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/state/app_settings.dart';
import 'package:dsh_mobile/ui/pages/media_page.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';
import 'package:dsh_mobile/ui/widgets/bottom_nav.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    DshColors.applySkin(DshPalettes.dark);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('dsh-narrow-');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 设一个**窄屏**（用户报的那种手机）。
  void narrow(WidgetTester tester, double w) {
    tester.view.physicalSize = Size(w, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  // 常见窄屏宽度：320（老机/小屏）、360（主流）、392（Pixel 类）。
  for (final w in <double>[320, 360, 392]) {
    testWidgets('底部导航 5 项在 ${w.toInt()}dp 宽下不溢出（标签自动缩字）', (tester) async {
      narrow(tester, w);
      await tester.pumpWidget(MaterialApp(
        theme: buildDshTheme(),
        home: Scaffold(
          body: const SizedBox.shrink(),
          bottomNavigationBar: DshBottomNav(currentIndex: 0, onTap: (_) {}),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '${w.toInt()}dp 下导航溢出了');
      // 5 项都在，且都在屏内（等分单元格，位置断言防的是"最后一项被挤出去"）
      for (final label in <String>['首页', '工作台', '资料库', '定时任务', '设置']) {
        expect(find.text(label), findsOneWidget, reason: '缺了「$label」');
        final r = tester.getRect(find.text(label));
        expect(r.left >= -0.5 && r.right <= w + 0.5, isTrue,
            reason: '导航项「$label」跑到屏幕外了：$r（视口宽 $w）');
      }
    });

    testWidgets('影视页 6 个模式在 ${w.toInt()}dp 宽下全部可见（不再藏在屏幕外）', (tester) async {
      narrow(tester, w);
      final rt = DshRuntime(<String, dynamic>{
        'filesDir': tmp.path,
        'nodeHome': '${tmp.path}/dshhome',
        'toolboxDir': '${tmp.path}/toolbox',
      });
      await tester.pumpWidget(MaterialApp(
        theme: buildDshTheme(),
        home: MediaPage(
          runtime: rt,
          settings: AppSettings(),
          onOpenSettings: () {},
          refreshTick: 0,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull, reason: '${w.toInt()}dp 下影视页溢出了');
      // ⚠️ 关键断言：**各模式不仅要存在，还要真的落在屏幕里**。
      //
      // 只 `find.text` 是不够的 —— 横向滚动的 chip 行里，屏幕外的 chip 照样"存在"
      // （只是看不见）。用户报的就是"看不见"，所以这里断言**矩形**：
      // 每一项的 left/right 都必须在视口内。
      // 「作品」2026-10-12 起**不在工作台**（挪到「资料库」右上角），所以只剩 5 个。
      for (final m in <String>['生图', '生视频', '修图', '口播', '短剧']) {
        expect(find.text(m), findsOneWidget, reason: '${w.toInt()}dp 下没有模式「$m」');
        final r = tester.getRect(find.text(m));
        expect(r.left >= 0 && r.right <= w, isTrue,
            reason: '「$m」跑到屏幕外了：$r（视口宽 $w）');
      }
      expect(find.text('作品'), findsNothing,
          reason: '「作品」已挪到资料库，不该再出现在工作台入口屏');
    });
  }
}
