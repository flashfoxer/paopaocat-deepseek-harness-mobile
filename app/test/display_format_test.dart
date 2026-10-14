// 会话列表里的「时间 + 用了多少 token」（用户 2026-10-15 第 2 条：
// 「我记得以前提过要求会话都是可以显示时间和用了多少tok」）与点猫咪说话（第 4 条）。
//
// 两个小组件级的纯逻辑，一起钉住：
//   * `formatTokens` —— 用量怎么显示（数字口径必须全 App 一致）；
//   * `mascotLineAt` —— 点猫咪轮换句子（越界要回环，不能崩）。

import 'package:dsh_mobile/data/display_format.dart';
import 'package:dsh_mobile/data/mascot_lines.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('token 用量显示', () {
    test('一千以内直接显示，取整不加单位', () {
      expect(formatTokens(0), '0');
      expect(formatTokens(7), '7');
      expect(formatTokens(999), '999');
    });

    test('1024 进制（与「应用信息」里的体积口径一致）', () {
      expect(formatTokens(1024), '1.0k');
      expect(formatTokens(1536), '1.5k');
      expect(formatTokens(12345), '12k');
      expect(formatTokens(1024 * 1024), '1.0M');
      expect(formatTokens(3 * 1024 * 1024 + 500000), '3.5M');
    });

    test('负数不显示成负的（脏数据不许画到界面上）', () {
      expect(formatTokens(-5), '0');
    });
  });

  group('点猫咪说话', () {
    test('一共 6 句，界面/测试都从这里取数', () {
      expect(mascotLineCount, 6);
    });

    test('越界自动回环，不会崩', () {
      final first = mascotLineAt(0);
      expect(first, isNotEmpty);
      expect(mascotLineAt(mascotLineCount), first);
      expect(mascotLineAt(-1), mascotLineAt(mascotLineCount - 1));
      expect(mascotLineAt(-100), mascotLineAt((-100 % mascotLineCount + mascotLineCount) % mascotLineCount));
    });

    test('连着点会换句子（不是每次同一句）', () {
      final seen = <String>{};
      for (var i = 0; i < mascotLineCount; i++) {
        seen.add(mascotLineAt(i));
      }
      expect(seen.length, mascotLineCount);
    });
  });
}
