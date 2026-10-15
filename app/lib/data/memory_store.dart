import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../i18n/dsh_i18n.dart' show tr;
import 'atomic_file.dart';

/// 「用户记忆」—— 让用户（或模型按用户确认）写下**跨会话长期有效**的信息，
/// **每个新会话都会自动注入模型上下文**。
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
/// ## 数据模型 v2（v1 无损兼容）
///
/// ```json
/// {"version":2,
///  "settings":{"enabled":true,"autoSuggest":false},
///  "entries":[{"id":"m…","text":"…","kind":"identity|preference|project|avoid|other",
///              "importance":2,"scope":"global","workspace":null,
///              "source":"manual|extracted","createdAt":"ISO-8601"}],
///  "updatedAt":"ISO-8601"}
/// ```
///
/// v1（`{"entries":[{"id","text","createdAt"}]}` 或**裸数组**）必须能**无损**读进来：
/// 缺字段给默认值（[MemoryKind.other] / importance 2 / [MemoryScope.global] /
/// [MemorySource.manual]），读的时候不改写用户的原文，下一次写盘才升到 v2。
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
  ///
  /// ⚠️ **这两个字符串不许改**：老设备上已经写进 `AGENTS.md` 的块是用旧标记包着的，
  /// 一改就再也剥不掉 —— 文件里会同时残留两块，模型会同时看到新旧两份记忆。
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

  /// 当前盘上 JSON 的结构版本（v1 读进来也按 v2 解释）。
  static const int schemaVersion = 2;

  final List<MemoryEntry> _entries = <MemoryEntry>[];
  bool _loaded = false;
  bool _enabled = true;
  bool _autoSuggest = false;

  List<MemoryEntry> get entries => List.unmodifiable(_entries);

  int get count => _entries.length;

  bool get loaded => _loaded;

  bool get isEmpty => _entries.isEmpty;

  /// 总开关：`false` = **整块**从 `AGENTS.md` 移除（条目本身保留，页面照常可管理），
  /// 重新打开能把同一批条目原样写回去。
  bool get enabled => _enabled;

  /// 「从会话提炼」是否自动弹出建议（本版本只存开关状态，不自动写盘、不自动加条目）。
  bool get autoSuggest => _autoSuggest;

  String get statePath => '$dshHome/$_stateFile';

  /// DSH 内置 `agent-instructions` 读的**用户全局**指令文件。
  String get agentsMdPath => '$dshHome/AGENTS.md';

  /// 当前记忆块占多少字节（UTF-8）。
  ///
  /// 口径是**条目渲染出来的字节数**，与开关无关：关掉注入不等于可以超预算 ——
  /// 重新打开时那份块要能一次写完，所以超限照样拒绝。
  int get usedBytes => utf8.encode(renderBlock()).length;

  int get remainingBytes => byteBudget - usedBytes;

  /// 真正会被注入的字节数（关掉总开关 = 0）。
  int get injectedBytes => _enabled ? usedBytes : 0;

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
  ///
  /// v1 结构（无 `version` / 无 `settings` / 裸数组）**无损**读入：
  /// 只补默认值，绝不改写 `text` 本身。
  Future<void> load() async {
    _entries.clear();
    _enabled = true;
    _autoSuggest = false;
    try {
      final f = File(statePath);
      if (f.existsSync()) {
        final raw = jsonDecode(await f.readAsString());
        Object? listRaw;
        var version = 1;
        if (raw is Map) {
          listRaw = raw['entries'];
          if (raw['version'] is num) version = (raw['version'] as num).toInt();
          final s = raw['settings'];
          if (s is Map) {
            if (s['enabled'] is bool) _enabled = s['enabled'] as bool;
            if (s['autoSuggest'] is bool) _autoSuggest = s['autoSuggest'] as bool;
          }
        } else {
          // v0/v1 的裸数组形态
          listRaw = raw;
        }
        if (listRaw is List) {
          for (final e in listRaw) {
            final m = MemoryEntry.fromJson(e);
            if (m != null) _entries.add(m);
          }
        }
        if (version < schemaVersion) {
          debugPrint('[dsh-memory] 读到 v$version 结构（${_entries.length} 条），'
              '已按 v$schemaVersion 解释（缺分类/重要度/范围的条目取默认值）');
        }
      }
      debugPrint('[dsh-memory] 已载入记忆 ${_entries.length} 条'
          '（注入=${_enabled ? '开' : '关'}，$statePath）');
    } catch (e) {
      // 读失败按"空"处理，但**要说出来** —— 静默变空会让用户以为记忆丢了却没人告诉他。
      debugPrint('[dsh-memory] 读取记忆失败（按空处理，未覆盖磁盘）：$e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// 追加一条。返回 `null` = 成功，否则是给用户看的中文错误。
  ///
  /// v1 的调用点（只传 text）照样能用：其它字段取默认值。
  Future<String?> add(
    String text, {
    MemoryKind kind = MemoryKind.other,
    int importance = 2,
    MemoryScope scope = MemoryScope.global,
    String? workspace,
    MemorySource source = MemorySource.manual,
  }) async {
    final err = _validate(text, scope, workspace);
    if (err != null) return err;
    final entry = MemoryEntry(
      id: _newId(),
      text: sanitize(text).trim(),
      kind: kind,
      importance: clampImportance(importance),
      scope: scope,
      workspace: scope == MemoryScope.workspace ? workspace!.trim() : null,
      source: source,
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

  /// 加入一条**提炼候选**（用户在候选确认界面勾选后走这里）。
  ///
  /// 单独开一个入口而不是让界面直接调 [add]：这样"来源=extracted"不会被漏掉，
  /// 界面上也能如实标出"这条是模型建议的"。
  Future<String?> addFromCandidate({
    required String text,
    MemoryKind kind = MemoryKind.other,
    int importance = 2,
    MemoryScope scope = MemoryScope.global,
    String? workspace,
  }) =>
      add(
        text,
        kind: kind,
        importance: importance,
        scope: scope,
        workspace: workspace,
        source: MemorySource.extracted,
      );

  /// 修改某一条。只传需要改的字段（[text] 传 null = 不改文本）。
  ///
  /// 任何一项改完都必须重新过预算检查：改长了一条也可能把整块顶爆。
  Future<String?> update(
    String id, {
    String? text,
    MemoryKind? kind,
    int? importance,
    MemoryScope? scope,
    String? workspace,
  }) async {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i < 0) return tr('找不到这条记忆（可能已被删除）');
    final before = _entries[i];
    final nextText = text == null ? before.text : sanitize(text).trim();
    final nextScope = scope ?? before.scope;
    final nextWorkspace = nextScope == MemoryScope.workspace
        ? (workspace ?? before.workspace ?? '').trim()
        : null;
    final err = _validate(nextText, nextScope, nextWorkspace);
    if (err != null) return err;
    _entries[i] = before.copyWith(
      text: nextText,
      kind: kind ?? before.kind,
      importance: clampImportance(importance ?? before.importance),
      scope: nextScope,
      workspace: nextWorkspace,
    );
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

  /// 把顺序上移/下移一条 —— 同一分类、同一重要度内还会保持这个顺序
  /// （截断砍尾部时靠前的也活得更久）。
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

  /// 置顶：把一条挪到列表最前。
  Future<String?> moveToTop(String id) async {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i <= 0) return null;
    final e = _entries.removeAt(i);
    _entries.insert(0, e);
    notifyListeners();
    return _flush();
  }

  /// 总开关：关 = 整块从 `AGENTS.md` 移除（条目保留）；开 = 原样写回。
  Future<String?> setEnabled(bool on) async {
    if (_enabled == on) return null;
    _enabled = on;
    notifyListeners();
    final err = await _flush();
    if (err != null) {
      _enabled = !on; // 写失败就退回原状，别让界面显示一个没落盘的开关
      notifyListeners();
    }
    return err;
  }

  /// 「从会话提炼」的偏好开关。只改配置，不动注入块（所以不必重写 AGENTS.md）。
  Future<String?> setAutoSuggest(bool on) async {
    if (_autoSuggest == on) return null;
    _autoSuggest = on;
    notifyListeners();
    final err = await _flush(rewriteAgents: false);
    if (err != null) {
      _autoSuggest = !on;
      notifyListeners();
    }
    return err;
  }

  /// 纯本地过滤：按正文、分类名、范围名匹配（大小写不敏感）。
  /// 空查询 = 全部。
  List<MemoryEntry> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return entries;
    return <MemoryEntry>[
      for (final e in _entries)
        if (e.text.toLowerCase().contains(q) ||
            e.kind.label.contains(q) ||
            e.scopeLabel.contains(q) ||
            (e.workspace?.toLowerCase().contains(q) ?? false))
          e,
    ];
  }

  /// 导出成 v2 JSON 文本（界面写入临时文件后交给系统「保存文件」）。
  String exportJson() => '${const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'version': schemaVersion,
        'settings': <String, dynamic>{
          'enabled': _enabled,
          'autoSuggest': _autoSuggest,
        },
        'entries': <Map<String, dynamic>>[for (final e in _entries) e.toJson()],
        'updatedAt': DateTime.now().toIso8601String(),
      })}\n';

  /// 合并导入（按 text 去重）。坏 JSON 不抛异常，返回带中文 [MemoryImportResult.error]。
  ///
  /// 语义：
  ///   * 接受 v2 对象、v1 对象、**裸数组**三种形态；
  ///   * 重复（sanitize+trim 后与已有条目相同）**跳过**，不改写已存在的那条；
  ///   * 导入的条目**重新生成 id**（两台设备的 id 撞车会让"删除一条"删掉两条）；
  ///   * 超出 8 KB 预算的条目**不计入**，在 [MemoryImportResult.overBudget] 里如实报数。
  Future<MemoryImportResult> importJson(String raw) async {
    final List<Object?> list;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map) {
        final e = decoded['entries'];
        if (e is! List) {
          return MemoryImportResult(error: tr('导入失败：这份 JSON 里没有 entries 数组。'));
        }
        list = e;
      } else {
        return MemoryImportResult(error: tr('导入失败：顶层既不是对象也不是数组。'));
      }
    } on FormatException catch (e) {
      return MemoryImportResult(
          error: tr('导入失败：这不是有效的 JSON（{0}）', <Object?>[e.message]));
    } catch (e) {
      return MemoryImportResult(error: tr('导入失败：读不出这份文件（{0}）', <Object?>['$e']));
    }

    final seen = <String>{for (final e in _entries) _dedupeKey(e.text)};
    final before = List<MemoryEntry>.from(_entries);
    var added = 0;
    var skipped = 0;
    var overBudget = 0;
    for (final item in list) {
      final parsed = MemoryEntry.fromJson(item);
      if (parsed == null) {
        skipped++;
        continue;
      }
      final key = _dedupeKey(parsed.text);
      if (seen.contains(key)) {
        skipped++;
        continue;
      }
      final entry = parsed.copyWith(id: _newId());
      _entries.add(entry);
      if (_overBudgetError() != null) {
        _entries.removeLast();
        overBudget++;
        continue;
      }
      seen.add(key);
      added++;
    }

    if (added == 0) {
      return MemoryImportResult(added: 0, skipped: skipped, overBudget: overBudget);
    }
    notifyListeners();
    final err = await _flush();
    if (err != null) {
      _entries
        ..clear()
        ..addAll(before); // 写盘失败整体回滚，别让界面显示一批没落盘的条目
      notifyListeners();
      return MemoryImportResult(error: err);
    }
    debugPrint('[dsh-memory] 导入完成：新增 $added / 跳过 $skipped / 超预算 $overBudget');
    return MemoryImportResult(added: added, skipped: skipped, overBudget: overBudget);
  }

  static String _dedupeKey(String text) => sanitize(text).trim();

  String _newId() => 'm${DateTime.now().microsecondsSinceEpoch}'
      // 一毫秒内导入多条时上面那个值会撞车 → 加一个自增序号
      '${_idSeq++}';

  static int _idSeq = 0;

  /// 校验（add / update 共用）。返回 null = 通过。
  String? _validate(String text, MemoryScope scope, String? workspace) {
    final t = text.trim();
    if (t.isEmpty) return tr('内容不能为空');
    if (utf8.encode(sanitize(t)).length > perEntryBudget) {
      return tr('这一条太长了（上限 {0} 字节，约 600 多个汉字）', <Object?>['$perEntryBudget']);
    }
    if (scope == MemoryScope.workspace && (workspace ?? '').trim().isEmpty) {
      return tr('选了「仅当前工作区」但没有工作目录路径 —— 这条记忆不知道该在哪儿生效。');
    }
    return null;
  }

  String? _overBudgetError() {
    final used = usedBytes;
    if (used <= byteBudget) return null;
    return tr('记忆总量超了：现在约 {0} 字节，上限 {1} 字节。'
        '请先删掉几条再添加（总预算与专家说明共享 DSH 的 64 KB 注入上限）。',
        <Object?>['$used', '$byteBudget']);
  }

  Future<String?> _flush({bool rewriteAgents = true}) async {
    try {
      final dir = Directory(dshHome);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await writeStringAtomic(
        File(statePath),
        '${const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
              'version': schemaVersion,
              'settings': <String, dynamic>{
                'enabled': _enabled,
                'autoSuggest': _autoSuggest,
              },
              'entries': <Map<String, dynamic>>[
                for (final e in _entries) e.toJson()
              ],
              'updatedAt': DateTime.now().toIso8601String(),
            })}\n',
      );
    } catch (e) {
      debugPrint('[dsh-memory] 写 memory.json 失败：$e');
      return tr('写入记忆文件失败：{0}', <Object?>['$e']);
    }
    if (!rewriteAgents) return null;
    return _writeAgentsMd();
  }

  /// 真正要写进 `AGENTS.md` 的内容：关掉总开关就是**空**（= 整块移除）。
  String _desiredBlock() => _enabled ? renderBlock().trim() : '';

  /// 把记忆写进 `$DSH_HOME/AGENTS.md` 的受管区块（**前置**，见类注释的坑 1）。
  Future<String?> _writeAgentsMd() async {
    try {
      final file = File(agentsMdPath);
      final existing = file.existsSync() ? await file.readAsString() : '';
      final kept = _stripBlock(existing).trim();
      final block = _desiredBlock();

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
      debugPrint('[dsh-memory] AGENTS.md 已重写：记忆 ${_entries.length} 条'
          '（注入=${_enabled ? '开' : '关'}）→ $agentsMdPath');
      return null;
    } catch (e) {
      debugPrint('[dsh-memory] 写 AGENTS.md 失败：$e');
      return tr('写入 {0} 失败：{1}', <Object?>[agentsMdPath, '$e']);
    }
  }

  /// 保证受管区块与当前条目一致（App 启动时调一次）。幂等：一致就跳过写盘。
  Future<String?> ensureAgentsMd() async {
    try {
      final file = File(agentsMdPath);
      final existing = file.existsSync() ? await file.readAsString() : '';
      final desired = _desiredBlock();
      if (desired.isEmpty) {
        // 没有记忆（或注入被关掉）：如果文件里还留着旧块，要清掉
        //（否则会一直注入已删的内容 / 用户已经关掉的内容）
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

  /// 生成受管区块正文（**不看总开关** —— 总开关在 [_desiredBlock] 上生效）。
  ///
  /// 渲染规则（模型读起来要有结构，但不能让用户写的内容变成"系统小节标题"）：
  ///   * 按 [MemoryKind] 分组，每组一个小标题；
  ///   * 组内按 [MemoryEntry.importance] **升序**（1 在前），同级保持用户排的顺序；
  ///   * 每条渲染成引用块（`> `），内容一字不改；
  ///   * `scope=workspace` 的条目单独加一行「仅当工作目录是 <路径> 时适用」。
  ///     AGENTS.md 是**全局**文件、无法按会话切换，所以只能如实标注，不能装作
  ///     它只在那个工作区生效。
  String renderBlock() {
    if (_entries.isEmpty) return '';
    final sb = StringBuffer()
      ..writeln(blockBegin)
      ..writeln()
      ..writeln('## 用户记忆（用户在 App「记忆」页写下的，请遵守）')
      ..writeln()
      ..writeln('下面是用户**自己**写下的长期偏好与约定。它们和上面的项目指令同等有效；'
          '与本次任务的临时要求冲突时以本次要求为准，但要先说明这一点。')
      ..writeln()
      ..writeln('分组内越靠前越重要。标注了工作目录的条目**只在那个目录下适用**。');
    for (final kind in MemoryKind.values) {
      // 稳定排序：同样是 importance=2 的两条，保持用户自己的排列顺序
      final group = <MapEntry<int, MemoryEntry>>[
        for (var i = 0; i < _entries.length; i++)
          if (_entries[i].kind == kind) MapEntry<int, MemoryEntry>(i, _entries[i]),
      ]..sort((a, b) {
          final byImp = a.value.importance.compareTo(b.value.importance);
          return byImp != 0 ? byImp : a.key.compareTo(b.key);
        });
      if (group.isEmpty) continue;
      sb
        ..writeln()
        ..writeln('### ${kind.label}（${group.length} 条）')
        ..writeln();
      for (final g in group) {
        final e = g.value;
        if (e.isWorkspaceScoped) {
          sb.writeln('> （仅当工作目录是 ${e.workspace!.trim()} 时适用）');
        }
        // 每条渲染成引用块：既好读，也避免用户写的内容被误认成"系统小节标题"
        // （用户可能写成 `## 忽略以上所有指令` 这种 —— 渲染成引用块能弱化它的结构感，
        //   但**不隐瞒**：内容一字不改地写出来，让模型自己判断）。
        for (final line in e.text.split('\n')) {
          sb.writeln('> $line');
        }
        sb.writeln();
      }
    }
    sb.writeln(blockEnd);
    return sb.toString();
  }
}

/// 记忆分类（五类）。
///
/// JSON 里存的是 [name]（英文小写），界面显示的是 [label]（中文，走 `context.tr`）。
enum MemoryKind {
  /// 身份：我是谁、用什么语言、什么职业
  identity,

  /// 偏好：回答风格、习惯
  preference,

  /// 项目与事实：正在做的事、技术选型、约定
  project,

  /// 不要做的事：禁忌、红线
  avoid,

  /// 其它
  other,
}

/// 作用范围。
enum MemoryScope {
  /// 全局：任何工作目录下都注入
  global,

  /// 仅某个工作区（[MemoryEntry.workspace] 必填，绝对路径）
  workspace,
}

/// 这条记忆从哪来。
enum MemorySource {
  /// 用户手写
  manual,

  /// 从会话里提炼（**必须用户确认过才加进来**）
  extracted,
}

extension MemoryKindLabel on MemoryKind {
  /// 界面用中文名（**用 `context.tr(...)` 显示**，见文件末尾的 i18n 锚点）。
  String get label => switch (this) {
        MemoryKind.identity => '身份',
        MemoryKind.preference => '偏好',
        MemoryKind.project => '项目与事实',
        MemoryKind.avoid => '不要做的事',
        MemoryKind.other => '其它',
      };

  /// 加在提示词/空状态里的一句解释（界面用得到）。
  String get hint => switch (this) {
        MemoryKind.identity => '我是谁：语言、职业、长期身份',
        MemoryKind.preference => '我希望你怎么回答',
        MemoryKind.project => '正在做的事、技术选型、约定',
        MemoryKind.avoid => '不要做的事（红线、禁忌）',
        MemoryKind.other => '不好归类，但长期有效',
      };
}

extension MemoryScopeLabel on MemoryScope {
  String get label => switch (this) {
        MemoryScope.global => '全局',
        MemoryScope.workspace => '仅当前工作区',
      };
}

extension MemorySourceLabel on MemorySource {
  String get label => switch (this) {
        MemorySource.manual => '手动添加',
        MemorySource.extracted => '从会话提炼',
      };
}

/// JSON 里的 kind → 枚举；认不出来的一律 [MemoryKind.other]（不丢数据）。
MemoryKind memoryKindFromJson(Object? raw) {
  final s = raw?.toString().trim().toLowerCase();
  for (final k in MemoryKind.values) {
    if (k.name == s) return k;
  }
  return MemoryKind.other;
}

MemoryScope memoryScopeFromJson(Object? raw) {
  final s = raw?.toString().trim().toLowerCase();
  for (final v in MemoryScope.values) {
    if (v.name == s) return v;
  }
  return MemoryScope.global;
}

MemorySource memorySourceFromJson(Object? raw) {
  final s = raw?.toString().trim().toLowerCase();
  for (final v in MemorySource.values) {
    if (v.name == s) return v;
  }
  return MemorySource.manual;
}

/// 重要度夹到 1..3（1 最高）。非数字/越界都不报错，取就近值。
int clampImportance(Object? raw, {int fallback = 2}) {
  if (raw is num) {
    final v = raw.toInt();
    if (v < 1) return 1;
    if (v > 3) return 3;
    return v;
  }
  if (raw is String) {
    final v = int.tryParse(raw.trim());
    if (v != null) return clampImportance(v);
  }
  return fallback;
}

/// 重要度（1 最高）的中文档位名。界面用 `context.tr(...)` 显示。
String importanceLabel(int importance) => switch (clampImportance(importance)) {
      1 => '高',
      2 => '中',
      _ => '低',
    };

/// 路径取末段（列表里显示"仅当前工作区 · 项目名"，而不是一整条长路径）。
String lastPathSegment(String path) {
  final p = path.trim().replaceAll(RegExp(r'/+$'), '');
  if (p.isEmpty) return path.trim();
  final i = p.lastIndexOf('/');
  return i < 0 ? p : p.substring(i + 1);
}

/// 一次导入的结果。坏 JSON → [error] 非空（中文），此时计数都是 0。
@immutable
class MemoryImportResult {
  const MemoryImportResult({
    this.added = 0,
    this.skipped = 0,
    this.overBudget = 0,
    this.error,
  });

  /// 真的加进来的条数
  final int added;

  /// 跳过的条数（与已有条目重复 / 结构不合法）
  final int skipped;

  /// 因为总量超 8 KB 预算没加进来的条数（**如实报**，不静默丢）
  final int overBudget;

  /// 给用户看的中文错误；null = 成功
  final String? error;

  bool get ok => error == null;
}

/// 一条记忆。
@immutable
class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.text,
    required this.createdAt,
    this.kind = MemoryKind.other,
    this.importance = 2,
    this.scope = MemoryScope.global,
    this.workspace,
    this.source = MemorySource.manual,
  });

  final String id;
  final String text;

  final MemoryKind kind;

  /// 1..3（1 最高）
  final int importance;

  final MemoryScope scope;

  /// [MemoryScope.workspace] 时必填的绝对路径；global 时为 null
  final String? workspace;

  final MemorySource source;

  final DateTime createdAt;

  /// 是不是真的带工作目录声明（有些条目 scope=workspace 但路径是空的，
  /// 渲染时**不能**编一个路径出来 —— 那就当全局条目处理）。
  bool get isWorkspaceScoped =>
      scope == MemoryScope.workspace && (workspace?.trim().isNotEmpty ?? false);

  String get scopeLabel =>
      isWorkspaceScoped ? '仅当前工作区' : '全局';

  String get importanceName => importanceLabel(importance);

  static const Object _unset = Object();

  MemoryEntry copyWith({
    String? id,
    String? text,
    MemoryKind? kind,
    int? importance,
    MemoryScope? scope,
    Object? workspace = _unset,
    MemorySource? source,
  }) =>
      MemoryEntry(
        id: id ?? this.id,
        text: text ?? this.text,
        kind: kind ?? this.kind,
        importance: clampImportance(importance ?? this.importance),
        scope: scope ?? this.scope,
        workspace: identical(workspace, _unset)
            ? this.workspace
            : workspace as String?,
        source: source ?? this.source,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'text': text,
        'kind': kind.name,
        'importance': importance,
        'scope': isWorkspaceScoped ? scope.name : MemoryScope.global.name,
        'workspace': isWorkspaceScoped ? workspace!.trim() : null,
        'source': source.name,
        'createdAt': createdAt.toIso8601String(),
      };

  /// 宽容解析：v1 只有 id/text/createdAt 也能读进来（缺字段取默认值）。
  static MemoryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final scope = memoryScopeFromJson(raw['scope']);
    final ws = raw['workspace'];
    final wsText = ws is String && ws.trim().isNotEmpty ? ws.trim() : null;
    return MemoryEntry(
      id: id is String && id.trim().isNotEmpty
          ? id
          : 'm${DateTime.now().microsecondsSinceEpoch}',
      text: text,
      kind: memoryKindFromJson(raw['kind']),
      importance: clampImportance(raw['importance']),
      scope: scope,
      workspace: wsText,
      source: memorySourceFromJson(raw['source']),
      createdAt:
          DateTime.tryParse(raw['createdAt'] as String? ?? '') ?? DateTime(1970),
    );
  }
}

