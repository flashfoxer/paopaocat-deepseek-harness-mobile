/// 首页内置起始语（`builtin_starters.dart`）与「换一换」分组的门禁。
///
/// ## 为什么要有它
///
/// 这个文件是**纯数据 + 一点取数算术**，改起来看着"不会出错"，但它有两类**静默失效**：
///
///   ① **起始语指名了一个不存在的技能**。用户点了那张卡，模型照着技能名去找，
///      找不到就只能自由发挥（或更糟：回一句"没有这个技能"）。而技能表是会变的
///      （搬进搬出、改名），数据表不会跟着变、也**不会报任何错**。
///   ② **「换一换」的分组**。用户 2026-10-04 的原话是「点换一换也只是四个位置的不同」——
///      所以"一次换一整组、看完全部之前不重复"是**他明确要过的东西**。
///      旧实现靠 `(起点 + 4) % 12`，成立**只因为 12 正好是 4 的倍数**；
///      2026-10-12 池子加到 13 条时它就叠了（第 4 组 [12,0,1,2] 与第 1 组重 3 条）。
///      现在换成 [StarterDealer]，这条测试负责钉住"对任意条数都成立"。
library;

import 'dart:math';

import 'package:dsh_mobile/data/builtin_skills.dart';
import 'package:dsh_mobile/data/builtin_starters.dart';
import 'package:dsh_mobile/i18n/tables/en_table.dart';
import 'package:dsh_mobile/i18n/tables/ja_table.dart';
import 'package:dsh_mobile/i18n/tables/ko_table.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('起始语数据', () {
    test('每条的技能都**真的在随包技能表里**（否则用户点了那张卡，模型找不到技能）', () {
      final names = BuiltinSkills.names.toSet();
      for (final s in BuiltinStarters.all) {
        expect(names, contains(s.skill),
            reason: '起始语「${s.title}」指向技能 `${s.skill}`，'
                '而它不在 BuiltinSkills.names 里 —— 用户点了只会得到一句"没有这个技能"');
      }
    });

    test('首句必须**点名技能**（只给标题的话模型不知道该走哪条流程）', () {
      for (final s in BuiltinStarters.all) {
        expect(s.prompt, contains(s.skill),
            reason: '「${s.title}」的 prompt 里没出现技能名 `${s.skill}`');
      }
    });

    test('技能不许重复（否则首页会出现两张一样的卡）', () {
      final seen = <String>{};
      for (final s in BuiltinStarters.all) {
        expect(seen.add(s.skill), isTrue, reason: '技能 `${s.skill}` 在池子里出现了两次');
      }
    });

    test('三条文案都不许空（空标题会让卡片变成一个空框）', () {
      for (final s in BuiltinStarters.all) {
        expect(s.title.trim(), isNotEmpty);
        expect(s.subtitle.trim(), isNotEmpty);
        expect(s.prompt.trim(), isNotEmpty);
      }
    });

    test('「把小说做成游戏」这条在池子里，而且**如实说了这是多轮**', () {
      final s = BuiltinStarters.bySkill('novel-to-game');
      expect(s, isNotNull, reason: '小说改游戏的首页入口没进池子');
      // 这条流水线要走"拆原著 → 选方向 → 设计 → 构建 → 验证"，
      // 说成"一句话出游戏"就是骗人（而且会把模型带成赶工）。
      expect('${s!.prompt}${s.subtitle}', contains('多轮'),
          reason: '这条线的首句/副标题必须说明"不是一轮就能交付"');
    });

    test('标题 / 副标题 / 首句**三串都在三张表里**（否则切英日韩首页仍是中文）', () {
      // 这条是**最硬的一道**：它不看源码形状，只看"渲染时那个 key 能不能查到译文"——
      // 锚点里打错一个字、或者扫描器把整个文件跳过了（2026-10-12 就发生过，
      // 根因是 `scan.mjs` 的 SKIP_FILES 里排了 `builtin_starters.dart`），
      // 都会在这里当场露出来，而 `check-tables` 是看不出来的。
      final tables = <String, Map<String, String>>{
        '英语': kEnTable,
        '日语': kJaTable,
        '韩语': kKoTable,
      };
      for (final s in BuiltinStarters.all) {
        final fields = <String, String>{
          '标题': s.title,
          '副标题': s.subtitle,
          '首句': s.prompt,
        };
        for (final f in fields.entries) {
          for (final t in tables.entries) {
            expect(t.value.containsKey(f.value), isTrue,
                reason: '「${s.skill}」的${f.key}没进${t.key}表：'
                    '${f.value.replaceAll('\n', r'\n')}');
          }
        }
      }
    });

    test('译文不许与中文原文逐字相同（那等于没翻）', () {
      for (final s in BuiltinStarters.all) {
        for (final f in <String>[s.title, s.subtitle, s.prompt]) {
          final shown = f.replaceAll('\n', r'\n');
          expect(kEnTable[f], isNot(f), reason: '英文表里这条与中文一模一样：$shown');
          expect(kJaTable[f], isNot(f), reason: '日文表里这条与中文一模一样：$shown');
          expect(kKoTable[f], isNot(f), reason: '韩文表里这条与中文一模一样：$shown');
        }
      }
    });

    test('英/韩译文里不许再有汉字或假名（日文用汉字是正常的，不查它）', () {
      // ⚠️ 别拿"有没有汉字"去查日文：**日语本来就用汉字**（資料/生成/動画…）。
      final cjk = RegExp(r'[\u4e00-\u9fff\u3040-\u30ff]');
      final hangul = RegExp(r'[\uac00-\ud7af]');
      for (final s in BuiltinStarters.all) {
        for (final f in <String>[s.title, s.subtitle, s.prompt]) {
          final shown = f.replaceAll('\n', r'\n');
          expect(cjk.hasMatch(kEnTable[f]!), isFalse,
              reason: '英文译文里还有中日文字符：$shown → ${kEnTable[f]}');
          expect(cjk.hasMatch(kKoTable[f]!), isFalse,
              reason: '韩文译文里还有中日文字符：$shown → ${kKoTable[f]}');
          expect(hangul.hasMatch(kKoTable[f]!), isTrue,
              reason: '韩文译文里一个谚文都没有（八成是没翻）：$shown → ${kKoTable[f]}');
        }
      }
    });
  });

  group('「换一换」的发牌器（StarterDealer）', () {
    /// 池子大小 → "整批"（4 条）有几批，剩下的是零头。
    ///
    /// ⚠️ 别把期望写成"⌈n/4⌉ 批之间全不重复"——那是**不可能**的：
    ///    n 不是 4 的整数倍时，最后一批必然要用零头 + 几张老面孔凑满 4 张
    ///    （11 条时第 3 批、13 条时第 4 批）。真正该保证的是下面这三条。
    int fullBatches(int n) => n ~/ BuiltinStarters.visibleCount;

    test('真实池子（13 条）：整批之间互不重复，零头**不被吞掉**，4 批内看全 13 条', () {
      final dealer = StarterDealer(random: Random(7));
      final all = BuiltinStarters.all.map((s) => s.skill).toList();
      final full = fullBatches(all.length); // 13 → 3

      final batches = <List<String>>[];
      for (var i = 0; i <= full; i++) {
        batches.add(dealer.current.map((s) => s.skill).toList());
        dealer.next();
      }

      // ① 每批都必须是 4 条 —— 池子 13 条时最后只剩 1 条，
      //    这里要是变成"只给 1 张卡"，就说明零头把那一批缩水了。
      for (final b in batches) {
        expect(b.length, BuiltinStarters.visibleCount,
            reason: '每批都该是 4 条（不够就用新洗的一副补满）');
      }

      // ② 整批之间（前 3 批 = 12 条）互不重复。
      final head = batches.take(full).expand((b) => b).toList();
      expect(head.length, BuiltinStarters.visibleCount * full);
      expect(head.toSet().length, head.length,
          reason: '整批之间出现了重复 —— 用户会看到"点一下还是那几条"');

      // ③ 那第 13 条必须**出现在下一批的第一张**。
      //    队列是"没看过的牌"，零头留在队首、由新洗的一副补到 4 张 —— 所以
      //    "最后一条被吞掉"或"最后一条单独凑成 1 张卡"这两种坏情况都会在这里露出来。
      expect(batches[full].first, all[12],
          reason: '最后剩下的那条没出现在下一批开头（被吞了，或者只在末尾凑数）');

      // ④ 覆盖：这几批加起来能看全池子。
      expect(batches.expand((b) => b).toSet().length, all.length);
    });

    test('池子不是 4 的整数倍（11 条）：整批不重叠，零头那 3 条各占一张卡', () {
      final pool = BuiltinStarters.all.take(11).toList();
      final dealer = StarterDealer(pool: pool, random: Random(3));

      final b1 = dealer.current.map((s) => s.skill).toList();
      dealer.next();
      final b2 = dealer.current.map((s) => s.skill).toList();
      dealer.next();
      final b3 = dealer.current.map((s) => s.skill).toList();

      expect(b1.toSet().length, 4);
      expect(b2.toSet().length, 4);
      expect(b1.toSet().intersection(b2.toSet()), isEmpty,
          reason: '两个整批之间不该重叠');
      // 11 = 4 + 4 + 3：零头 3 条刚好占满第 3 批的前三张
      expect(b3.take(3).toSet().length, 3, reason: '零头没各占一张卡');
      expect({...b1, ...b2, ...b3}.length, 11, reason: '3 批没覆盖全部 11 条');
    });

    test('池子比一批还小（3 条）：不会死循环，一次给全部，也不重复', () {
      final pool = BuiltinStarters.all.take(3).toList();
      final dealer = StarterDealer(pool: pool, random: Random(1));
      final batch = dealer.current;
      expect(batch.length, 3, reason: '池子只有 3 条时，一批就是 3 条（不能补出重复的）');
      expect(batch.map((s) => s.skill).toSet().length, 3);
      dealer.next();
      expect(dealer.current.length, 3);
      expect(dealer.current.map((s) => s.skill).toSet().length, 3,
          reason: '下一批内部也不能有重复（发牌器只在新一轮里才会重复）');
    });

    test('首屏保持**声明顺序**（改动前用户一进来看到的就是这 4 条）', () {
      // 这条是**刻意的**：换一换才洗牌，第一屏不变 —— 免得"顺手改成随机"
      // 让用户以为首页被换了一套。
      final dealer = StarterDealer(random: Random(99));
      expect(dealer.current.map((s) => s.skill).toList(),
          BuiltinStarters.all.take(4).map((s) => s.skill).toList());
    });

    test('空池子不炸（不下标越界、不无限循环）', () {
      final dealer = StarterDealer(pool: const <BuiltinStarter>[], random: Random(1));
      expect(dealer.current, isEmpty);
      dealer.next();
      expect(dealer.current, isEmpty);
    });
  });
}
