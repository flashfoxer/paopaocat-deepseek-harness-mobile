/// 会话列表**显示时间**的回归测试。
///
/// 用户反馈原话（2026-10-10）："会话的历史纪录，显示不出会话的时间"。
///
/// 根因：时间数据一直都在（`SessionInfo.updatedAt`，桥发的 `Date.now()` 毫秒），
/// 但列表项右下角画的是 `session.lastSeq` —— 一个对用户没有意义的**序号**，
/// 时间从来没被渲染出来。这个测试钉住三件事：
///   1. 相对时间**确实画出来了**；
///   2. 桥没给时间（0）时如实说「时间未知」，而不是显示 1970 年或空白；
///   3. **不再**拿序号冒充时间（否则界面看着"有东西"，其实还是没有时间）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/data/relative_time.dart';
import 'package:dsh_mobile/protocol/models.dart';
import 'package:dsh_mobile/state/bridge_state.dart';
import 'package:dsh_mobile/storage/credentials_store.dart';
import 'package:dsh_mobile/ui/sessions_page.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DshColors.applySkin(DshPalettes.dark);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  SessionInfo session({
    required String id,
    String cwd = '/data/ws',
    String? title,
    int lastSeq = 42,
    required int updatedAt,
  }) =>
      SessionInfo(
        id: id,
        cwd: cwd,
        title: title,
        status: 'idle',
        lastSeq: lastSeq,
        updatedAt: updatedAt,
      );

  Future<void> pump(WidgetTester tester, List<SessionInfo> sessions) async {
    final state = BridgeState(CredentialsStore())
      ..conn = ConnState.connected // 不连上时列表会被"正在连接…"占位挡住
      ..sessions = sessions;
    await tester.pumpWidget(ChangeNotifierProvider<BridgeState>.value(
      value: state,
      child: MaterialApp(theme: buildDshTheme(), home: const SessionsPage()),
    ));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('列表项显示相对时间（几分钟前 / 几小时前 / 几天前）', (tester) async {
    final now = DateTime.now();
    await pump(tester, <SessionInfo>[
      session(
          id: 'a1',
          title: '猫猫的项目',
          updatedAt: now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch),
      session(
          id: 'b2',
          title: '昨晚那个',
          updatedAt: now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch),
      session(
          id: 'c3',
          title: '上周的',
          updatedAt: now.subtract(const Duration(days: 2)).millisecondsSinceEpoch),
    ]);

    expect(find.text('5 分钟前'), findsOneWidget, reason: '这就是用户要的时间');
    expect(find.text('3 小时前'), findsOneWidget);
    expect(find.text('2 天前'), findsOneWidget);
  });

  testWidgets('⚠️ 不再拿序号冒充时间（列出 lastSeq=42 的会话，界面上不该出现 42）', (tester) async {
    final now = DateTime.now();
    await pump(tester, <SessionInfo>[
      session(
          id: 'a1',
          title: '有时间的会话',
          lastSeq: 42,
          updatedAt: now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch),
    ]);
    expect(find.text('42'), findsNothing,
        reason: '序号对用户没有意义，不应占着"时间"那个位置');
    expect(find.text('5 分钟前'), findsOneWidget);
  });

  testWidgets('桥没给时间（updatedAt=0）→ 如实说「时间未知」，不显示 1970 年', (tester) async {
    await pump(tester, <SessionInfo>[
      session(id: 'a1', title: '没有时间的会话', updatedAt: 0),
    ]);
    expect(find.text('时间未知'), findsOneWidget);
    expect(find.textContaining('1970'), findsNothing);
    expect(find.textContaining('刚刚'), findsNothing,
        reason: '没有时间就不该猜一个"刚刚"出来');
  });

  testWidgets('绝对时间档（超过 7 天）显示 yyyy-MM-dd HH:mm', (tester) async {
    final old = DateTime.now().subtract(const Duration(days: 20));
    await pump(tester, <SessionInfo>[
      session(
          id: 'a1',
          title: '很久以前',
          updatedAt: old.millisecondsSinceEpoch),
    ]);
    expect(find.text(relativeTimeLabel(old)), findsOneWidget);
    expect(find.textContaining('${old.year}-'), findsOneWidget);
  });
}
