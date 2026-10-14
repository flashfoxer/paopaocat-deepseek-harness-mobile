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

/// 判断 [sessionId] 这条会话在磁盘上有没有真实内容。
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
}) {
  if (dshHome.isEmpty || sessionId.isEmpty) return SessionContentState.unknown;

  final bytes = transcriptBytes?[sessionId];

  final cached = _readProjcacheEmpty(dshHome, sessionId);
  if (cached == true) {
    if (bytes == null) return SessionContentState.unknown;
    return bytes < kShellTranscriptMaxBytes
        ? SessionContentState.empty
        : SessionContentState.hasMessages;
  }
  // 缓存说"有内容"，但转录文件小得像空壳 —— 以文件为准，仍判有内容（不隐藏）。
  if (cached == false) return SessionContentState.hasMessages;
  return SessionContentState.unknown;
}

/// 读投影缓存：`true` = 确定 0 消息，`false` = 确定有内容，`null` = 读不出来。
bool? _readProjcacheEmpty(String dshHome, String sessionId) {
  final f = File('$dshHome/storages/session_projcache/sessions/$sessionId.json');
  try {
    if (!f.existsSync()) return null;
    final raw = jsonDecode(f.readAsStringSync());
    if (raw is! Map) return null;
    final rows = _rowsOf(raw);
    if (rows == null) return null;
    final title = _countIn(rows['titleInput']);
    final turn = _countIn(rows['turnBoundary']);
    // 两个都读到、且都是 0 → 才敢说"这句会话从没聊过"。
    if (title == 0 && turn == 0) return true;
    if (title != null || turn != null) return false;
    return null;
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
