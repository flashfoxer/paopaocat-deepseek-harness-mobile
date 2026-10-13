import 'package:dsh_mobile/data/schedule_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// `ScheduleStore.computeNextRun` 的边界验算。
///
/// 为什么值得写测试：定时任务的「下次运行时间」是整个功能的核心，
/// 算错的表现是"该跑的时候没跑"或"跑了两次"，在真机上很难复现。
///
/// ⚠️ 第一版测试自己写错了三处：用 `difference().inDays` 去断言天数，
/// 但**时间差会被时间点截断** —— 周五 09:00 → 周一 08:00 是 2 天 23 小时，
/// `inDays` 是 2 而不是 3。所以现在一律用**精确到分钟的 DateTime 全等**断言，
/// 不掺任何算术近似。
void main() {
  DateTime at(int y, int m, int d, int hh, int mm) => DateTime(y, m, d, hh, mm);

  /// 找到从 base 起的下一个指定星期几（1=周一…7=周日），避免把测试绑死在具体日期。
  DateTime nextWeekday(DateTime base, int weekday) {
    var d = DateTime(base.year, base.month, base.day);
    while (d.weekday != weekday) {
      d = d.add(const Duration(days: 1));
    }
    return d;
  }

  test('每天 08:00：今天该时刻已过 → 顺延到明天同一时刻', () {
    final from = at(2026, 10, 2, 9, 0);
    final next = ScheduleStore.computeNextRun(
      repeat: ScheduleRepeat.daily,
      hour: 8,
      minute: 0,
      weekdays: const <int>[],
      from: from,
    );
    // ignore: avoid_print
    print('[daily 已过] from=$from → next=$next');
    expect(next, DateTime(2026, 10, 3, 8, 0));
  });

  test('每天 08:00：今天该时刻还没到 → 就是今天', () {
    final from = at(2026, 10, 2, 7, 0);
    final next = ScheduleStore.computeNextRun(
      repeat: ScheduleRepeat.daily,
      hour: 8,
      minute: 0,
      weekdays: const <int>[],
      from: from,
    );
    // ignore: avoid_print
    print('[daily 未到] from=$from → next=$next');
    expect(next, DateTime(2026, 10, 2, 8, 0));
  });

  test('每天 08:00：正好等于该时刻不算"还没到" → 明天（避免重复触发）', () {
    final from = at(2026, 10, 2, 8, 0);
    final next = ScheduleStore.computeNextRun(
      repeat: ScheduleRepeat.daily,
      hour: 8,
      minute: 0,
      weekdays: const <int>[],
      from: from,
    );
    // ignore: avoid_print
    print('[daily 边界] from=$from → next=$next');
    expect(next, DateTime(2026, 10, 3, 8, 0));
  });

  test('工作日 08:00：周五晚 → 下周一（跳过周末）', () {
    final fridayDay = nextWeekday(at(2026, 1, 1, 9, 0), DateTime.friday);
    // ⚠️ 注意把时间设成 09:00：nextWeekday 返回的是当天 00:00，
    // 直接用会让"08:00 已过"这个前提不成立（第一版就是在这一步错的）。
    final from = DateTime(fridayDay.year, fridayDay.month, fridayDay.day, 9, 0);
    final next = ScheduleStore.computeNextRun(
      repeat: ScheduleRepeat.weekdays,
      hour: 8,
      minute: 0,
      weekdays: const <int>[1, 2, 3, 4, 5],
      from: from,
    );
    // ignore: avoid_print
    print('[weekdays] 周五=$from → next=$next (weekday=${next?.weekday})');
    // 周五 +3 天 = 下周一 08:00（DateTime 会自动进位跨月）
    expect(next, DateTime(from.year, from.month, from.day + 3, 8, 0));
    expect(next!.weekday, DateTime.monday);
  });

  test('工作日 08:00：周三早于 08:00 → 当天', () {
    final wednesday = nextWeekday(at(2026, 1, 1, 6, 30), DateTime.wednesday);
    final from = DateTime(
      wednesday.year,
      wednesday.month,
      wednesday.day,
      6,
      30,
    );
    final next = ScheduleStore.computeNextRun(
      repeat: ScheduleRepeat.weekdays,
      hour: 8,
      minute: 0,
      weekdays: const <int>[1, 2, 3, 4, 5],
      from: from,
    );
    // ignore: avoid_print
    print('[weekdays 当天] from=$from → next=$next');
    expect(next, DateTime(from.year, from.month, from.day, 8, 0));
  });

  test('每周一 08:00：周一已过 → 下周一', () {
    final monday = nextWeekday(at(2026, 1, 1, 9, 0), DateTime.monday);
    final from = DateTime(monday.year, monday.month, monday.day, 9, 0);
    final next = ScheduleStore.computeNextRun(
      repeat: ScheduleRepeat.weekly,
      hour: 8,
      minute: 0,
      weekdays: const <int>[1],
      from: from,
    );
    // ignore: avoid_print
    print('[weekly 周一] from=$from → next=$next');
    expect(next, DateTime(from.year, from.month, from.day + 7, 8, 0));
  });

  test('每周三、五 08:00：从周三 09:00 → 本周五（不是下周三）', () {
    final wednesday = nextWeekday(at(2026, 1, 1, 9, 0), DateTime.wednesday);
    final from = DateTime(wednesday.year, wednesday.month, wednesday.day, 9, 0);
    final next = ScheduleStore.computeNextRun(
      repeat: ScheduleRepeat.weekly,
      hour: 8,
      minute: 0,
      weekdays: const <int>[3, 5],
      from: from,
    );
    // ignore: avoid_print
    print('[weekly 三/五] from=$from → next=$next (weekday=${next?.weekday})');
    expect(next, DateTime(from.year, from.month, from.day + 2, 8, 0));
    expect(next!.weekday, DateTime.friday);
  });

  test('仅一次：已经跑过 → 不再触发（null）', () {
    final next = ScheduleStore.computeNextRun(
      repeat: ScheduleRepeat.once,
      hour: 8,
      minute: 0,
      weekdays: const <int>[],
      from: at(2026, 10, 2, 9, 0),
      onceAlreadyRan: true,
    );
    expect(next, isNull);
  });

  test('仅一次：没跑过 → 给出下一个该时刻', () {
    final next = ScheduleStore.computeNextRun(
      repeat: ScheduleRepeat.once,
      hour: 8,
      minute: 0,
      weekdays: const <int>[],
      from: at(2026, 10, 2, 9, 0),
      onceAlreadyRan: false,
    );
    // ignore: avoid_print
    print('[once] → next=$next');
    expect(next, DateTime(2026, 10, 3, 8, 0));
  });

  test('跨月/跨年：12 月 31 日 09:00 的每天任务 → 次年 1 月 1 日 08:00', () {
    final next = ScheduleStore.computeNextRun(
      repeat: ScheduleRepeat.daily,
      hour: 8,
      minute: 0,
      weekdays: const <int>[],
      from: at(2026, 12, 31, 9, 0),
    );
    expect(next, DateTime(2027, 1, 1, 8, 0));
  });

  test('humanize：优先按日历日表述', () {
    final now = at(2026, 10, 2, 9, 0);
    // ignore: avoid_print
    print(
        '[humanize] +30min = ${ScheduleStore.humanize(now.add(const Duration(minutes: 30)), now: now)}');
    // ignore: avoid_print
    print(
        '[humanize] +3h    = ${ScheduleStore.humanize(now.add(const Duration(hours: 3)), now: now)}');
    // ignore: avoid_print
    print(
        '[humanize] 明天8点 = ${ScheduleStore.humanize(at(2026, 10, 3, 8, 0), now: now)}');
    // ignore: avoid_print
    print(
        '[humanize] 后天8点 = ${ScheduleStore.humanize(at(2026, 10, 4, 8, 0), now: now)}');
    // ignore: avoid_print
    print(
        '[humanize] 过期    = ${ScheduleStore.humanize(at(2026, 10, 1, 8, 0), now: now)}');
    expect(
        ScheduleStore.humanize(now.add(const Duration(minutes: 30)), now: now),
        '30 分钟后');
    // 23 小时后也是"明天 08:00" —— 用户关心的是哪天几点
    expect(ScheduleStore.humanize(at(2026, 10, 3, 8, 0), now: now), '明天 08:00');
    expect(ScheduleStore.humanize(at(2026, 10, 4, 8, 0), now: now), '后天 08:00');
    expect(ScheduleStore.humanize(now.add(const Duration(hours: 3)), now: now),
        '12:00（3 小时后）');
    expect(ScheduleStore.humanize(at(2026, 10, 1, 8, 0), now: now), '已过期');
    expect(ScheduleStore.humanize(null, now: now), '不再触发');
  });

  test('ruleLabel：中文描述', () {
    final s = Schedule(
      id: 'x',
      name: '日报',
      prompt: '写日报',
      repeat: ScheduleRepeat.weekdays,
      hour: 8,
      minute: 5,
    );
    expect(s.ruleLabel, '每个工作日 08:05');
    final w = Schedule(
      id: 'y',
      name: '周报',
      prompt: '写周报',
      repeat: ScheduleRepeat.weekly,
      hour: 20,
      minute: 0,
      weekdays: const <int>[1, 5],
    );
    expect(w.ruleLabel, '每周一、五 20:00');
    final o = Schedule(
      id: 'z',
      name: '一次性',
      prompt: '跑一次',
      repeat: ScheduleRepeat.once,
      hour: 9,
      minute: 30,
    );
    expect(o.ruleLabel, '仅一次 · 09:30');
  });
}
