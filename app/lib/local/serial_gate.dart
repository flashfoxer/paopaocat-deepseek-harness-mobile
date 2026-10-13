import 'dart:async';

/// 串行执行器：把并发调用**排成队列**，保证同一时刻只跑一个。
///
/// ## 为什么需要它
///
/// `LocalModelStore.register()` 是"读整表 → 改一条 → 写整表"。支持**同时下载**
/// 之后，几个下载可能几乎同时完成，于是三处并发调用会各自读到同一份旧表、
/// 再各自写回去 —— 后写的把先写的**覆盖掉**：用户明明下好了 3 个，
/// 登记表里只剩 1 个（另外两个"看起来没装上"）。
///
/// 这类 bug 只在"同时发生"时出现，平时测不出来，所以这里把顺序保证做成一个
/// 独立、**可测**的小东西，而不是散在界面里。
///
/// ## 用法
///
/// ```dart
/// final gate = SerialGate();
/// await gate.run(() => store.register(model));
/// ```
///
/// 上一个任务抛错不影响后面的排队（错误只抛给它的调用者）。
class SerialGate {
  Future<void> _tail = Future<void>.value();

  /// 排队执行 [task]；返回它的结果（或抛出它的异常）。
  Future<T> run<T>(Future<T> Function() task) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    try {
      // 等前面的跑完。`previous` 永远是"上一个 gate 的 future"，
      // 而它的 complete 在 finally 里必然发生 —— 所以队列不会卡死。
      await previous;
      return await task();
    } finally {
      release.complete();
    }
  }
}
