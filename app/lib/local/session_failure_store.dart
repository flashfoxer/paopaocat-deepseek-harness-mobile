import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'dsh_runtime.dart';

/// 一条"这次提问没有回上来"的记录（缺陷 C）。
///
/// ## 为什么 App 要自己存一份
///
/// 会话转录（`session.v4.jsonl.zstd`）是**运行时（node DSH）写的**，它只在
/// 失败时落 `assistant/attempt` + `llm/retry*`，**不落任何错误事件** ——
/// 于是重新打开会话回放，只看到"我发了话、没有回答"，看着就像对话被吞了。
///
/// App 侧改不了运行时的落盘逻辑（那是另一个包），但**能让失败可见**：
/// 失败时把"人话原因 + 技术细节"记在本文件里，回放时由
/// `session_transcript.dart` 合并成一条 `notice`。
///
/// 如实说明边界：这**不是**写进 DSH 转录的事件 —— 换台设备/重装 App 就没了，
/// 命令行直接 `read-transcript.mjs` 也看不到。要做到"转录里就有"，得改
/// dsh-acp 的落盘（上游）。
class SessionFailureRecord {
  const SessionFailureRecord({
    required this.at,
    required this.friendly,
    this.detail,
  });

  /// 失败发生的时刻（epoch 毫秒）
  final int at;

  /// 给用户看的人话（界面主文案）
  final String friendly;

  /// 技术细节（原始报错；界面上折起来，默认不展开）
  final String? detail;

  Map<String, Object?> toJson() => {
        'at': at,
        'friendly': friendly,
        if (detail != null && detail!.trim().isNotEmpty) 'detail': detail,
      };

  static SessionFailureRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = raw['at'];
    final friendly = raw['friendly'];
    if (at is! num || friendly is! String || friendly.trim().isEmpty) {
      return null;
    }
    final detail = raw['detail'];
    return SessionFailureRecord(
      at: at.toInt(),
      friendly: friendly,
      detail: detail is String && detail.trim().isNotEmpty ? detail : null,
    );
  }
}

/// 最多留多少条会话的失败记录（超出丢最旧的）。
///
/// 为什么要有上限：这是个只增不减的小账本，不封顶的话用得越久文件越大。
/// 50 条足够覆盖"最近翻历史时可能看到的那些会话"。
const int kMaxFailureRecords = 50;

String _filePathOf(DshRuntime runtime) =>
    '${runtime.filesDir}/session_failures.json';

Map<String, SessionFailureRecord> _readAll(DshRuntime runtime) {
  final out = <String, SessionFailureRecord>{};
  try {
    final f = File(_filePathOf(runtime));
    if (!f.existsSync()) return out;
    final raw = jsonDecode(f.readAsStringSync());
    if (raw is! Map) return out;
    final items = raw['items'];
    if (items is! Map) return out;
    for (final e in items.entries) {
      final rec = SessionFailureRecord.fromJson(e.value);
      if (rec != null) out['${e.key}'] = rec;
    }
  } catch (e) {
    debugPrint('[dsh-session-failure] 读账本失败（当成空的）：$e');
  }
  return out;
}

void _writeAll(DshRuntime runtime, Map<String, SessionFailureRecord> all) {
  try {
    // 超上限就按时间丢最旧的 —— 保证文件有上界。
    if (all.length > kMaxFailureRecords) {
      final sorted = all.entries.toList()
        ..sort((a, b) => b.value.at.compareTo(a.value.at));
      all = <String, SessionFailureRecord>{
        for (final e in sorted.take(kMaxFailureRecords)) e.key: e.value,
      };
    }
    final f = File(_filePathOf(runtime));
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(jsonEncode({
      'v': 1,
      'items': {for (final e in all.entries) e.key: e.value.toJson()},
    }));
    // 先写临时文件再改名：中途被杀不会留下半截 JSON（账本坏了就全读不出来了）。
    tmp.renameSync(f.path);
  } catch (e) {
    debugPrint('[dsh-session-failure] 写账本失败（不影响主流程）：$e');
  }
}

/// 记下"这次提问失败"。**覆盖**同一会话的上一条（只留最近的）。
Future<void> recordSessionFailure({
  required DshRuntime runtime,
  required String sessionId,
  required String friendly,
  String? detail,
}) async {
  if (sessionId.trim().isEmpty) return;
  final all = _readAll(runtime);
  all[sessionId] = SessionFailureRecord(
    at: DateTime.now().millisecondsSinceEpoch,
    friendly: friendly,
    detail: detail,
  );
  _writeAll(runtime, all);
}

/// 读某条会话的失败记录（没有就返回 null）。
SessionFailureRecord? readSessionFailure({
  required DshRuntime runtime,
  required String sessionId,
}) {
  if (sessionId.trim().isEmpty) return null;
  return _readAll(runtime)[sessionId];
}

/// 这条会话已经成功回上来一次了 → 把旧记录擦掉（免得回放里挂个过期的"没回答"）。
Future<void> clearSessionFailure({
  required DshRuntime runtime,
  required String sessionId,
}) async {
  if (sessionId.trim().isEmpty) return;
  final all = _readAll(runtime);
  if (all.remove(sessionId) != null) _writeAll(runtime, all);
}
