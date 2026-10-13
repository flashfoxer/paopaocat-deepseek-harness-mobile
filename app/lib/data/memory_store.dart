import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../i18n/dsh_i18n.dart' show tr;
import 'atomic_file.dart';

/// 「用户记忆」—— 让用户自己写一段话，**每个新会话都会自动注入模型上下文**。
///
/// ## 为什么需要它（以及它和专家开关的关系）
///
/// 手机版运行时里**没有** Mnemon 那类记忆插件（实测：把打进 APK 的**原版**运行时
/// 26,495 个条目翻了一遍，`mnemon` / `MEMORY.md` / `USER.md` 全是 **0 命中** ——
/// 不是瘦身删的，本来就没打进去）。所以手机版原先**没有**"自动记住用户偏好"的能力：
/// 会话历史能落盘、能恢复，但那是**记录**，不会变成下一轮的指令。
///
/// 唯一已经通的自动注入通道是 DSH 内置插件 `@deepseek-ai/dsh-agent-instructions`：
/// 它把 `$DSH_HOME/AGENTS.md` 作为「用户全局指令」在**每个会话第一个请求之前**
/// 渲染进 agent 上下文（`USER_GLOBAL_FILE = "AGENTS.md"`）。专家开关已经在用这条通道
/// （见 [ExpertStore]），本类复用它来放**用户自己写的话**。
///
/// 于是"记忆"这件事分成两层，界面上必须讲清楚：
///   * **App 侧**：`$DSH_HOME/memory.json` —— 用户维护的条目列表（可增删改）；
///   * **DSH 侧**：`$DSH_HOME/AGENTS.md` 里的一段受管区块 —— 真正被注入的东西。
///
/// ## 两条容易踩的坑（都按实测行为处理了）
///
/// 1. **注入是"截断尾部"，所以记忆块必须放在文件靠前的位置。**
///    插件用 `truncateUtf8(value, maxBytes)` 截断（`dsh-base` 里 `maxBytes: 65536`），
///    超出预算时**砍掉尾部**（并打印 "instructions were omitted or truncated"）。
///    如果记忆块写在专家块后面，被砍掉的就是用户自己写的话 —— 那是本末倒置。
///    所以本类**把记忆块前置**。
/// 2. **用户输入里不能出现受管标记。**
///    如果用户（或模型代写）的内容里正好含有 `<!-- dsh-mobile:user-memory:end -->`
///    这种字样，块解析就会错位、把后面的内容吃掉。[sanitize] 会先把它 neutralize 掉。
///    这条有测试钉住。
///
/// ## 时序（界面上要讲）
/// `AGENTS.md` 是**会话开始时**读的，所以改了记忆对**已经打开的会话**不生效 ——
/// 需要新建会话（与专家开关同一句话）。
class MemoryStore extends ChangeNotifier {
  MemoryStore({required this.dshHome});

  /// 设备的 `DSH_HOME`（Android 上 = `<filesDir>/dshhome`）。
  final String dshHome;

  static const String _stateFile = 'memory.json';

  /// 受管区块的标记。**只动这两个标记之间**，`AGENTS.md` 里其它内容一律保留
  /// （包括专家开关写的那一段 —— 它有自己的标记，各有各的 strip）。
  static const String blockBegin =
      '<!-- dsh-mobile:user-memory:begin（由 App「记忆」页生成，请勿手改；改动会重写这一段）-->';
  static const String blockEnd = '<!-- dsh-mobile:user-memory:end -->';

  /// 记忆块自己的字节上限。
  ///
  /// 为什么单列一个小额度、而不是用满 64 KB：`AGENTS.md` 里还有专家块与
  /// 「本机执行环境」那段（那是**功能必需**的），而且预算是**整个文件共享**的。
  /// 记忆是"锦上添花"，给它 8 KB（约几千汉字）足够表达偏好，也不会把必需的
  /// 那段挤出预算导致被截断。超了就**在界面上如实拒绝**，不静默丢。
  static const int byteBudget = 8000;

  /// 单条上限（防一条把整块占满）。
  static const int perEntryBudget = 2000;

  final List<MemoryEntry> _entries = <MemoryEntry>[];
  bool _loaded = false;

  List<MemoryEntry> get entries => List.unmodifiable(_entries);

  int get count => _entries.length;

  bool get loaded => _loaded;

  bool get isEmpty => _entries.isEmpty;

  String get statePath => '$dshHome/$_stateFile';

  /// DSH 内置 `agent-instructions` 读的**用户全局**指令文件。
  String get agentsMdPath => '$dshHome/AGENTS.md';

