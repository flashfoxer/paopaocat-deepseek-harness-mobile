import 'dart:io';

import 'package:flutter/foundation.dart';

/// 一条技能（目录束形式：`<root>/<name>/SKILL.md`）。
class SkillEntry {
  const SkillEntry({
    required this.name,
    required this.description,
    required this.path,
    required this.root,
    required this.origin,
  });

  /// 技能名（DSH 要求 kebab-case 小写；同时就是目录名）。
  final String name;

  /// 路由简介（DSH 用它决定"什么时候该用这个技能"）。
  final String description;

  /// `SKILL.md` 的绝对路径。
  final String path;

  /// 技能根目录（用户级 / 项目级）。
  final String root;

  /// 来源：`user` = `$DSH_HOME/skills`，`project` = `<工作区>/.dsh/skills`。
  final String origin;

  bool get isUser => origin == 'user';
}

/// 读写 DSH **真实**技能目录。
///
/// 为什么这两个根目录是对的（都在 DSH 源码里核对过，不是猜的）：
/// `@deepseek-ai/dsh-skill-filesystem` 的 `roots()` 会扫描
///   - 项目级：`<projectRoot>/.dsh/skills`（rank 100，`source: project-dsh`）
///   - 用户级：`<DSH_HOME>/skills`（rank 400，`source: user-dsh`）
/// 而 `dsh-base` 默认挂载了这个 provider（`cordis.patch.yml` 第 296-297 行），
/// `dsh-tool-skill` 会把它们编成会话里的技能目录交给模型。
///
/// 文件格式同样来自 DSH 自己的实现（`dsh-skills-manager/lib/core.js` 的 `createSkill`
/// 与 `dsh-skill-filesystem` 的 `parseSkillFile`）：
/// ```
/// ---
/// name: <kebab-case>
/// description: "<json 转义的简介>"
/// ---
///
/// <Markdown 正文>
/// ```
/// 技能名必须匹配 `^[a-z0-9]+(?:-[a-z0-9]+)*$`（`dsh-skill` 里的 `SKILL_NAME`），
/// 这是 DSH 的硬约束 —— 界面上要如实提示，而不是放个中文名进去然后静默失败。
class SkillStore {
  SkillStore({required this.dshHome, this.workspacePath});

  final String dshHome;

  /// 当前工作区（项目级技能根 = `<workspace>/.dsh/skills`）。为 null 时只读用户级。
  final String? workspacePath;

  static final RegExp namePattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

  String get userRoot => '$dshHome/skills';

  String? get projectRoot {
    final ws = workspacePath;
    if (ws == null || ws.isEmpty) return null;
    return '$ws/.dsh/skills';
  }

  /// DSH 的技能名规范（给界面做提示用）。
  static const String nameRule = '只能用小写字母 a-z、数字 0-9 和连字符 -，'
      '例如 daily-report（这是 DSH 的技能名规范，中文请写在「简介」里）';

