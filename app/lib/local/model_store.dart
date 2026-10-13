import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'model_manifest.dart';
import '../data/atomic_file.dart';

/// 一个**已经装在手机上**的模型。
///
/// 它记录"当初是从清单哪一条、哪个哈希装进来的" —— 因为清单会更新，
/// 而磁盘上的文件不会自己变；两者不一致时要能说清楚。
/// 已安装模型的**伴生文件**记录（mmproj 等）：名字 + 期望字节数。
///
/// 为什么要记进登记表：多模态模型少了下半截（编码器）就"看得见模型、看不了图"，
/// 必须在"已安装"这一层就能验出来，而不是等用户去发一张图才发现。
class InstalledCompanion {
  const InstalledCompanion({required this.fileName, required this.bytes});

  final String fileName;
  final int bytes;

  factory InstalledCompanion.fromJson(Map<String, dynamic> j) =>
      InstalledCompanion(
        fileName: (j['fileName'] as String?) ?? '',
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'fileName': fileName, 'bytes': bytes};
}

class InstalledModel {
  const InstalledModel({
    required this.id,
    required this.family,
    required this.name,
    required this.fileName,
    required this.bytes,
    required this.installedAt,
    this.kind = 'text',
    this.engine = 'llama.cpp',
    this.format = 'gguf',
    this.quant = '',
    this.license = 'unknown',
    this.sha256,
    this.sourceLabel = '',
    this.companions = const <InstalledCompanion>[],
  });

  final String id;
  final String family;
  final String name;
  final String fileName;
  final int bytes;
  final DateTime installedAt;
  final String kind;
  final String engine;
  final String format;
  final String quant;
  final String license;
  final String? sha256;

  /// 实际是从哪个源下下来的（排查"某个源给出坏文件"时唯一有用的线索）。
  final String sourceLabel;

  /// 伴生文件（多模态的视觉编码器）。空 = 这个模型不需要。
  final List<InstalledCompanion> companions;

