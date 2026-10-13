/// 「思考过程」显示方式的测试（用户 2026-10-12：「思考过程都是英文的，怎么回避」）。
///
/// ## 为什么这件事值得钉住
///
/// 思考用哪种语言**是模型训练出来的倾向** —— 我们只能"请求它用中文"
/// （写进 AGENTS.md 受管区块），**不能保证**。所以真正能"彻底不看到英文思考"
/// 的只有一条路：**不渲染它**。这个开关如果悄悄失效（比如取值写成别的、
/// 或者界面读的是另一个字段），用户就会以为"设了不显示怎么还全是英文"。
///
/// 这条测试同时钉住三件容易走样的事：
///   ① 三档取值的字面量（它们是**落盘**的值，改名 = 老用户的选择静默失效）；
///   ② `hidden` 必须**真的一个节点都不渲染**（不是"透明"、不是"高度 0"）；
///   ③ `collapsed` 要给得出「展开」，`expanded` 不该有折叠按钮。
library;

import 'package:dsh_mobile/data/artifacts.dart';
import 'package:dsh_mobile/state/app_settings.dart';
import 'package:dsh_mobile/ui/widgets/message_stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一段**足够长**的英文思考（超过折叠阈值，这样"折叠/展开"才有区别）。
const String _longThought =
    'Let me think about this carefully. The user is asking whether the app can '
    'avoid showing English reasoning. First I should check what the runtime '
    'actually exposes, then look at how the message stream renders thought '
    'blocks, and finally decide whether hiding is needed at all.';

ChatMsg _thought(String text) =>
    ChatMsg(text: text, role: ChatRole.thought);

Future<void> _pump(WidgetTester tester, List<ChatMsg> msgs, String mode) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MessageStream(
        messages: msgs,
        artifacts: const <Artifact>[],
        running: false,
        controller: ScrollController(),
        onOpenArtifacts: () {},
        thinkingMode: mode,
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('思考块：三档显示方式', () {
    testWidgets('hidden —— 一个节点都不渲染（这才是"彻底看不到英文"的硬保证）',
        (tester) async {
      await _pump(tester, <ChatMsg>[_thought(_longThought)], 'hidden');
      expect(find.textContaining('Let me think'), findsNothing,
          reason: 'hidden 时**不能**还留在树里（透明或零高度都算漏）');
      expect(find.text('展开思考'), findsNothing);
      expect(find.text('展开'), findsNothing);
    });

    testWidgets('collapsed —— 显示开头 + 给「展开」；点开后能看到全文', (tester) async {
      await _pump(tester, <ChatMsg>[_thought(_longThought)], 'collapsed');
      // 折叠时 Text 仍在（显示前几行），所以用"展开按钮在不在"判断模式
      expect(find.text('展开'), findsOneWidget);
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget,
          reason: '点开之后应该变成「收起」');
    });

    testWidgets('expanded —— 直接铺开，不给折叠按钮', (tester) async {
      await _pump(tester, <ChatMsg>[_thought(_longThought)], 'expanded');
      expect(find.text('展开'), findsNothing);
      expect(find.text('收起'), findsNothing);
      expect(find.textContaining('Let me think'), findsOneWidget);
    });

    testWidgets('很短的思考不摆一个点了没反应的「展开」', (tester) async {
      await _pump(tester, <ChatMsg>[_thought('嗯。')], 'collapsed');
      expect(find.textContaining('嗯。'), findsOneWidget);
      expect(find.text('展开'), findsNothing);
    });
  });

  group('设置层：取值是落盘字面量，白名单必须兜住坏值', () {
    test('三档的 id 就是这三个（改名 = 老用户的选择静默失效）', () {
      expect(AppSettings.kThinkingModeIds,
          <String>{'collapsed', 'expanded', 'hidden'});
      expect(AppSettings.kThinkingModes.map((m) => m.id).toSet(),
          AppSettings.kThinkingModeIds,
          reason: '文案表与白名单必须一一对应（少一个 = 那一档永远选不上）');
      for (final m in AppSettings.kThinkingModes) {
        expect(m.label.trim(), isNotEmpty);
        expect(m.note.trim(), isNotEmpty, reason: '${m.id} 没有说明文案');
      }
    });

    test('默认是「折叠」（不是展开、更不是不显示）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final s = AppSettings();
      await s.load();
      expect(s.thinkingModeId, 'collapsed');
    });

    test('磁盘上是脏值 → 退回默认，不把界面留在一个不认识的状态', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{'dsh_thinking_mode': 'nonsense'});
      final s = AppSettings();
      await s.load();
      expect(s.thinkingModeId, 'collapsed');
    });

    test('落盘 + 读回（重启后还记得）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final s = AppSettings();
      await s.load();
      await s.setThinkingMode('hidden');
      expect(s.thinkingModeId, 'hidden');
      // 重新 load 一次模拟重启
      final s2 = AppSettings();
      await s2.load();
      expect(s2.thinkingModeId, 'hidden');
    });

    test('不认识的取值一律忽略（不写坏数据）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final s = AppSettings();
      await s.load();
      await s.setThinkingMode('展开吧');
      expect(s.thinkingModeId, 'collapsed');
    });
  });
}
