/// 彩蛋的回归测试（用户 2026-10-15 指定：**连点首页那只猫 7 下**）。
///
/// 为什么值得单独钉住：这个彩蛋的表现是"设置页里**多出一块**设置"。如果触发次数、
/// 连点窗口或落盘哪个细节坏了，界面上**不会报错**，只是"点了 7 下什么都没发生" ——
/// 那正是最难查的一类问题。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/data/easter_egg.dart';
import 'package:dsh_mobile/i18n/app_language.dart';
import 'package:dsh_mobile/i18n/dsh_i18n.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';
import 'package:dsh_mobile/ui/widgets/mascot_speech.dart';

Widget _host(Widget child) => DshI18n(
      language: AppLanguage.zh,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildDshTheme(),
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    DshColors.applySkin(DshPalettes.dark);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await EasterEggStore.instance.resetForTest();
  });

  test('触发次数是用户指定的 7 下（不是"大概几下"）', () {
    expect(EasterEggStore.tapsToUnlock, 7,
        reason: '用户 2026-10-15 晚明确：第 7 下长震 + 左/上/右三个泡泡「有彩蛋，在设置里」');
    // 连点窗口必须存在：没有它，"今天 3 下 + 明天 4 下"也会解锁。
    expect(EasterEggStore.tapWindow.inMilliseconds, greaterThan(0));
  });

  test('解锁会真的落盘（下次启动还在）', () async {
    await EasterEggStore.instance.unlockZen();
    expect(EasterEggStore.instance.zenUnlocked, isTrue);

    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool('dsh_easter_zen_unlocked'), isTrue,
        reason: '彩蛋状态没落盘 —— 用户下次启动会发现"设置又没了"');
  });

  testWidgets('前 6 下不解锁，第 7 下解锁（数字从常量取，别在测试里写死）', (tester) async {
    await tester.pumpWidget(_host(const MascotSpeech()));
    await tester.pump();

    const need = EasterEggStore.tapsToUnlock; // = 7
    for (var i = 0; i < need - 1; i++) {
      await tester.tap(find.byType(MascotSpeech));
      // 间隔远小于 1.2s 的连点窗口 → 会一直累加
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(EasterEggStore.instance.zenUnlocked, isFalse,
        reason: '第 ${need - 1} 下就解锁了 —— 触发次数错了');

    await tester.tap(find.byType(MascotSpeech));
    await tester.pump(const Duration(milliseconds: 80));
    expect(EasterEggStore.instance.zenUnlocked, isTrue,
        reason: '连点 $need 下没有解锁彩蛋');

    // 收尾：卸树让 dispose 跑完（气泡是个 5 秒的 Timer，不卸树测试会报 pending timer）。
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('第 7 下：左/上/右三个泡泡同时弹，文字都是「有彩蛋，在设置里」', (tester) async {
    await tester.pumpWidget(_host(const MascotSpeech()));
    await tester.pump();

    for (var i = 0; i < EasterEggStore.tapsToUnlock; i++) {
      await tester.tap(find.byType(MascotSpeech));
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(find.text('有彩蛋，在设置里'), findsNWidgets(3),
        reason: '用户要的是"猫咪的左上右都会弹出泡泡" —— 必须是 3 个，不是 1 个');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('普通点击只弹一个泡泡（别一上来就三个）', (tester) async {
    await tester.pumpWidget(_host(const MascotSpeech()));
    await tester.pump();

    await tester.tap(find.byType(MascotSpeech));
    await tester.pump(const Duration(milliseconds: 80));
    // 第 1 下说的是台词表里的第 1 句
    expect(find.text('喵～今天想聊点什么？'), findsOneWidget);
    expect(find.text('有彩蛋，在设置里'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('慢慢点（超过连点窗口）不会解锁', (tester) async {
    // ⚠️ 必须注入时钟：`tester.pump(Duration)` 只推进测试时钟，`DateTime.now()`
    //    在测试里根本不动 —— 不注入的话"每次间隔都超过窗口"这件事是**装出来的**，
    //    测试会误判成"解锁了"（我第一版就是这么写的，跑出来才发现的）。
    var now = DateTime(2026, 10, 15, 12);
    await tester.pumpWidget(_host(MascotSpeech(clock: () => now)));
    await tester.pump();

    // 每次间隔都超过窗口 → 计数每次都被重置成 1，永远到不了 6。
    for (var i = 0; i < 8; i++) {
      await tester.tap(find.byType(MascotSpeech));
      await tester.pump(const Duration(milliseconds: 80));
      now = now.add(EasterEggStore.tapWindow + const Duration(milliseconds: 50));
    }
    expect(EasterEggStore.instance.zenUnlocked, isFalse,
        reason: '间隔超过窗口的点按也被算进连点了 —— 那就不是彩蛋了');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
