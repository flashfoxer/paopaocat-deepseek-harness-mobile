import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// 一条会话「到底聊没聊过」的三态判断。
///
/// 为什么是三态而不是布尔：判据说到底来自 DSH 的缓存文件，**读不到就不能当空** ——
/// 把一条真聊过的会话藏起来，比多显示一条空壳严重得多。
enum SessionContentState {
  /// 确定有真实内容（缓存说有，或缓存说空但转录文件明显不止一个头部）
  hasMessages,

  /// 确定是 0 消息空壳（缓存说空 + 转录文件只有头部那么大）
  empty,

  /// 判不出来（缓存缺失 / 字段缺失 / 解析失败 / 转录文件找不到）
  unknown,
}

/// 空壳转录的大小上限（字节）。
///
/// 依据（设备实测 v0.74，见 `docs/CHANGES-2026-10-14.md` 附录 8.A）：
/// 17 个 0 消息空壳的 `session.v4.jsonl.zstd` 在 **175 B ～ 410 B**；
/// 而真正聊过的会话是 KB 级起步。这里取 4 KB —— 比空壳宽松一个数量级，
/// 又远小于任何一次真实对话，两头都不容易误判。
const int kShellTranscriptMaxBytes = 4096;

/// 扫描 `<dshHome>/sessions/*/<sessionId>/session.v4.jsonl.zstd`，返回 `id → 字节数`。
///
/// 只做 `readdir` + `stat`，不解码（转录是多帧 zstd，Dart 解不了）。
/// 扫不到就返回空表 —— 调用方据此给 [SessionContentState.unknown]。
///
/// `sessions/` 下面第一层是 cwd 的转义目录（数量很少），第二层才是会话目录。
Map<String, int> scanTranscriptSizes(String dshHome) {
  final out = <String, int>{};
  if (dshHome.isEmpty) return out;
  final root = Directory('$dshHome/sessions');
  List<FileSystemEntity> cwds;
  try {
    if (!root.existsSync()) return out;
    cwds = root.listSync(followLinks: false);
  } catch (e) {
    debugPrint('[dsh-session-content] 列 sessions/ 失败：$e');
    return out;
  }
  for (final c in cwds) {
    if (c is! Directory) continue;
    List<FileSystemEntity> subs;
    try {
      subs = c.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final s in subs) {
      if (s is! Directory) continue;
      final f = File('${s.path}/session.v4.jsonl.zstd');
      try {
        if (!f.existsSync()) continue;
        out[s.uri.pathSegments.where((p) => p.isNotEmpty).last] =
            f.lengthSync();
      } catch (_) {
        // 单个会话读不到就跳过，不影响别的
      }
    }
  }
  return out;
}

/// 一条会话在磁盘上的两件事：**是不是空壳** + **用了多少 token**（意见 2 要显示用量）。
///
/// 两者同源（都在那份投影缓存里），所以一次读出来，不要为同一份文件读两遍。
({SessionContentState state, int? totalTokens}) readSessionFacts({
  required String dshHome,
  required String sessionId,
  Map<String, int>? transcriptBytes,
}) {
  if (dshHome.isEmpty || sessionId.isEmpty) {
    return (state: SessionContentState.unknown, totalTokens: null);
  }
  final rows = _readProjcacheRows(dshHome, sessionId);
  final bytes = transcriptBytes?[sessionId];

  final tokens = rows == null ? null : _totalsIn(_valOf(rows['tokenUsage']));

  SessionContentState state;
  if (rows == null) {
    state = SessionContentState.unknown;
  } else {
    final title = _countIn(rows['titleInput']);
    final turn = _countIn(rows['turnBoundary']);
    if (title == 0 && turn == 0) {
      if (bytes == null) {
        state = SessionContentState.unknown;
      } else {
        state = bytes < kShellTranscriptMaxBytes
            ? SessionContentState.empty
            : SessionContentState.hasMessages;
      }
    } else if (title != null || turn != null) {
      state = SessionContentState.hasMessages;
    } else {
      state = SessionContentState.unknown;
    }
  }
  return (state: state, totalTokens: tokens);
}

