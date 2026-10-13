/// 时间标签的测试（用户反馈：会话的历史记录显示不出时间）。
///
/// 这里最容易错、也最难在真机上发现的是**单位**：入参必须是 **epoch 毫秒**
/// （桥发的 `Date.now()`、ACP 的 `createdAt` 都是毫秒）。当成秒来用不会报错，
/// 只会把 2026 年算成 1970 年 —— 所以下面专门钉住这条。
library;

import 'package:dsh_mobile/data/relative_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 固定"现在"，避免测试在跨分钟/跨天时抖动。
  final now = DateTime(2026, 10, 10, 15, 30, 45);

  String at(DateTime t) => relativeTimeLabel(t, now: now);

  group('相对时间的档位', () {
    test('1 分钟内 → 刚刚（含"正好现在"和几十秒前）', () {
      expect(at(now), '刚刚');
      expect(at(now.subtract(const Duration(seconds: 1))), '刚刚');
      expect(at(now.subtract(const Duration(seconds: 59))), '刚刚');
    });

    test('分钟 → {0} 分钟前（60 分钟整就进位到小时）', () {
      expect(at(now.subtract(const Duration(seconds: 60))), '1 分钟前');
      expect(at(now.subtract(const Duration(minutes: 5))), '5 分钟前');
      expect(at(now.subtract(const Duration(minutes: 59))), '59 分钟前');
      expect(at(now.subtract(const Duration(minutes: 60))), '1 小时前');
    });

    test('小时 → {0} 小时前（24 小时整就进位到天）', () {
      expect(at(now.subtract(const Duration(hours: 3))), '3 小时前');
      expect(at(now.subtract(const Duration(hours: 23))), '23 小时前');
      expect(at(now.subtract(const Duration(hours: 24))), '1 天前');
    });

    test('天 → {0} 天前（7 天整就改成绝对时间）', () {
      expect(at(now.subtract(const Duration(days: 2))), '2 天前');
      expect(at(now.subtract(const Duration(days: 6))), '6 天前');
      // 7 天前 = 10-03 15:30
      expect(at(now.subtract(const Duration(days: 7))), '2026-10-03 15:30');
    });

    test('更久 → 绝对时间 yyyy-MM-dd HH:mm（补零）', () {
      expect(at(DateTime(2026, 9, 28, 14, 2)), '2026-09-28 14:02');
      expect(at(DateTime(2025, 1, 5, 9, 7)), '2025-01-05 09:07');
    });

    test('未来时间也说「刚刚」，不说「-3 分钟前」', () {
      // 设备时钟被改过 / 服务端时钟偏快时会出现
      expect(at(now.add(const Duration(minutes: 3))), '刚刚');
      expect(at(now.add(const Duration(days: 2))), '刚刚');
    });
  });

  group('单位与缺值（真机上最容易静默算错的地方）', () {
    test('入参是**毫秒**：同一个时刻按毫秒传才是对的', () {
      // 2026-10-10 15:25:45 的毫秒时间戳
      final ms = now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;
      expect(relativeTimeLabelFromMs(ms, now: now), '5 分钟前');

      // ⚠️ 反面对照：如果谁误把**秒**当毫秒传（少乘 1000），就会算成 1970 年。
      // 这里把这个错误形状钉出来 —— 它不会抛异常，只会显示一个离谱的日期。
      final wrong = ms ~/ 1000;
      expect(relativeTimeLabelFromMs(wrong, now: now), isNot('5 分钟前'));
      expect(relativeTimeLabelFromMs(wrong, now: now), startsWith('1970-'));
    });

    test('缺值：null / 0 / 负数都返回空串（界面据此不显示这一行）', () {
      expect(relativeTimeLabel(null), '');
      expect(relativeTimeLabelFromMs(0), '');
      expect(relativeTimeLabelFromMs(-1), '');
    });
  });
}
