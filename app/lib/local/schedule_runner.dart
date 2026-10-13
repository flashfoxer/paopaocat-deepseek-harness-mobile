import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/schedule_store.dart';
import 'dsh_runtime.dart';

import '../i18n/dsh_i18n.dart';

/// 定时任务的**执行器**：到点就调 `DshRuntime.headless(prompt)` 跑一次。
///
/// 复用的是已经跑通的那条通道（内部是 `dsh --profile headless --patch <overlay> <任务>`），
/// **没有**另造一条执行路径 —— 定时任务和手打消息走的是同一个模型、同一份 overlay。
///
/// ⚠️ 能力边界（写在这里省得以后误判）：
///   * 本类是 **App 进程内**的调度器。进程被系统回收后不会触发任何东西 ——
///     这是本机没有系统级闹钟（AlarmManager/WorkManager）的结果。
///   * 让进程活着的责任在原生侧：`DshSchedulerService`（前台服务 + 常驻通知），
///     由 `app_shell` 按"是否存在已启用任务"来启停。
///   * 启动时会调 `markMissedIfStale()`：把 App 没运行时错过的计划
///     **如实记成「已错过」**，而不是假装刚跑过。
class ScheduleRunner {
  ScheduleRunner({
    required this.store,
    required this.runtimeOf,
    this.tick = const Duration(seconds: 20),
  });

  final ScheduleStore store;

  /// 取当前运行时。**必须是回调而不是实例**：换模型时 `main.dart` 会重建
  /// `DshRuntime`（overlay 路径不变但对象换了），持有旧实例会用到过期的 Key。
  final DshRuntime Function() runtimeOf;

  final Duration tick;

  Timer? _timer;
  bool _busy = false;
  bool _started = false;

  /// 当前正在跑的任务名（UI 用；null = 空闲）
  final ValueNotifier<String?> runningTask = ValueNotifier<String?>(null);

  /// 最近一次执行结果（UI 用来弹提示）
  final ValueNotifier<String?> lastOutcome = ValueNotifier<String?>(null);

  bool get busy => _busy;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    // 先处理"错过的"，再排下一次
    try {
      await store.markMissedIfStale();
    } catch (e) {
      debugPrint('[dsh-schedule] markMissed 失败: $e');
    }

    _timer = Timer.periodic(tick, (_) => _check());
    // 立刻检查一次（不必等第一个 tick）
    unawaited(_check());
    debugPrint('[dsh-schedule] 调度器已启动，tick=${tick.inSeconds}s');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
    debugPrint('[dsh-schedule] 调度器已停止');
  }

  /// 每 tick 检查一次：有哪些任务到期了。同一时刻只跑一个。
  Future<void> _check() async {
    if (_busy) return;
    final now = DateTime.now();
    Schedule? due;
    for (final s in store.schedules) {
      final next = s.nextRunAt;
      if (!s.enabled || next == null) continue;
      if (!next.isAfter(now)) {
        due = s;
        break;
      }
    }
    if (due == null) return;
    await _execute(due);
  }

  /// 手动「立即运行一次」：不等计划时间。
  /// 返回一句给用户看的中文结论。
  Future<String> runNow(Schedule s) async {
    if (_busy) return tr('已有任务在执行中，请等它跑完。');
    await _execute(s);
    return lastOutcome.value ?? tr('执行结束');
  }

  Future<void> _execute(Schedule s) async {
    if (_busy) return;
    _busy = true;
    runningTask.value = s.name;
    debugPrint('[dsh-schedule] 执行任务「${s.name}」rule=${s.ruleLabel}');

    try {
      final result = await runtimeOf().headless(s.prompt);
      final ok = result.exitCode == 0;
      final summary = _summarize(result);
      await store.recordRun(
        s,
        ScheduleRun(
          at: DateTime.now(),
          ok: ok,
          summary: summary,
          taskName: s.name,
        ),
      );
      lastOutcome.value = ok
          ? tr('「{0}」执行成功：{1}', [s.name, summary])
          : tr('「{0}」执行失败：{1}', [s.name, summary]);
      debugPrint('[dsh-schedule] 完成「${s.name}」exit=${result.exitCode}');
    } catch (e) {
      await store.recordRun(
        s,
        ScheduleRun(
          at: DateTime.now(),
          ok: false,
          summary: tr('执行异常：{0}', [e]),
          taskName: s.name,
        ),
      );
      lastOutcome.value = tr('「{0}」执行异常：{1}', [s.name, e]);
      debugPrint('[dsh-schedule] 异常「${s.name}」: $e');
    } finally {
      _busy = false;
      runningTask.value = null;
    }
  }

  /// 输出摘要：优先 stdout，没有就 stderr；截断成一行，别把整个日志塞进历史。
  static String _summarize(DshRunResult r) {
    final raw = r.stdout.trim().isNotEmpty ? r.stdout : r.stderr;
    final compact = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return tr('无输出（exit={0}）', [r.exitCode]);
    return compact.length > 300 ? '${compact.substring(0, 300)}…' : compact;
  }

  void dispose() {
    stop();
    runningTask.dispose();
    lastOutcome.dispose();
  }
}