  /// 列出两个根目录下的全部技能（用户级在前）。
  Future<List<SkillEntry>> list() async {
    final out = <SkillEntry>[];
    final seen = <String>{};
    for (final entry in [
      (root: userRoot, origin: 'user'),
      if (projectRoot != null) (root: projectRoot!, origin: 'project'),
    ]) {
      final dir = Directory(entry.root);
      if (!dir.existsSync()) continue;
      List<FileSystemEntity> children;
      try {
        children = dir.listSync();
      } catch (e) {
        debugPrint('[dsh-skill] 无法列出 ${entry.root}: $e');
        continue;
      }
      for (final child in children) {
        if (child is! Directory) continue;
        final name = child.path.split(Platform.pathSeparator).last;
        final file = File('${child.path}${Platform.pathSeparator}SKILL.md');
        if (!file.existsSync()) continue;
        // 同名时用户级优先（与 DSH 的 rank 相反也没关系：这里只是列表展示，
        // 真正生效的优先级由 DSH 决定，界面按"用户级在前"排序更好用）。
        final key = '$name@${entry.origin}';
        if (!seen.add(key)) continue;
        final parsed = await _readFrontmatter(file);
        out.add(SkillEntry(
          name: parsed.name.isEmpty ? name : parsed.name,
          description: parsed.description,
          path: file.path,
          root: entry.root,
          origin: entry.origin,
        ));
      }
    }
    out.sort((a, b) {
      if (a.isUser != b.isUser) return a.isUser ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    debugPrint('[dsh-skill] 技能目录：${out.length} 条'
        '（user=$userRoot, project=${projectRoot ?? '-'}）');
    return out;
  }

  /// 读取技能正文（供编辑 / 查看）。
  Future<String> readBody(SkillEntry skill) async {
    final text = await File(skill.path).readAsString();
    return _splitFrontmatter(text).body;
  }

  /// 新建技能。返回 `null` 表示成功，否则是给用户看的中文错误。
  Future<String?> create({
    required String name,
    required String description,
    required String body,
  }) async {
    final raw = name.trim().toLowerCase();
    if (!namePattern.hasMatch(raw)) return '技能名不合法：$nameRule';
    if (description.trim().isEmpty) return '简介不能为空';
    if (body.trim().isEmpty) return '技能正文不能为空';

    final children = _childNames(userRoot);
    if (children.contains(raw)) return '同名技能已存在：$raw';

    try {
      final dir = Directory('$userRoot${Platform.pathSeparator}$raw');
      dir.createSync(recursive: true);
      await File('${dir.path}${Platform.pathSeparator}SKILL.md').writeAsString(
          _render(raw, description.trim(), body.trim()),
          flush: true);
      debugPrint('[dsh-skill] 已创建技能 $raw → ${dir.path}');
      return null;
    } catch (e) {
      debugPrint('[dsh-skill] 创建技能失败：$e');
      return '创建失败：$e';
    }
  }

  /// 覆盖已有技能（不存在则报错，避免"以为在改其实新建了一个"）。
  Future<String?> update({
    required SkillEntry skill,
    required String description,
    required String body,
  }) async {
    if (!File(skill.path).existsSync()) return '技能文件已不存在：${skill.path}';
    if (description.trim().isEmpty) return '简介不能为空';
    if (body.trim().isEmpty) return '技能正文不能为空';
    try {
      await File(skill.path).writeAsString(
          _render(skill.name, description.trim(), body.trim()),
          flush: true);
      debugPrint('[dsh-skill] 已更新技能 ${skill.name} → ${skill.path}');
      return null;
    } catch (e) {
      debugPrint('[dsh-skill] 更新技能失败：$e');
      return '保存失败：$e';
    }
  }

  /// 删除技能（只在**用户级**根目录允许，项目级由工作区自己管）。
  Future<String?> delete(SkillEntry skill) async {
    if (!skill.isUser) return '项目级技能请在项目目录里删（界面只管理 $userRoot）';
    try {
      final dir =
          Directory('${skill.root}${Platform.pathSeparator}${skill.name}');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      debugPrint('[dsh-skill] 已删除技能 ${skill.name}');
      return null;
    } catch (e) {
      debugPrint('[dsh-skill] 删除技能失败：$e');
      return '删除失败：$e';
    }
  }

  List<String> _childNames(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) return const [];
    try {
      return [
        for (final c in dir.listSync())
          if (c is Directory) c.path.split(Platform.pathSeparator).last,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 与 DSH 完全一致的落盘格式（含 YAML 字符串转义）。
  static String _render(String name, String description, String body) {
    final escaped = description
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n');
    return '---\nname: $name\ndescription: "$escaped"\n---\n\n$body\n';
  }

  Future<({String name, String description})> _readFrontmatter(
      File file) async {
    try {
      final text = await file.readAsString();
      final split = _splitFrontmatter(text);
      return (name: split.name, description: split.description);
    } catch (e) {
      debugPrint('[dsh-skill] 解析 ${file.path} 失败：$e');
      return (name: '', description: '');
    }
  }

  static ({String name, String description, String body}) _splitFrontmatter(
      String text) {
    final norm = text.startsWith('\uFEFF') ? text.substring(1) : text;
    final m = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---\r?\n?').firstMatch(norm);
    if (m == null) return (name: '', description: '', body: norm);
    var name = '';
    var description = '';
    for (final line in m.group(1)!.split(RegExp(r'\r?\n'))) {
      final i = line.indexOf(':');
      if (i < 0) continue;
      final key = line.substring(0, i).trim();
      var value = line.substring(i + 1).trim();
      if (value.length > 1 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      value = value
          .replaceAll('\\n', '\n')
          .replaceAll('\\"', '"')
          .replaceAll('\\\\', '\\');
      if (key == 'name') name = value;
      if (key == 'description') description = value;
    }
    return (name: name, description: description, body: norm.substring(m.end));
  }
}
