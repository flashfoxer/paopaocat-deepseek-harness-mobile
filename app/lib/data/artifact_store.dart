import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'artifacts.dart';
import 'atomic_file.dart';

/// 会话产物的**落盘索引**（用户意见⑤）。
///
/// ## 为什么需要它
///
/// 会话页的产物列表原本是**纯内存**的（`ChatPage._artifacts`）：退出会话再进来就空了，
/// 用户只能去「资料库」翻文件，而且**看不出是哪个会话产生的**。
/// 这里把核实过的产物按会话 id 存成一个小 JSON，恢复会话时读回来。
///
/// ## 三条纪律
///
/// 1. **它只是缓存，不是真相。** 真相永远是工作区里的那些真实文件 ——
///    所以读回来的条目在展示前仍要能被 `ArtifactOpener` 打开；找不到就
///    沿用既有的「如实说找不到」路径，不摆一堆点不开的卡片。
/// 2. **一个会话一个文件。** 某个文件坏了只影响那一个会话，不会连带全挂。
/// 3. **写失败不抛错。** 磁盘满 / 权限问题不该让会话本身崩掉，只打日志。
class ArtifactStore {
  ArtifactStore({required this.dir});

  /// 存放目录（调用方给，通常是 `<DSH_HOME>/artifacts`）。
  final String dir;

  String _fileFor(String sessionId) => '$dir/${_safe(sessionId)}.json';

  /// 会话 id 是 UUID，理论上安全；仍然做一次白名单清洗，避免路径穿越。
  static String _safe(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// 覆盖式保存某个会话的产物列表。
  Future<void> save(String sessionId, List<Artifact> artifacts) async {
    if (sessionId.isEmpty) return;
    try {
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      final payload = <String, dynamic>{
        'version': 1,
        'sessionId': sessionId,
        'updatedAt': DateTime.now().toIso8601String(),
        'artifacts': artifacts.map((a) => a.toJson()).toList(),
      };
      await writeStringAtomic(
        File(_fileFor(sessionId)),
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      debugPrint(
          '[dsh-artifacts] 已保存 ${artifacts.length} 个产物（${_short(sessionId)}）');
    } catch (e) {
      debugPrint('[dsh-artifacts] 保存产物索引失败（${_short(sessionId)}）：$e');
    }
  }

  /// 读回某个会话的产物列表；没有索引时返回空表（**不是错误**）。
  Future<List<Artifact>> load(String sessionId) async {
    if (sessionId.isEmpty) return const <Artifact>[];
    try {
      final f = File(_fileFor(sessionId));
      if (!f.existsSync()) return const <Artifact>[];
      return _parse(await f.readAsString()).$2;
    } catch (e) {
      debugPrint('[dsh-artifacts] 读取产物索引失败（${_short(sessionId)}）：$e');
      return const <Artifact>[];
    }
  }

  /// 全部会话的产物索引 —— 资料库的「按会话」视图用。
  ///
  /// 返回「会话 id → 产物列表」，只包含**非空**的会话。
  Future<Map<String, List<Artifact>>> loadAll() async {
    final out = <String, List<Artifact>>{};
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return out;
      for (final f in d.listSync().whereType<File>()) {
        if (!f.path.endsWith('.json')) continue;
        try {
          final parsed = _parse(f.readAsStringSync());
          if (parsed.$1.isEmpty || parsed.$2.isEmpty) continue;
          out[parsed.$1] = parsed.$2;
        } catch (_) {
          // 单个文件坏了不影响其它会话 —— 这正是"一会话一文件"的意义。
        }
      }
    } catch (e) {
      debugPrint('[dsh-artifacts] 枚举产物索引失败：$e');
    }
    return out;
  }

  /// 解析一份索引文件 → (sessionId, 产物列表)。坏数据一律降级成空。
  (String, List<Artifact>) _parse(String text) {
    final raw = jsonDecode(text);
    if (raw is! Map) return ('', const <Artifact>[]);
    final sid = raw['sessionId'];
    final list = raw['artifacts'];
    if (sid is! String || list is! List) return ('', const <Artifact>[]);
    final items = <Artifact>[];
    for (final item in list) {
      final a = Artifact.fromJson(item);
      if (a != null) items.add(a);
    }
    return (sid, items);
  }

  static String _short(String id) => id.length <= 8 ? id : id.substring(0, 8);
}
