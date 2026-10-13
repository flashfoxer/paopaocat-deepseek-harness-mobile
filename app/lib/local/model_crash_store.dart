import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import '../data/atomic_file.dart';

/// 本地引擎的**崩溃记录**（`<dir>/crashes.json`）。
///
/// ## 为什么必须落盘（不能只记在内存里）
///
/// 崩溃发生在**用户发第一条真话**的时候 —— 那一刻用户早就离开了设置页。
/// 如果只在内存里记，App 一重启就忘了，于是下次点「启动」还会用同一个后端
/// 再崩一遍，用户永远爬不出来。所以这条记忆必须持久化。
///
/// ## 依据（真机日志，2026-10-07）
///
/// 用户发「你好」→ 12 秒后 `进程退出 code=-11`（SIGSEGV 段错误）→
/// 之后每次请求都是 `Connection error`（因为服务已经死了，而 overlay 还指着它）。
/// 同一份日志里还有：`error while handling argument "--flash-attn": unknown value
/// for --flash-attn: '--cache-type-k'` —— 性能开关因为参数写法错误**全部没生效**，
/// 于是 GPU 上跑的是**未量化的 16k KV cache**，显存压力大。
class ModelCrashStore {
  ModelCrashStore({required this.dir});

  /// 模型目录（通常与 `LocalModelStore` 同一个 `<DSH_HOME>/models`）。
  final String dir;

  String get path => '$dir/crashes.json';

  Map<String, int>? _cache;

  /// 一条记录的键：模型 + 后端。**后端必须参与**：同一个模型换后端可能就好了。
  static String key(String modelId, String backend) => '$modelId|$backend';

  Future<Map<String, int>> load({bool refresh = false}) async {
    if (!refresh && _cache != null) return _cache!;
    final out = <String, int>{};
    try {
      final f = File(path);
      if (f.existsSync()) {
        final raw = jsonDecode(await f.readAsString());
        if (raw is Map) {
          for (final e in raw.entries) {
            final v = e.value;
            if (v is num) out['${e.key}'] = v.toInt();
          }
        }
      }
    } catch (e) {
      debugPrint('[dsh-crash] 读崩溃记录失败（当作空）：$e');
    }
    _cache = out;
    return out;
  }

  /// 这个模型在这个后端上崩过几次。
  Future<int> countFor(String modelId, String backend) async {
    final m = await load();
    return m[key(modelId, backend)] ?? 0;
  }

  /// 记一次崩溃。`code` 是进程退出码（负值 = 被信号终止）。
  Future<void> record(String modelId, String backend, int code) async {
    final m = await load(refresh: true);
    final k = key(modelId, backend);
    m[k] = (m[k] ?? 0) + 1;
    _cache = m;
    try {
      Directory(dir).createSync(recursive: true);
      await writeStringAtomic(File(path), jsonEncode(m));
    } catch (e) {
      debugPrint('[dsh-crash] 写崩溃记录失败：$e');
    }
  }

  /// 清掉某个模型的全部崩溃记录（用户手动"再信它一次"时用）。
  Future<void> clearFor(String modelId) async {
    final m = await load(refresh: true);
    m.removeWhere((k, _) => k.startsWith('$modelId|'));
    _cache = m;
    try {
      await writeStringAtomic(File(path), jsonEncode(m));
    } catch (e) {
      debugPrint('[dsh-crash] 清崩溃记录失败：$e');
    }
  }
}

/// 退出码 → 人话。
///
/// 为什么要翻译：日志里只有 `code=-11`，用户看不懂；而 `code=-11` 恰好是
/// **段错误**（GPU/驱动问题的典型信号），把它写清楚能让下一次排查少绕一圈。
String exitCodeReason(int code) {
  if (code == -11 || code == 139) {
    return '段错误（SIGSEGV）—— 常见于图形后端驱动或显存不足';
  }
  if (code == -6 || code == 134) return '异常中止（SIGABRT）';
  if (code == -9 || code == 137) {
    return '被系统强杀（SIGKILL）—— 常见于内存不足';
  }
  if (code == -4 || code == 132) return '非法指令（SIGILL）';
  if (code < 0) return '被信号终止（code=$code）';
  return '非正常退出（code=$code）';
}
