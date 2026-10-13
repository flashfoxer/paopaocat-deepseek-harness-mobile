/// 「剪辑」页的界面测试（`ui/pages/clip_page.dart`）。
///
/// ## 这里测什么、不测什么
///
/// **不测**真实的 ffmpeg 剪辑 —— 那一层由 `test/clip_video_test.dart` 用真 node
/// + 真 ffmpeg 端到端验过了。这里只管**界面行为**，以及三条最容易静默坏掉的东西：
///
/// * **五个操作与参数区要一一对上**：选「抽音频」却还显示「精确剪」的勾选框，
///   或者选了「压小」却看不到 CRF 输入框 —— 用户会以为功能没做；
/// * **「开始」在没选够文件时必须是禁用的**：拼接至少要两段，一段就点开始
///   只会白等一次报错；
/// * **i18n 锚点与数据表逐字同步**：五个操作的名字和说明写在 `const` 表里，
///   扫描器看不见，靠 `clipI18nAnchors()` 复写一遍才收得到 ——
///   改了表忘了改锚点，切语言会**静默露中文**，而 `check-tables.mjs` 仍报 0 漂移。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/ui/pages/clip_page.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    DshColors.applySkin(DshPalettes.dark);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('dsh-clip-page-');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    // 长表单：视口给足，否则下半部分的参数区根本没被构建（同 media_page_test 的踩坑）。
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
      home: ClipPage(runtime: rt),
    ));
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 点某个操作 chip（点整个 chip，不是里面的文字 —— 文字可能落在内边距上）。
  Future<void> tapOp(WidgetTester tester, String label) async {
    final chip = find.ancestor(of: find.text(label), matching: find.byType(ChoiceChip));
    expect(chip, findsWidgets, reason: '找不到操作「$label」');
    await tester.tap(chip.first);
    await tester.pumpAndSettle();
  }

  group('五个操作', () {
    testWidgets('都在，且默认选中「剪一段」并显示它的说明', (tester) async {
      await pump(tester);
      for (final o in ClipPage.ops) {
        expect(find.text(o.label), findsOneWidget, reason: '缺了操作「${o.label}」');
      }
      expect(ClipPage.ops.length, 5);
      // 默认是 trim：它的说明要在
      expect(find.text(ClipPage.ops.first.hint), findsOneWidget,
          reason: '默认选中的那个操作，说明也要跟着显示');
    });

    testWidgets('选「抽音频」→ 显示"原样搬"的说明，且不再显示精确剪勾选框', (tester) async {
      await pump(tester);
      expect(find.text('精确剪（重新编码，慢）'), findsOneWidget);

      await tapOp(tester, '抽音频');
      expect(find.textContaining('原样搬过去'), findsOneWidget);
      expect(find.text('精确剪（重新编码，慢）'), findsNothing,
          reason: '切到抽音频后还留着"精确剪"，会让人以为这一刀也能精确剪');
      expect(find.text('参数不一致时重新编码（慢）'), findsNothing);
    });

    testWidgets('选「拼接」→ 显示重编码勾选框，且标题变成"选要拼的视频（按顺序）"', (tester) async {
      await pump(tester);
      await tapOp(tester, '拼接');
      expect(find.text('参数不一致时重新编码（慢）'), findsOneWidget);
      expect(find.text('选要拼的视频（按顺序）'), findsOneWidget);
      // 拼接至少两段，一个都没选时必须点不动
      final start = find.widgetWithText(FilledButton, '开始（本机执行，不联网）');
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
    });

    testWidgets('选「压小」→ 有最大宽度与 CRF 两个输入框', (tester) async {
      await pump(tester);
      await tapOp(tester, '压小');
      expect(find.text('最大宽度（像素）'), findsOneWidget);
      expect(find.text('清晰度 CRF（越大越糊越小）'), findsOneWidget);
    });

    testWidgets('选「抽一帧」→ 有"截第几秒"，且没有重编码勾选框', (tester) async {
      await pump(tester);
      await tapOp(tester, '抽一帧');
      expect(find.text('截第几秒（如 0:03，留空=开头）'), findsOneWidget);
      expect(find.text('精确剪（重新编码，慢）'), findsNothing);
      expect(find.text('参数不一致时重新编码（慢）'), findsNothing);
    });
  });

  group('没选够文件就不许开始', () {
    testWidgets('剪一段：一个文件都没选 → 开始按钮禁用，并说明去哪儿选', (tester) async {
      await pump(tester);
      final start = find.widgetWithText(FilledButton, '开始（本机执行，不联网）');
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
      expect(find.textContaining('还没选文件'), findsOneWidget);
      expect(find.text('从资料库选'), findsOneWidget);
    });
  });

  group('如实说明', () {
    testWidgets('页面里写清了关键帧、拼接格式、压小慢这三件事', (tester) async {
      await pump(tester);
      expect(find.text('边界（如实说）'), findsOneWidget);
      // 这三条是"用户最容易误解成功能没做好"的地方，必须在页面上说清
      expect(find.textContaining('对齐到最近的关键帧'), findsOneWidget);
      expect(find.textContaining('要求几段的画面/声音格式一致'), findsOneWidget);
      expect(find.textContaining('压小要重新编码'), findsOneWidget);
      // 也要写明不会动原素材（用户最怕这个）
      expect(find.textContaining('原始素材'), findsOneWidget);
    });
  });

  group('i18n 锚点与数据表同步', () {
    test('五个操作的名字与说明都在锚点里逐字出现', () {
      final src = File('lib/ui/pages/clip_page.dart').readAsStringSync();
      final at = src.indexOf('void clipI18nAnchors()');
      expect(at, greaterThan(0), reason: '找不到 clipI18nAnchors()：锚点被改名或删掉了？');
      final open = src.indexOf('{', at);
      final anchors = src.substring(open, src.indexOf('\n}', open));
      for (final o in ClipPage.ops) {
        expect(anchors.contains(o.label), isTrue,
            reason: '「${o.label}」不在锚点里：切到英文会露出中文，'
                '而 check-tables 仍然报 0 漂移');
        expect(anchors.contains(o.hint), isTrue, reason: '「${o.hint}」不在锚点里');
      }
    });
  });
}
