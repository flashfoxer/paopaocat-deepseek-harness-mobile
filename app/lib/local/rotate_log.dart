import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// 从轮换代理的日志里读出**这一次实际用了哪个成员**。
///
/// ## 为什么需要它
///
/// 用户口径（2026-10-07）：「轮换池的大模型用的时候，能不能在会话提醒用的轮换池那个大模型」。
///
/// 轮换池在 DSH 眼里只是**一个**模型（`rotate/<池名>`），它在内部按顺序试成员、
/// 失败就换下一个 —— 所以"这句话到底是哪个模型答的"只有代理自己知道。
/// 好在代理把这件事写进了日志（`--log <file>`），这里就是把那几行读出来。
///
/// ## 代理会写的三种行（实测自 `assets/toolbox/rotate-proxy.mjs`）
///
/// ```
/// → cat: model="..." stream=false 起始成员=claude-sonnet
/// cat: gpt-5 失败(上游 429)，改用 claude-sonnet
/// cat: claude-sonnet 成功（第 2 个成员顶上）
/// cat: claude-sonnet 成功          ← 只有 --verbose 才有这一行
/// ```
///
/// 判定规则（从后往前取最可靠的一条）：
///   1. 最后一条 `… 成功（第 N 个成员顶上）` → 那个成员就是答案；
///   2. 否则最后一条 `成功`（非"顶上"形态，verbose 模式才有）；
///   3. 再否则最后一条 `起始成员=` —— 一次都没换过时，起始成员就是答案。
///
/// 拿不到就返回 null（界面**什么都不显示**，不猜、不显示假信息）。
class RotateLog {
  const RotateLog({required this.path});

  /// 代理日志文件（代理以 `--log <这里>` 启动）。
  final String path;

  /// 日志的**唯一**默认位置：启动代理时传的就是它，读日志时也读它。
  /// （两处各写一份字面量就会像 LOCAL_MODEL_API_KEY 那次一样悄悄错开。）
  static String defaultPath(String nodeHome) => '$nodeHome/rotate.log';

  /// 解析日志文本，取"最后一次用的成员"。
  ///
  /// 抽成纯函数是为了能单测 —— 这段正则很容易写错，而错了的表现是
  /// "会话里显示一个错的模型名"，比不显示更糟。
  static ({String pool, String member})? parseLastUsed(String text) {
    if (text.trim().isEmpty) return null;
    // 只扫尾部：日志会越写越长，没必要每次读整份。
    final lines = text.split('\n');
    final tail = lines.length > 400 ? lines.sublist(lines.length - 400) : lines;

    // ⚠️ 代理每行前面都带 ISO 时间戳，而**时间戳里也有冒号** ——
    // 不先剥掉它，正则会把 `2026-10-07T00` 当成池名（第一版就栽在这）。
    final ts = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?\s+');
    // 池名里不会有冒号，所以用 `[^:]+` 卡住。
    final switched = RegExp(r'^([^:]+): (.+?) 成功（第 \d+ 个成员顶上）$');
    final plainOk = RegExp(r'^([^:]+): (.+?) 成功$');
    final start = RegExp(r'^→ ([^:]+): .*起始成员\s*=\s*(\S+)\s*$');

    ({String pool, String member})? bySwitch;
    ({String pool, String member})? byPlain;
    ({String pool, String member})? byStart;
    for (var line in tail) {
      line = line.trim().replaceFirst(ts, '');
      final m1 = switched.firstMatch(line);
      if (m1 != null) {
        bySwitch = (pool: m1.group(1)!.trim(), member: m1.group(2)!.trim());
        continue;
      }
      final m2 = plainOk.firstMatch(line);
      if (m2 != null) {
        byPlain = (pool: m2.group(1)!.trim(), member: m2.group(2)!.trim());
        continue;
      }
      final m3 = start.firstMatch(line);
      if (m3 != null) {
        byStart = (pool: m3.group(1)!.trim(), member: m3.group(2)!.trim());
      }
    }
    return bySwitch ?? byPlain ?? byStart;
  }

  /// 读文件尾部并解析。文件不存在 / 读失败 → null（不打扰用户）。
  Future<({String pool, String member})?> lastUsed() async {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final len = f.lengthSync();
      // 只读最后 64 KB：日志可能很大，但从尾部就能拿到最近一次。
      const cap = 64 * 1024;
      final start = len > cap ? len - cap : 0;
      final raf = f.openSync();
      try {
        raf.setPositionSync(start);
        final bytes = raf.readSync(len - start);
        return parseLastUsed(String.fromCharCodes(bytes));
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      debugPrint('[dsh-rotate-log] 读日志失败：$e');
      return null;
    }
  }
}
