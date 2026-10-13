import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// 面向模型的「专家」目录（内置快照）。
///
/// **数据来源（重要，不要改成编造的假数据）**：
/// 资产 `assets/experts/agency_catalog.json` 由 `install/build-expert-catalog.mjs`
/// 从**本机已安装的 DSH 插件** `@michengai/dsh-agency-agents`（The Agency，Apache-2.0）
/// 的中文资产目录 `assets/agency-agents-zh/<分区>/<slug>.md` 解析而来：
/// 名称 / 简介取 frontmatter 的 `name` / `description`，`brief` 取正文「核心使命」小节。
/// 全部是插件原文，没有任何一条是本项目自己编的。
///
/// **能力边界（诚实说明）**：手机运行时（`app-assets/dsh-runtime.zip`）里**不含**这个插件，
/// 所以这里的目录只是一份快照，App 无法调用插件的 `summon_experts` 召唤引擎。
/// 「开关真起作用」走的是 DSH 内置的 `agent-instructions` 通道，见 [ExpertStore]。
class ExpertCatalog {
  ExpertCatalog({
    required this.sourcePackage,
    required this.sourceVersion,
    required this.sourceNote,
    required this.snapshotAt,
    required this.divisions,
    required this.experts,
  });

  /// 来源插件包名，例如 `@michengai/dsh-agency-agents`。
  final String sourcePackage;

  /// 来源插件版本，例如 `1.0.5`。
  final String sourceVersion;

  /// 来源说明（原样来自 JSON，界面上要能读到）。
  final String sourceNote;

  /// 快照日期（`YYYY-MM-DD`）。
  final String snapshotAt;

  final List<ExpertDivision> divisions;
  final List<ExpertEntry> experts;

  /// slug → 专家，供开关状态反查显示用。
  late final Map<String, ExpertEntry> bySlug = {
    for (final e in experts) e.slug: e,
  };

  static ExpertCatalog? _cached;

  /// 读一次并缓存（资产解析 ~165 KB，不必每次进页面都做）。
  static Future<ExpertCatalog> load({bool force = false}) async {
    if (!force && _cached != null) return _cached!;
    final raw =
        await rootBundle.loadString('assets/experts/agency_catalog.json');
    _cached = decode(raw);
    return _cached!;
  }

  /// 纯解析（便于单测/脚本复用，不碰 asset bundle）。
  static ExpertCatalog decode(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final src = Map<String, dynamic>.from(map['source'] as Map? ?? const {});
    return ExpertCatalog(
      sourcePackage: src['package'] as String? ?? '?',
      sourceVersion: src['version'] as String? ?? '?',
      sourceNote: src['note'] as String? ?? '',
      snapshotAt: src['snapshotAt'] as String? ?? '?',
      divisions: [
        for (final d in (map['divisions'] as List? ?? const []))
          ExpertDivision.fromJson(Map<String, dynamic>.from(d as Map)),
      ],
      experts: [
        for (final e in (map['experts'] as List? ?? const []))
          ExpertEntry.fromJson(Map<String, dynamic>.from(e as Map)),
      ],
    );
  }
}

/// 一个行业分区（对应插件里的一个资产目录，如 `engineering` → 「工程」）。
class ExpertDivision {
  const ExpertDivision(
      {required this.slug, required this.name, required this.count});

  final String slug;

  /// 中文分区名，来自插件源码的 `ZH_DIVISION` 映射表。
  final String name;
  final int count;

  factory ExpertDivision.fromJson(Map<String, dynamic> j) => ExpertDivision(
        slug: j['slug'] as String? ?? '',
        name: j['name'] as String? ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
      );
}

/// 一名专家。
class ExpertEntry {
  const ExpertEntry({
    required this.slug,
    required this.division,
    required this.name,
    required this.description,
    required this.emoji,
    required this.brief,
  });

  /// 插件资产文件名（不含 `.md`），全局唯一，用作开关的主键。
  final String slug;

  /// 所属分区 slug。
  final String division;

  /// 专家名（插件 frontmatter 的 `name`）。
  final String name;

  /// 一句话简介（插件 frontmatter 的 `description`）。
  final String description;

  /// 插件 frontmatter 里的 emoji（可能为空）。
  final String emoji;

  /// 正文「核心使命」摘要，用于写进 AGENTS.md 让模型真的看到职责。
  final String brief;

  factory ExpertEntry.fromJson(Map<String, dynamic> j) => ExpertEntry(
        slug: j['slug'] as String? ?? '',
        division: j['division'] as String? ?? '',
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        emoji: j['emoji'] as String? ?? '',
        brief: j['brief'] as String? ?? '',
      );
}