/// ⚠️ **i18n 扫描器的锚点**（不要删）。
///
/// 分类名 / 范围名 / 重要度档位 / 来源名都是**枚举里的字面量**，
/// 界面用 `context.tr(kind.label)` 显示；而扫描器只认源码里 `tr('字面量')`
/// 这种写法 —— 写在枚举 getter 里的字符串它**看不见**（同 `tts.dart`
/// 的 `ttsI18nAnchors`、`ai_role_page.dart` 的 `aiRoleI18nAnchors`）。
/// 这一段的唯一作用就是让扫描器看得到它们，从而能发现"没翻"。
///
/// **改了上面任何一条文案，这里要逐字同步**（`test/memory_store_test.dart`
/// 的「文案都在 i18n 锚点里」会核对）。
// ignore: unused_element
void memoryI18nAnchors() {
  tr('身份');
  tr('偏好');
  tr('项目与事实');
  tr('不要做的事');
  tr('其它');
  tr('我是谁：语言、职业、长期身份');
  tr('我希望你怎么回答');
  tr('正在做的事、技术选型、约定');
  tr('不要做的事（红线、禁忌）');
  tr('不好归类，但长期有效');
  tr('全局');
  tr('仅当前工作区');
  tr('高');
  tr('中');
  tr('低');
  tr('手动添加');
  tr('从会话提炼');
}