  factory InstalledModel.fromJson(Map<String, dynamic> json) => InstalledModel(
        id: json['id'] as String,
        family: (json['family'] as String?) ?? json['id'] as String,
        // ⚠️ **空字符串也要兜底**：`''` 不是 null，`??` 不会触发 —— 老版本写进去
        // 的空名字会让界面上的模型名整块消失（真机反馈过）。见 [_nameOrId]。
        name: _nameOrId(json),
        fileName: json['fileName'] as String,
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        installedAt:
            DateTime.tryParse((json['installedAt'] as String?) ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
        kind: (json['kind'] as String?) ?? 'text',
        engine: (json['engine'] as String?) ?? 'llama.cpp',
        format: (json['format'] as String?) ?? 'gguf',
        quant: (json['quant'] as String?) ?? '',
        license: (json['license'] as String?) ?? 'unknown',
        sha256: (json['sha256'] as String?)?.trim(),
        sourceLabel: (json['sourceLabel'] as String?) ?? '',
        companions: ((json['companions'] as List?) ?? const <dynamic>[])
            .map((e) => InstalledCompanion.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .toList(growable: false),
      );

  /// 显示名兜底链：name → id → fileName（三者都可能空，按序取第一个非空的）。
  ///
  /// 为什么需要：`name` 是后加的字段，老版本下载的条目里可能是**空字符串**，
  /// 而 `??` 只挡 null —— 界面会因为一个空字符串而整行没有名字。
  static String _nameOrId(Map<String, dynamic> json) {
    for (final k in <String>['name', 'id', 'fileName']) {
      final v = (json[k] as String?)?.trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'family': family,
        'name': name,
        'fileName': fileName,
        'bytes': bytes,
        'installedAt': installedAt.toIso8601String(),
        'kind': kind,
        'engine': engine,
        'format': format,
        'quant': quant,
        'license': license,
        'sha256': sha256,
        'sourceLabel': sourceLabel,
        // ⚠️ 曾经漏了这一行：只要回写一次登记表，伴生文件（mmproj / VAE / T5）记录
        // 就全没了 —— 下次读取会以为"这个模型不需要伴生"，于是**不该放行时放行**。
        'companions': <Map<String, dynamic>>[
          for (final c in companions) c.toJson(),
        ],
      };

  /// 只换名字的副本。
  ///
  /// 专用于「老版本把空名字写进登记表 → 用清单里的名字把它补回去」这一种自愈，
  /// 不做通用 copyWith：其他字段各有语义，随手改容易改坏。
  InstalledModel withName(String newName) => InstalledModel(
        id: id,
        family: family,
        name: newName,
        fileName: fileName,
        bytes: bytes,
        installedAt: installedAt,
        kind: kind,
        engine: engine,
        format: format,
        quant: quant,
        license: license,
        sha256: sha256,
        sourceLabel: sourceLabel,
        companions: companions,
      );

  /// 按"当初装它时清单里那条"重建（清单更新后 id 可能已不存在）。
  static InstalledModel fromEntry(
    OnDeviceModel entry, {
    required String? sha256,
    required int bytes,
    String sourceLabel = '',
    DateTime? at,
  }) =>
      InstalledModel(
        id: entry.id,
        family: entry.family,
        name: entry.name,
        fileName: entry.fileName,
        bytes: bytes,
        installedAt: at ?? DateTime.now(),
        kind: entry.kind,
        engine: entry.engine,
        format: entry.format,
        quant: entry.quant,
        license: entry.license,
        sha256: sha256,
        sourceLabel: sourceLabel,
        companions: <InstalledCompanion>[
          for (final c in entry.companions)
            InstalledCompanion(fileName: c.fileName, bytes: c.bytes),
        ],
      );
}

/// 已装模型的**登记表**（`<dir>/registry.json`）。
///
/// 两条纪律：
/// 1. **登记表不是真相，磁盘才是。** 读取时对每条都核对文件是否存在、大小是否一致；
///    对不上就标为"文件缺失/损坏"，而不是继续骗 UI 显示"已安装"。
/// 2. **写失败不抛错**（与 `ArtifactStore` 一致）：写登记表失败不该让下载白干 ——
///    文件已经校验并落盘，下次扫描能重新发现。
class LocalModelStore {
  LocalModelStore({required this.dir});

  /// 模型目录（通常是 `<DSH_HOME>/models`）。
  final String dir;

  String get registryPath => '$dir/registry.json';

  Map<String, InstalledModel>? _cache;

  String pathFor(String fileName) => '$dir/$fileName';

  String pathForEntry(OnDeviceModel entry) => pathFor(entry.fileName);

  /// 文件是否真的在，且大小与登记一致。
  bool fileOk(InstalledModel m) {
    final f = File(pathFor(m.fileName));
    if (!f.existsSync()) return false;
    final len = f.lengthSync();
    if (m.bytes > 0 && len != m.bytes) return false;
    // 伴生文件同样要验：缺了它多模态就"看不了图"，不能算安装完整。
    for (final c in m.companions) {
      final cf = File(pathFor(c.fileName));
      if (!cf.existsSync()) return false;
      if (c.bytes > 0 && cf.lengthSync() != c.bytes) return false;
    }
    return true;
  }

  /// 读登记表（带内存缓存）。
  Future<Map<String, InstalledModel>> list({bool refresh = false}) async {
    if (!refresh && _cache != null) return _cache!;
    final out = <String, InstalledModel>{};
    try {
      final f = File(registryPath);
      if (f.existsSync()) {
        final raw = jsonDecode(await f.readAsString());
        if (raw is Map) {
          final list = (raw['models'] as List?) ?? const <dynamic>[];
          for (final item in list) {
            if (item is Map) {
              try {
                final m =
                    InstalledModel.fromJson(Map<String, dynamic>.from(item));
                out[m.id] = m;
              } catch (e) {
                debugPrint('[dsh-models] 跳过一条坏记录：$e');
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[dsh-models] 读登记表失败（当作空）：$e');
    }
    _cache = out;
    return out;
  }

  Future<InstalledModel?> get(String id, {bool refresh = false}) async =>
      (await list(refresh: refresh))[id];

  /// 登记一个刚下载完成的模型。
  Future<void> register(InstalledModel model) async {
    final all = Map<String, InstalledModel>.from(await list());
    all[model.id] = model;
    await _flush(all);
  }

  /// 卸载：默认连文件一起删。
  Future<void> remove(String id, {bool deleteFile = true}) async {
    final all = Map<String, InstalledModel>.from(await list());
    final m = all.remove(id);
    if (deleteFile && m != null) {
      try {
        final f = File(pathFor(m.fileName));
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        debugPrint('[dsh-models] 删除模型文件失败：$e');
      }
    }
    await _flush(all);
  }

  /// 已装模型的总体积（设置页显示"占用 3.2 GB"用）。
  Future<int> totalBytes() async {
    var sum = 0;
    for (final m in (await list()).values) {
      if (fileOk(m)) sum += m.bytes;
    }
    return sum;
  }

  Future<void> _flush(Map<String, InstalledModel> all) async {
    _cache = all;
    try {
      await Directory(dir).create(recursive: true);
      final payload = <String, dynamic>{
        'version': 1,
        'updatedAt': DateTime.now().toIso8601String(),
        'models': all.values.map((m) => m.toJson()).toList(),
      };
      await writeStringAtomic(
          File(registryPath), const JsonEncoder.withIndent('  ').convert(payload));
    } catch (e) {
      debugPrint('[dsh-models] 写登记表失败（文件已落盘，下次扫描可恢复）：$e');
    }
  }
}
