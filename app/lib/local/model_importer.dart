import 'package:flutter/foundation.dart' show debugPrint;

import '../i18n/dsh_i18n.dart' show tr;
import 'dsh_runtime.dart';
import 'model_manifest.dart';
import 'model_store.dart';

/// 单个文件的导入结果。
///
/// `matched` 与 `verified` 是**两件事**，UI 不能混着说：
///  - `matched`   = 文件名命中了随包清单里的一条（说明"这是我们要的那个模型"）；
///  - `verified`  = 真的比对过字节数/sha256（说明"文件是完整的"）。
/// 用户从网盘拖进来的自定义模型会是 `matched=false, verified=false` —— 能装、能用，
/// 但只能保证"传完了"，不能保证"是清单里那个"。
class ModelImportOutcome {
  const ModelImportOutcome({
    required this.file,
    required this.ok,
    this.path,
    this.bytes = 0,
    this.sha256,
    this.matched = false,
    this.verified = false,
    this.errorCode,
    this.errorMessage,
  });

  final String file;
  final bool ok;
  final String? path;
  final int bytes;
  final String? sha256;
  final bool matched;
  final bool verified;
  final String? errorCode;
  final String? errorMessage;

  factory ModelImportOutcome.fromNative(Map<String, dynamic> raw) =>
      ModelImportOutcome(
        file: (raw['file'] as String?) ?? '?',
        ok: raw['ok'] == true,
        path: raw['path'] as String?,
        bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
        sha256: (raw['sha256'] as String?)?.trim(),
        matched: raw['matched'] == true,
        verified: raw['verified'] == true,
        errorCode: raw['code'] as String?,
        errorMessage: raw['message'] as String?,
      );

  @override
  String toString() => ok
      ? '✅ $file (${bytes}B, matched=$matched, verified=$verified)'
      : '❌ $file: $errorMessage';
}

/// 批量导入的汇总（给 UI 直接用，不要在 UI 里再拼一遍逻辑）。
class ModelImportSummary {
  const ModelImportSummary({required this.outcomes, this.cancelled = false});

  const ModelImportSummary.cancelled()
      : outcomes = const <ModelImportOutcome>[],
        cancelled = true;

  final List<ModelImportOutcome> outcomes;

  /// 用户在系统选择器里取消了 —— 不是错误，不要说"导入失败"。
  final bool cancelled;

  List<ModelImportOutcome> get succeeded =>
      outcomes.where((o) => o.ok).toList(growable: false);

  List<ModelImportOutcome> get failed =>
      outcomes.where((o) => !o.ok).toList(growable: false);

  /// 一句人话总结（i18n 走全局 `tr`，因为这里拿不到 context）。
  String get message {
    if (cancelled) return tr('已取消，没有导入任何文件');
    if (outcomes.isEmpty) return tr('没有选中任何文件');
    final ok = succeeded.length;
    final bad = failed.length;
    if (bad == 0) return tr('导入完成：{0} 个文件', ['$ok']);
    return tr('导入完成：成功 {0} 个，失败 {1} 个', ['$ok', '$bad']);
  }
}

/// 实际去拉起「系统文件选择器」的函数 —— 做成可注入，测试里换成假的。
typedef ModelFilePicker = Future<List<Map<String, dynamic>>?> Function({
  required String targetDir,
  required List<Map<String, dynamic>> expected,
});

/// 端侧模型的**本地文件导入器**。
///
/// 与下载器的分工：下载器管「从网上取」，这里管「从本机取」（网盘 App 下好的、
/// 微信/QQ 传过来的、电脑数据线拷进去的）。两者最后走**同一条**校验+登记路径 ——
/// 这条纪律很重要：一旦导入器有自己的一套校验，以后加新校验只会改一边，
/// 另一边就会悄悄放行未经校验的文件。
class ModelImporter {
  ModelImporter(
      {required this.dir, LocalModelStore? store, ModelFilePicker? picker})
      : _store = store ?? LocalModelStore(dir: dir),
        _pick = picker ?? _pickViaHost;

  /// 目标目录（通常是 `<DSH_HOME>/models`，与下载器同一个目录）。
  final String dir;
  final LocalModelStore _store;
  final ModelFilePicker _pick;

  static Future<List<Map<String, dynamic>>?> _pickViaHost({
    required String targetDir,
    required List<Map<String, dynamic>> expected,
  }) =>
      DshHost.importModelFiles(targetDir: targetDir, expected: expected);

  /// 批量导入。
  ///
  /// [candidates] 一般是"清单里这台机器能跑、但还没装"的那些 —— 它们作为**期望值**
  /// 传给原生，用于按文件名匹配并校验大小/sha256。用户选了清单外的文件也能装进来。
  Future<ModelImportSummary> importFromDevice(
      List<OnDeviceModel> candidates) async {
    final expected = candidates
        .map((m) => <String, dynamic>{
              'fileName': m.fileName,
              'bytes': m.bytes,
              'sha256': m.sha256 ?? '',
            })
        .toList(growable: false);

    final raw = await _pick(targetDir: dir, expected: expected);
    if (raw == null) {
      debugPrint('[dsh-import] 用户取消');
      return const ModelImportSummary.cancelled();
    }

    final outcomes =
        raw.map(ModelImportOutcome.fromNative).toList(growable: false);

    // 成功 + 命中清单的，登记成"已安装"（登记表只记录清单内的模型；
    // 清单外的文件先留在磁盘上，等以后加"自定义模型"功能再说）。
    for (final o in outcomes) {
      if (!o.ok) continue;
      final entry = _findByFileName(candidates, o.file);
      if (entry == null) {
        debugPrint('[dsh-import] ${o.file} 不在清单里，仅落盘不登记');
        continue;
      }
      await _store.register(InstalledModel.fromEntry(
        entry,
        sha256: o.sha256,
        bytes: o.bytes,
        sourceLabel: '本地文件导入',
      ));
      debugPrint('[dsh-import] 已登记 ${entry.id}（${o.bytes} 字节）');
    }
    return ModelImportSummary(outcomes: outcomes);
  }

  /// 文件名匹配**不区分大小写**：SAF 给的显示名大小写可能被系统改过。
  static OnDeviceModel? _findByFileName(List<OnDeviceModel> list, String file) {
    final want = file.toLowerCase();
    for (final m in list) {
      if (m.fileName.toLowerCase() == want) return m;
    }
    return null;
  }
}