/// 判断 [sessionId] 这条会话在磁盘上有没有真实内容（[readSessionFacts] 的薄封装）。
///
/// 两个数据源，缺一不可地**互相佐证**：
///
///   1. **投影缓存** `<dshHome>/storages/session_projcache/sessions/<id>.json`
///      —— 明文 JSON，Dart 能直接读（转录是多帧 zstd，Dart 读不了）。
///      实测字段：`record.rows.titleInput.val.count`（0 = 还没取过标题）、
///      `record.rows.turnBoundary.val.lastTurn`（0 = 一个轮次都没跑过）。
///   2. **转录文件大小**（可选，由 [scanTranscriptSizes] 预先扫好）。
///      缓存可能滞后（App 被杀等），所以"缓存说空"时再看一眼文件大小：
///      文件明显不小 → 说明有内容，**判有**，不隐藏。
///
/// [transcriptBytes] 为 null 时缺这一路佐证：此时"缓存说空"给 [SessionContentState.unknown]
/// （保守，不隐藏）。
SessionContentState sessionContentState({
  required String dshHome,
  required String sessionId,
  Map<String, int>? transcriptBytes,
}) =>
    readSessionFacts(
      dshHome: dshHome,
      sessionId: sessionId,
      transcriptBytes: transcriptBytes,
    ).state;

/// 读投影缓存的 `rows` 那一层；文件缺失 / 坏 JSON / 没有 rows 都返回 null。
Map? _readProjcacheRows(String dshHome, String sessionId) {
  final f = File('$dshHome/storages/session_projcache/sessions/$sessionId.json');
  try {
    if (!f.existsSync()) return null;
    final raw = jsonDecode(f.readAsStringSync());
    if (raw is! Map) return null;
    return _rowsOf(raw);
  } catch (e) {
    debugPrint('[dsh-session-content] 读投影缓存失败 $sessionId：$e');
    return null;
  }
}

Map? _rowsOf(Map raw) {
  final record = raw['record'] ?? raw['rows']; // 两种层级都认，格式变了也不至于全瞎
  if (record is! Map) return null;
  final rows = record['rows'] ?? record;
  return rows is Map ? rows : null;
}

/// 取某一行里的 `val` 那一层（`{val: X}` → X，没有 val 就返回整行）。
Object? _valOf(Object? row) => row is Map ? (row['val'] ?? row) : row;

/// 从 `{val: {count: 0}}` / `{val: 0}` 这类形状里取一个整数。
int? _countIn(Object? row) {
  if (row is! Map) return null;
  return _firstInt(row['val']) ?? _firstInt(row);
}

int? _firstInt(Object? v) {
  if (v is num) return v.toInt();
  if (v is Map) {
    for (final k in const ['count', 'lastTurn', 'turn', 'total', 'value']) {
      final x = v[k];
      if (x is num) return x.toInt();
    }
  }
  return null;
}

/// 从 `tokenUsage.val.totals` 里取总用量。
///
/// 形状按**宽容**处理（不同 DSH 版本不一样，猜窄了就等于永远读不到）：
/// `totals` 是数字就用它；是对象就优先认 `total` / `totalTokens`，认不到就把里面
/// 所有数字**加起来**（input+output+…）。都没有 → null（界面**不显示**，不编 0）。
int? _totalsIn(Object? totals) {
  if (totals is num) return totals.toInt();
  if (totals is! Map) return null;
  for (final k in const ['total', 'totalTokens', 'overall', 'sum']) {
    final v = totals[k];
    if (v is num) return v.toInt();
  }
  var sum = 0;
  var saw = false;
  for (final v in totals.values) {
    if (v is num) {
      sum += v.toInt();
      saw = true;
    }
  }
  return saw ? sum : null;
}
