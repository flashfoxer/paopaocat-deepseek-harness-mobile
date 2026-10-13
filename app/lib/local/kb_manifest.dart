/// 知识库清单（`assets/kb/kb_manifest.json`）的解析。
///
/// ## 知识库是什么
///
/// 给**本地模型**用的一包离线资料（百科/手册/笔记）。它和云端模型无关 ——
/// 用户在「本地对话」里提问时，检索到的片段会被折进那一轮的问题里，
/// 走的还是同一条“参考资料注入”通道（与联网搜索共用）。
///
/// ## 为什么单独一份清单
///
/// 模型清单（`model_manifest.json`）管的是“模型文件”，这里管的是“资料文件”，
/// 两者的下载路径不同（模型要内存匹配，资料不需要），混在一起会让两边都变难读。
///
/// ⚠️ 校验口径**已经**不是“只看体积”了（2026-10-09，审计 P0-4）：
/// 清单里的 [KbPack.sha256] 若给了就**必须**一致；没给才退回体积校验，
/// 而且那时界面会如实写“仅体积校验”。同长度的损坏/篡改只有 sha256 能发现。
///
/// ## 许可红线
///
/// 只收**明确允许再分发**的数据（维基百科是 CC BY-SA）。没有授权 dump 的站点
/// （如百度百科）一律不收 —— 这不是技术问题，是合规问题。
library;

import 'dart:convert';

/// 一个下载源（按 [priority] 从小到大试）。
class KbSource {
  const KbSource({required this.label, required this.url, this.priority = 0});

  final String label;
  final String url;
  final int priority;

  static KbSource? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final label = raw['label'];
    final url = raw['url'];
    if (label is! String || url is! String || url.trim().isEmpty) return null;
    return KbSource(
      label: label,
      url: url,
      priority: (raw['priority'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 一包可下载/可导入的资料。
class KbPack {
  const KbPack({
    required this.id,
    required this.name,
    required this.kind,
    required this.format,
    required this.textField,
    required this.bundled,
    required this.fileName,
    required this.bytes,
    required this.entries,
    required this.license,
    required this.note,
    required this.sources,
    this.sha256 = '',
  });

  final String id;
  final String name;

  /// 资料类型（现在只有 `encyclopedia`，以后可以有 `manual` / `notes`）。
  final String kind;

  /// 文件格式（现在只认 `json-array`：一个 JSON 数组，每条一个对象）。
  final String format;

  /// 正文在哪个字段（这份清洗版是 `completion`）。
  final String textField;

  /// 是不是随包附带（不用下载，直接从 assets 装）。
  final bool bundled;

  final String fileName;
  final int bytes;

  /// 条目数（清单里写好的）。0 = 未知（导入的文件会在建索引时统计）。
  final int entries;
  final String license;
  final String note;

  /// 整包的 sha256（小写十六进制）。空串 = **清单没给**，此时只剩体积校验。
  ///
  /// 为什么必须补上它（审计 P0-4）：原来只看 `bytes` —— **同长度的损坏/篡改
  /// 完全发现不了**。HTTPS 挡的是传输途中的第三方，挡不了"上游换了文件"或
  /// "落盘时写坏了同样多的字节"。
  ///
  /// 为什么是"可以空"而不是"必填"：历史清单里没有这个字段，硬要求会让
  /// 页面直接没得用。空的时候由界面/日志**如实说"仅体积校验"**，
  /// 不谎称已校验（口径与 `model_downloader` 的 `hashVerified` 一致）。
  final String sha256;
  final List<KbSource> sources;

  List<KbSource> get sortedSources =>
      List<KbSource>.from(sources)..sort((a, b) => a.priority.compareTo(b.priority));

  static KbPack? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String s(String k) => (raw[k] as String?)?.trim() ?? '';
    final id = s('id');
    final fileName = s('fileName');
    if (id.isEmpty || fileName.isEmpty) return null;
    return KbPack(
      id: id,
      name: s('name').isEmpty ? id : s('name'),
      kind: s('kind').isEmpty ? 'encyclopedia' : s('kind'),
      format: s('format').isEmpty ? 'json-array' : s('format'),
      textField: s('textField').isEmpty ? 'text' : s('textField'),
      bundled: raw['bundled'] == true,
      fileName: fileName,
      bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
      entries: (raw['entries'] as num?)?.toInt() ?? 0,
      license: s('license'),
      note: s('note'),
      // 统一成小写，比对时不用再做大小写兼容。
      sha256: s('sha256').toLowerCase(),
      sources: <KbSource>[
        for (final e in (raw['sources'] as List? ?? const <Object?>[]))
          if (KbSource.fromJson(e) != null) KbSource.fromJson(e)!,
      ],
    );
  }
}

/// 整份清单。**解析失败一律退回空清单**（不让一个坏 JSON 把页面卡死）。
class KbManifest {
  const KbManifest({required this.version, required this.packs});

  final int version;
  final List<KbPack> packs;

  static const KbManifest empty = KbManifest(version: 0, packs: <KbPack>[]);

  KbPack? byId(String id) {
    for (final p in packs) {
      if (p.id == id) return p;
    }
    return null;
  }

  static KbManifest parse(String text) {
    try {
      final raw = jsonDecode(text);
      if (raw is! Map) return empty;
      final list = raw['packs'];
      return KbManifest(
        version: (raw['version'] as num?)?.toInt() ?? 0,
        packs: <KbPack>[
          for (final e in (list as List? ?? const <Object?>[]))
            if (KbPack.fromJson(e) != null) KbPack.fromJson(e)!,
        ],
      );
    } catch (_) {
      return empty;
    }
  }
}
