/// 「取图回来该落哪一页」—— 用户 2026-10-12 报的第 1 条后半句。
///
/// 原话：「**开启以后，退出去选其他服务有的时候会跳转到本地会话这个页面**」
/// （指本地大模型开启后，去别的页/别的地方，有时会被弹到「本地对话」页）。
///
/// 真机日志（`dsh-report-20261012-000919.txt`）把形态钉死了 —— 同一句话在一分多钟里
/// 出现了 **6 次**，而且每次都紧跟在一句 `保活服务已停止` 后面：
/// ```
/// 00:05:51.462 恢复上次停留的 Tab：4
/// 00:05:51.462 检测到"刚才在取图" → 恢复「本地对话」页
/// 00:06:58.197 恢复上次停留的 Tab：4
/// 00:06:58.197 检测到"刚才在取图" → 恢复「本地对话」页
/// …
/// ```
///
/// 两个 bug 叠在一起：
///
/// 1. **标记只置位、从不清除**：`setPickInFlight(true)` 在影视页有 **3 处**调用，
///    而 `setPickInFlight(false)` 在整个 `media_page.dart` 里**一处都没有**
///    （只有本地对话页那处写了 `finally`）。于是"在影视页选过一张参考图"这件事
///    会在盘上留 3 分钟 —— 期间任何一次重建都会推页。
/// 2. **推哪一页是写死的**：只记了时间戳，AppShell 一律推「本地对话」——
///    所以在**影视页**选图，回来也被推去本地对话。
///
/// 第 3 个 bug（同一处代码）：恢复逻辑挂在 `_onSchedulesChanged`（调度器监听器）上，
/// 定时任务一变就响 → 同一分钟内反复推。
library;

import 'dart:io';

import 'package:dsh_mobile/state/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 找源码树里的 `lib/`（`flutter test` 的工作目录是包根）。
Directory? _libDir() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    final f = Directory('${dir.path}/lib');
    if (f.existsSync()) return f;
    dir = dir.parent;
  }
  return null;
}

void main() {
  group('取图标记的记与清（从哪来，回哪去）', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('从影视页去取图 → 记的是 media；清掉后就没有了', () async {
      final s = AppSettings();
      await s.load();
      expect(s.pickInFlightFromWithin(), '');
      await s.setPickInFlight(true, from: 'media');
      expect(s.pickInFlightFromWithin(), 'media');
      await s.setPickInFlight(false);
      expect(s.pickInFlightFromWithin(), '',
          reason: '清不干净 = 下次重建还会平白推一页（就是这个 bug）');
    });

    test('从本地对话去取图 → 记的是 localchat（这时才该推回本地对话）', () async {
      final s = AppSettings();
      await s.load();
      await s.setPickInFlight(true, from: 'localchat');
      expect(s.pickInFlightFromWithin(), 'localchat');
      await s.setPickInFlight(false);
      expect(s.pickInFlightFromWithin(), '');
    });

    test('清除时必须把"出发页"一起清掉（否则下一次会带着上一页的名字）', () async {
      final s = AppSettings();
      await s.load();
      await s.setPickInFlight(true, from: 'localchat');
      await s.setPickInFlight(false);
      // 再开一次，这次不给 from（模拟旧代码/忘记传的调用点）
      await s.setPickInFlight(true);
      expect(s.pickInFlightFromWithin(), '',
          reason: '没传 from 就该是空 —— 绝不能让上一次的 localchat 粘住');
    });

    test('超过 3 分钟就不算"刚才在取图"（标记不该无限期有效）', () {
      // 直接构造一个过期时间戳：走 load() 那条路（从盘上读）。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dsh_pick_in_flight':
            DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
        'dsh_pick_in_flight_from': 'localchat',
      });
      final s = AppSettings();
      return s.load().then((_) {
        expect(s.pickInFlightWithin(), isFalse);
        expect(s.pickInFlightFromWithin(), '');
      });
    });
  });

  group('源码纪律：每一处置位都必须有对应的清除', () {
    test('setPickInFlight(true) 与 setPickInFlight(false) 必须成对出现在同一文件', () {
      final lib = _libDir();
      if (lib == null) {
        markTestSkipped('找不到 lib/（工作目录不是包根），跳过');
        return;
      }
      final offenders = <String>[];
      for (final e in lib.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final text = e.readAsStringSync();
        final on = 'setPickInFlight(true'.allMatches(text).length;
        if (on == 0) continue;
        final off = 'setPickInFlight(false'.allMatches(text).length;
        if (off < on) {
          offenders.add('${e.path.split('/').sublist(e.path.split('/').length - 3).join('/')}'
              '：置位 $on 处，清除只有 $off 处');
        }
      }
      expect(offenders, isEmpty,
          reason: '只置位不清除 → 标记会留 3 分钟，期间 App 一重建就跳页'
              '（用户 2026-10-12 报的"跳转到本地会话"）：\n${offenders.join('\n')}');
    });

    test('恢复导航不许再挂在调度器监听器上（那是每分钟会响好几次的东西）', () {
      final lib = _libDir();
      if (lib == null) {
        markTestSkipped('找不到 lib/（工作目录不是包根），跳过');
        return;
      }
      final f = File('${lib.path}/ui/app_shell.dart');
      final text = f.readAsStringSync();
      final start = text.indexOf('void _onSchedulesChanged()');
      expect(start, greaterThan(0), reason: '找不到 _onSchedulesChanged');
      final body = text.substring(start, text.indexOf('\n  }', start));
      expect(body.contains('_openLocalChat'), isFalse,
          reason: '_onSchedulesChanged 是调度器监听器，每分钟会响多次；'
              '把推页逻辑放这里 = 反复跳页（2026-10-12 的 bug）');
      expect(body.contains('lastTabRestorable'), isFalse,
          reason: '恢复 Tab 同理：只能在进程重建时做一次');
    });
  });
}