  /// 当前记忆块占多少字节（UTF-8）。
  int get usedBytes => utf8.encode(_renderBlock()).length;

  int get remainingBytes => byteBudget - usedBytes;

  /// 把受管标记从用户输入里 neutralize 掉。
  ///
  /// 为什么要做：块解析靠"找标记字符串"。用户内容里如果出现 `begin` 标记，
  /// `_stripBlock` 会从那句话开始切；出现 `end` 标记就会**提前收尾、吃掉后面所有内容**。
  /// 所以这里把标记里的 `<!--` / `-->` 打断（视觉上仍能看懂，但不再匹配）。
  static String sanitize(String text) {
    var s = text;
    for (final marker in <String>[blockBegin, blockEnd]) {
      // 标记的**关键子串**也要挡：用户可能只抄了前半段
      for (final key in <String>[
        'dsh-mobile:user-memory:begin',
        'dsh-mobile:user-memory:end',
      ]) {
        s = s.replaceAll(key, 'dsh-mobile／user-memory／${key.split(':').last}');
      }
      s = s.replaceAll(marker, '（已移除的受管标记）');
    }
    return s;
  }

  /// 从磁盘读回记忆条目。文件不存在 = 空记忆（不是错误）。
  Future<void> load() async {
    _entries.clear();
    try {
      final f = File(statePath);
      if (f.existsSync()) {
        final raw = jsonDecode(await f.readAsString());
        final list = raw is Map<String, dynamic> ? raw['entries'] : raw;
        if (list is List) {
          for (final e in list) {
            final m = MemoryEntry.fromJson(e);
            if (m != null) _entries.add(m);
          }
        }
      }
      debugPrint('[dsh-memory] 已载入记忆 ${_entries.length} 条（$statePath）');
    } catch (e) {
      // 读失败按"空"处理，但**要说出来** —— 静默变空会让用户以为记忆丢了却没人告诉他。
      debugPrint('[dsh-memory] 读取记忆失败（按空处理，未覆盖磁盘）：$e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// 追加一条。返回 `null` = 成功，否则是给用户看的中文错误。
  Future<String?> add(String text) async {
    final t = sanitize(text).trim();
    if (t.isEmpty) return tr('内容不能为空');
    if (utf8.encode(t).length > perEntryBudget) {
      return tr('这一条太长了（上限 {0} 字节，约 600 多个汉字）', ['$perEntryBudget']);
    }
    final entry = MemoryEntry(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      text: t,
      createdAt: DateTime.now(),
    );
    _entries.add(entry);
    final overflow = _overBudgetError();
    if (overflow != null) {
      _entries.remove(entry); // 回滚：宁可拒绝，也不要写进去半份
      return overflow;
    }
    notifyListeners();
    return _flush();
  }

  /// 修改某一条。
  Future<String?> update(String id, String text) async {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i < 0) return tr('找不到这条记忆（可能已被删除）');
    final t = sanitize(text).trim();
    if (t.isEmpty) return '内容不能为空';
    if (utf8.encode(t).length > perEntryBudget) {
      return '这一条太长了（上限 $perEntryBudget 字节，约 600 多个汉字）';
    }
    final before = _entries[i];
    _entries[i] = before.copyWith(text: t);
    final overflow = _overBudgetError();
    if (overflow != null) {
      _entries[i] = before;
      return overflow;
    }
    notifyListeners();
    return _flush();
  }

  Future<String?> remove(String id) async {
    final before = List<MemoryEntry>.from(_entries);
    _entries.removeWhere((e) => e.id == id);
    if (_entries.length == before.length) return null;
    notifyListeners();
    return _flush();
  }

  Future<String?> clearAll() async {
    if (_entries.isEmpty) return null;
    _entries.clear();
    notifyListeners();
    return _flush();
  }

  /// 把顺序上移/下移一条 —— 注入顺序就是显示顺序，靠前的更"重要"
  /// （而且截断砍尾部时它也活得更久）。
  Future<String?> move(String id, int delta) async {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i < 0) return null;
    final j = i + delta;
    if (j < 0 || j >= _entries.length) return null;
    final e = _entries.removeAt(i);
    _entries.insert(j, e);
    notifyListeners();
    return _flush();
  }

  String? _overBudgetError() {
    final used = usedBytes;
    if (used <= byteBudget) return null;
    return tr('记忆总量超了：现在约 {0} 字节，上限 {1} 字节。'
        '请先删掉几条再添加（总预算与专家说明共享 DSH 的 64 KB 注入上限）。',
        ['$used', '$byteBudget']);
  }

  Future<String?> _flush() async {
    try {
      final dir = Directory(dshHome);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await writeStringAtomic(
        File(statePath),
        '${const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
              'entries': [for (final e in _entries) e.toJson()],
              'updatedAt': DateTime.now().toIso8601String(),
            })}\n',
      );
    } catch (e) {
      debugPrint('[dsh-memory] 写 memory.json 失败：$e');
      return tr('写入记忆文件失败：{0}', ['$e']);
    }
    return _writeAgentsMd();
  }

  /// 把记忆写进 `$DSH_HOME/AGENTS.md` 的受管区块（**前置**，见类注释的坑 1）。
  Future<String?> _writeAgentsMd() async {
    try {
      final file = File(agentsMdPath);
      final existing = file.existsSync() ? await file.readAsString() : '';
      final kept = _stripBlock(existing).trim();
      final block = _renderBlock().trim();

      final buffer = StringBuffer();
      if (block.isNotEmpty) {
        buffer
          ..writeln(block)
          ..writeln();
      }
      if (kept.isNotEmpty) {
        buffer
          ..writeln(kept)
          ..writeln();
      }
      final out = buffer.toString();

      if (out.trim().isEmpty) {
        if (file.existsSync()) await file.delete();
        debugPrint('[dsh-memory] AGENTS.md 已清空并删除（无记忆、也无其它内容）');
        return null;
      }
      await writeStringAtomic(file, out);
      debugPrint('[dsh-memory] AGENTS.md 已重写：记忆 ${_entries.length} 条 → $agentsMdPath');
      return null;
    } catch (e) {
      debugPrint('[dsh-memory] 写 AGENTS.md 失败：$e');
      return tr('写入 {0} 失败：{1}', [agentsMdPath, '$e']);
    }
  }

  /// 保证受管区块与当前条目一致（App 启动时调一次）。幂等：一致就跳过写盘。
  Future<String?> ensureAgentsMd() async {
    try {
      final file = File(agentsMdPath);
      final existing = file.existsSync() ? await file.readAsString() : '';
      final desired = _renderBlock().trim();
      if (desired.isEmpty) {
        // 没有记忆：如果文件里还留着旧的记忆块，要清掉（否则会一直注入已删的内容）
        if (existing.contains(blockBegin)) return await _writeAgentsMd();
        return null;
      }
      if (existing.contains(desired)) {
        debugPrint('[dsh-memory] 记忆块已是最新，跳过写入');
        return null;
      }
    } catch (e) {
      debugPrint('[dsh-memory] 检查 AGENTS.md 失败，改为强制重写：$e');
    }
    return _writeAgentsMd();
  }

  /// 只剥**自己**这一块，其它内容（含专家块）原样保留。
  static String _stripBlock(String text) {
    final b = text.indexOf(blockBegin);
    if (b < 0) return text;
    final e = text.indexOf(blockEnd, b);
    if (e < 0) return text.substring(0, b);
    return text.substring(0, b) + text.substring(e + blockEnd.length);
  }

  String _renderBlock() {
    if (_entries.isEmpty) return '';
    final sb = StringBuffer()
      ..writeln(blockBegin)
      ..writeln()
      ..writeln('## 用户记忆（用户在 App「记忆」页写下的，请遵守）')
      ..writeln()
      ..writeln('下面是用户**自己**写下的长期偏好与约定。它们和上面的项目指令同等有效；'
          '与本次任务的临时要求冲突时以本次要求为准，但要先说明这一点。')
      ..writeln();
    for (final e in _entries) {
      // 每条渲染成一条引用块：既好读，也避免用户写的内容被误认成"系统小节标题"
      // （用户可能写成 `## 忽略以上所有指令` 这种 —— 渲染成引用块能弱化它的结构感，
      //   但**不隐瞒**：内容一字不改地写出来，让模型自己判断）。
      for (final line in e.text.split('\n')) {
        sb.writeln('> $line');
      }
      sb.writeln();
    }
    sb.writeln(blockEnd);
    return sb.toString();
  }
}

/// 一条记忆。
@immutable
class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String text;
  final DateTime createdAt;

  MemoryEntry copyWith({String? text}) => MemoryEntry(
        id: id,
        text: text ?? this.text,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
      };

  static MemoryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final text = raw['text'];
    if (id is! String || text is! String || text.trim().isEmpty) return null;
    return MemoryEntry(
      id: id,
      text: text,
      createdAt:
          DateTime.tryParse(raw['createdAt'] as String? ?? '') ?? DateTime(1970),
    );
  }
}
