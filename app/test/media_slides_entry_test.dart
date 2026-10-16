/// 「做 PPT / 幻灯片」入口的测试（2026-10-16 补）。
///
/// ## 为什么会有这一条
///
/// 用户问「ppt 这个功能放哪了」，然后说「放到创作台吧」——
/// 在那之前，这条路**只有一个入口**：首页内置会话第一条「做一份幻灯片」。
/// 创作台里找不到，所以用户找不到。
///
/// 这个文件钉住三件事，缺一件这个入口就会"看着在、点不动"：
///   1. **创作台「工具」组里真有这个入口**，而且点得开（不是死按钮）；
///   2. 点开后的弹层里**有可点的例子**，点一个就**真的开会话**（`onStartPrompt` 被调用），
///      而且起始指令里**点名了 `make-slides` 技能**（不点名模型不一定走那条技能）；
///   3. 源码纪律：那几句要进翻译表的文案必须写成 `context.tr('…')` 字面量、
///      前缀必须先取出来再用（扫描器只看 `tr(` 同一行的字面量，写成
///      `'${context.tr('…')}$e'` 会**静默漏翻**）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/state/app_settings.dart';
import 'package:dsh_mobile/ui/pages/media_page.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';

Future<void> expandAllGroups(WidgetTester tester) async {
  for (final g in <String>['生成图像与视频', '口播与短剧', '工具', '创作']) {
    final t = find.text(g);
    if (t.evaluate().isEmpty) continue;
    await tester.tap(t);
    await tester.pumpAndSettle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    DshColors.applySkin(DshPalettes.dark);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('dsh-slides-entry-');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<List<String>> pumpEntries(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final started = <String>[];
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
        // 停在「创作台」入口屏（`initialSeg: null`），并且带上开会话的回调 ——
        // 没有它的话 `onStartPrompt == null`，例子按钮是**禁用**的（那也是一条要钉的性质）。
        initialSeg: null,
        onStartPrompt: (text) => started.add(text),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    return started;
  }

  testWidgets('创作台「工具」组里有「做 PPT / 幻灯片」，点得开', (tester) async {
    await pumpEntries(tester);
    await expandAllGroups(tester);
    expect(find.text('做 PPT / 幻灯片'), findsWidgets,
        reason: '创作台里找不到这个入口 —— 用户就是因为找不到才问的');
    await tester.tap(find.text('做 PPT / 幻灯片').first);
    await tester.pumpAndSettle();
    // 弹层出现：说明文字 + 至少一个可点的例子
    expect(find.textContaining('排版不用你操心'), findsOneWidget,
        reason: '弹层说明没出来（点了没反应？）');
    expect(find.textContaining('工作汇报'), findsOneWidget, reason: '例子没出来');
  });

  testWidgets('点例子 → 真的开会话，而且起始指令点名叫 make-slides 技能', (tester) async {
    final started = await pumpEntries(tester);
    await expandAllGroups(tester);
    await tester.tap(find.text('做 PPT / 幻灯片').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('工作汇报').first);
    await tester.pumpAndSettle();
    expect(started, hasLength(1), reason: '点了例子却没开会话');
    expect(started.single, contains('make-slides'),
        reason: '起始指令必须点名技能，否则模型不一定走 make-slides');
  });

  test('源码纪律：文案都走 tr( 字面量、前缀先取出来（否则切外语会静默露中文）', () {
    final src = File('lib/ui/pages/media_page.dart').readAsStringSync();
    final sheet = src.substring(
        src.indexOf('Future<void> _showSlidesSheet()'),
        src.indexOf('/// 打开某个功能（入口 → 详情）。'));
    // 前缀必须是"先取出来"的那种写法 —— 与画图表那处同一个坑
    expect(sheet.contains("final prefix = context.tr("), isTrue,
        reason: r"前缀没先取出来：写成 '${context.tr('…')}\$e' 的话 i18n 扫描器看不见那个字面量");
    expect(sheet.contains(r"'$prefix$e'"), isTrue,
        reason: r"例子与前缀的拼接要用 '$prefix$e'（先取前缀再拼）");
    // 例子与说明都要包 tr(（扫描器只认同一行的字面量）
    expect(sheet.contains('context.tr('), isTrue);
    expect(RegExp(r"context\.tr\('[^']*'\)").allMatches(sheet).length, greaterThanOrEqualTo(6),
        reason: '弹层里的文案应当逐条 context.tr(\'…\')');
    // 开会话必须走 closeThenStart（先关自己再开 —— 写反了会把会话页弹掉）
    expect(sheet.contains('closeThenStart('), isTrue);
    // 入口的 hint 也要进翻译表
    expect(src.contains("hint: context.tr('生成真正的 .pptx："), isTrue);
  });

  testWidgets('没有开会话的能力时，例子是禁用的（不做假按钮）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
        initialSeg: null,
        // 故意不给 onStartPrompt（例如壳层没提供这条能力）
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await expandAllGroups(tester);
    await tester.tap(find.text('做 PPT / 幻灯片').first);
    await tester.pumpAndSettle();
    final tile = tester.widget<ListTile>(find.ancestor(
      of: find.textContaining('工作汇报'),
      matching: find.byType(ListTile),
    ).first);
    expect(tile.onTap, isNull, reason: '开不了会话就该禁用，而不是点了没反应');
  });
}
