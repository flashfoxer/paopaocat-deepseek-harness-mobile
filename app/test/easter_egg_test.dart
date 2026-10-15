/// 彩蛋的回归测试（用户 2026-10-15 指定：**连点首页那只猫 6 下**）。
///
/// 为什么值得单独钉住：这个彩蛋的表现是"设置页里**多出一块**设置"。如果触发次数、
/// 连点窗口或落盘哪个细节坏了，界面上**不会报错**，只是"点了 6 下什么都没发生" ——
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

  test('触发次数是用户指定的 6 下（不是"大概几下"）', () {
    expect(EasterEggStore.tapsToUnlock, 6);
    // 连点窗口必须存在：没有它，"今天 3 下 + 明天 3 下"也会解锁。
    expect(EasterEggStore.tapWindow.inMilliseconds, greaterThan(0));
  });

  test('解锁会真的落盘（下次启动还在）', () async {
    await EasterEggStore.instance.unlockZen();
    expect(EasterEggStore.instance.zenUnlocked, isTrue);

    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool('dsh_easter_zen_unlocked'), isTrue,
        reason: '彩蛋状态没落盘 —— 用户下次启动会发现"设置又没了"');
  });

  testWidgets('点 5 下不解锁，第 6 下解锁', (tester) async {
    await tester.pumpWidget(_host(const MascotSpeech()));
    await tester.pump();

    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byType(MascotSpeech));
      // 间隔远小于 1.2s 的连点窗口 → 会一直累加
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(EasterEggStore.instance.zenUnlocked, isFalse,
        reason: '第 5 下就解锁了 —— 触发次数错了');

    await tester.tap(find.byType(MascotSpeech));
    await tester.pump(const Duration(milliseconds: 80));
    expect(EasterEggStore.instance.zenUnlocked, isTrue,
        reason: '连点 6 下没有解锁彩蛋');

    // 收尾：卸树让 dispose 跑完（气泡是个 5 秒的 Timer，不卸树测试会报 pending timer）。
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
