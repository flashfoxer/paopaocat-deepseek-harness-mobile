import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../i18n/dsh_i18n.dart';
import 'atomic_file.dart';
import 'relative_time.dart';

/// 一个工作区 == DSH 运行时的一次 cwd（**真实的目录**）。
///
/// 为什么工作区必须是真实目录而不是界面上的一个标签：DSH 的会话是**按 cwd 持久化**的
/// （`$DSH_HOME/sessions/<cwd 编码>/<sessionId>/session.v4.jsonl.zstd`），
/// 而且 ACP 的 `session/resume` 会校验 cwd 与持久化的 cwd 一致才会恢复。
/// 所以"切工作区"在协议层就等于"换一个 cwd"，界面不能拿假目录糊弄。
class DshWorkspace {
  DshWorkspace({
    required this.name,
    required this.path,
    this.isDefault = false,
    this.createdAt = 0,
  });

  /// 展示名（用户输入的名字，或从路径末段推导）
  final String name;

  /// 绝对路径（= DSH 的 cwd）
  final String path;

  /// 随 App 自带的默认工作区（不可删除）
  final bool isDefault;

  /// 创建时间（毫秒时间戳；0 表示未知，不做排序承诺）
  final int createdAt;

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'isDefault': isDefault,
        'createdAt': createdAt,
      };

  static DshWorkspace? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'] as String?;
    if (path == null || path.isEmpty) return null;
    return DshWorkspace(
      name: (raw['name'] as String?)?.trim().isNotEmpty == true
          ? (raw['name'] as String).trim()
          : _lastSegment(path),
      path: path,
      isDefault: raw['isDefault'] == true,
      createdAt: raw['createdAt'] as int? ?? 0,
    );
  }

  static String _lastSegment(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }
}

/// 一条会话（一次 DSH 对话）。
///
/// 两个来源，界面上**都要能看出来是哪一种**，不允许把磁盘索引当成"我刚聊过"：
///   * `live`：本次运行期间用户真的发过消息（有真实标题 = 用户第一句话）；
///   * 磁盘索引：ACP `session/list` 列出的历史会话（DSH 不给标题，只有 sessionId）。
class DshSession {
  DshSession({
    required this.id,
    required this.cwd,
    this.title,
    this.live = false,
    this.createdAt,
    this.emptyShell = false,
  });

  /// 真实的 ACP sessionId（`session/resume` 就吃这个）
  final String id;
  final String cwd;

  /// 这条会话在磁盘上被**创建**的时间。
  ///
  /// 来源：ACP `session/list` 的 `createdAt` 字段 —— 它本来就返回
  /// （DSH 源码 `dsh-acp/lib/index.js` 还按它倒序排），是我们之前解析时丢掉了。
  ///
  /// 为什么现在要显示它：用户看到工作区里一堆历史会话，第一反应就是
  /// 「这是什么时候的事」。取不到时为 null，界面**如实不显示**时间，不编。
  final DateTime? createdAt;

  /// 真实标题：只有 `live` 会话才有（取自用户第一条消息，不编造）
  String? title;

  /// 本次运行期间真的对话过
  bool live;

  /// 这条磁盘会话是**0 消息空壳**（打开过、一句没发；见 `local/session_projcache.dart`）。
  ///
  /// 谁标的：`listPersistedSessions`（读投影缓存 + 转录大小），**只标不删** ——
  /// 磁盘上的目录、转录文件一个字节都不动，只是列表里不列出来。
  ///
  /// 为什么必须标出来：设备实测 48 条会话里 17 条是空壳（最老的 4 条转录只有
  /// 175 B，连一条消息都没有），它们把真会话淹了，用户以为"对话被删了"。
  bool emptyShell;

  bool get hasTitle => title != null && title!.trim().isNotEmpty;

  /// 列表里显示的标题。没有真实标题就**如实**显示会话号，不编一个假标题。
  String get label => hasTitle ? title! : tr('会话 {0}', [shortId]);

  String get shortId => id.length <= 8 ? id : id.substring(0, 8);

  /// 「刚刚 / 12 分钟前 / 3 小时前 / 2 天前 / 2026-09-28 14:02」。
  /// 取不到时间返回空串（界面就不显示这一行）。
  ///
  /// ⚠️ 格式化逻辑**只有一份**，在 `data/relative_time.dart` 里：会话列表页
  /// （`ui/sessions_page.dart`）也用同一个函数。以前这里是唯一实现，而会话列表
  /// 根本没显示时间 —— 用户反馈"会话的历史纪录，显示不出会话的时间"就是这么来的。
  String get createdLabel => relativeTimeLabel(createdAt);

  /// 可恢复：有真实 sessionId 就能让 ACP `session/resume` 试一次
  /// （DSH 侧条件：会话已持久化、当前不活跃、cwd 与持久化的一致）。
  bool get resumable => id.isNotEmpty;
}

/// 工作区 + 会话的本机登记表。
///
/// 落盘位置：`$filesDir/workspaces.json`（App 私有目录，不动用户可见存储）。
/// **只登记工作区**；会话不落盘 —— 磁盘上的会话是 DSH 自己在
/// `$DSH_HOME/sessions/` 里管的，界面通过 ACP `session/list` 读（见 session_index.dart），
/// 这里再存一份只会制造第二个真相。
class WorkspaceStore extends ChangeNotifier {
  WorkspaceStore(this.filesDir);

  final String filesDir;

  static const String _fileName = 'workspaces.json';

  final List<DshWorkspace> _workspaces = [];
  final List<DshSession> _live = [];

  /// 磁盘索引（ACP session/list 的结果）：历史会话
  List<DshSession> _disk = const [];
  bool _indexLoading = false;
  String? _indexError;
  bool _indexLoaded = false;

  String? _currentPath;
  bool _loaded = false;

  bool get loaded => _loaded;
  bool get indexLoading => _indexLoading;
  String? get indexError => _indexError;
  bool get indexLoaded => _indexLoaded;

  String get _defaultPath => '$filesDir/workspace';
  String get _workspacesRoot => '$filesDir/workspaces';
  String get _filePath => '$filesDir/$_fileName';

  /// 当前工作区（永远可求值：登记表还没载入时返回默认工作区，不写盘）。
  DshWorkspace get current {
    final all = allWorkspaces;
    for (final w in all) {
      if (w.path == _currentPath) return w;
    }
    if (all.isNotEmpty) return all.first;
    return DshWorkspace(
      name: tr('默认工作区'),
      path: _defaultPath,
      isDefault: true,
    );
  }

  /// 用户建的工作区 + 从磁盘会话里发现的工作区（真实存在的 cwd）。
  List<DshWorkspace> get allWorkspaces {
    final list = <DshWorkspace>[..._workspaces];
    final known = list.map((w) => w.path).toSet();
    for (final s in _disk) {
      if (s.cwd.isEmpty || known.contains(s.cwd)) continue;
      known.add(s.cwd);
      list.add(DshWorkspace(
        name: DshWorkspace._lastSegment(s.cwd),
        path: s.cwd,
      ));
    }
    return list;
  }

  /// 用户显式建过的工作区（不含"从会话里发现"的）
  List<DshWorkspace> get userWorkspaces => List.unmodifiable(_workspaces);

  /// 用户给会话起的显示名（会话 id → 名字）。见 [renameSession]。
  final Map<String, String> _sessionTitles = {};

  /// 某个会话的自定义显示名；没改过返回 null。
  String? customTitleOf(String id) => _sessionTitles[id];

  /// 给会话改个显示名（用户意见⑥）。
  ///
  /// 两点如实说明，不制造「改了 DSH 里也跟着变」的错觉：
  ///   * ACP 协议**没有** rename，DSH 自己的会话文件不会因此改变 ——
  ///     这个名字只是**本 App 的显示名**，存在工作区登记表里，重装即丢；
  ///   * 传空串表示**清除**自定义名，回到「首条消息 / 会话号」的默认显示。
  Future<void> renameSession(String id, String rawTitle) async {
    if (id.isEmpty) return;
    final title = rawTitle.trim();
    if (title.isEmpty) {
      _sessionTitles.remove(id);
    } else {
      _sessionTitles[id] = title;
    }
    for (final s in _live) {
      if (s.id == id) s.title = title.isEmpty ? null : title;
    }
    debugPrint(
      '[dsh-ws] 重命名会话 ${id.length > 8 ? id.substring(0, 8) : id}'
      ' → ${title.isEmpty ? '(清除自定义名)' : title}',
    );
    notifyListeners();
    await _save();
  }

  /// 应用自定义显示名。**返回副本**，不改原对象 —— 免得污染磁盘索引那份真实数据。
  DshSession _withCustomTitle(DshSession s) {
    final custom = _sessionTitles[s.id];
    if (custom == null || custom.isEmpty) return s;
    return DshSession(
      id: s.id,
      cwd: s.cwd,
      title: custom,
      live: s.live,
      createdAt: s.createdAt,
      emptyShell: s.emptyShell,
    );
  }

  /// 某个工作区下的会话：本次运行的真实会话在前，磁盘索引的历史会话随后。
  ///
  /// 同一个 sessionId 只出现一次（live 覆盖 disk —— live 那份有真实标题）。
  /// **0 消息空壳不列**（[DshSession.emptyShell]）：磁盘上还在，只是不显示 ——
  /// 列表里每一条点开都该有内容（缺陷 A 的验收标准）。
  List<DshSession> sessionsOf(String path) {
    final out = <DshSession>[];
    final seen = <String>{};
    for (final s in _live) {
      if (s.cwd != path) continue;
      if (s.emptyShell) continue;
      if (seen.add(s.id)) out.add(_withCustomTitle(s));
    }
    for (final s in _disk) {
      if (s.cwd != path) continue;
      if (s.emptyShell) continue;
      if (seen.add(s.id)) out.add(_withCustomTitle(s));
    }
    return out;
  }

  int get totalLiveSessions => _live.length;

  /// 磁盘上查到多少条会话（**含**空壳 —— 这个数字是"磁盘上有几条"，不是"列表显示几条"）
  int get totalDiskSessions => _disk.length;

  /// 其中被判为 0 消息空壳、因此**没列出来**的条数。
  ///
  /// 界面要如实说出这个差值，否则用户看到"磁盘 48 条"却只数出 31 条，会以为仍在丢。
  int get hiddenEmptySessions => _disk.where((s) => s.emptyShell).length;

  // ------------------------------------------------------------------ 载入 / 落盘

  Future<void> load() async {
    try {
      final f = File(_filePath);
      if (f.existsSync()) {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is Map) {
          final list = raw['workspaces'];
          if (list is List) {
            for (final item in list) {
              final w = DshWorkspace.fromJson(item);
              if (w != null) _workspaces.add(w);
            }
          }
          final cur = raw['current'];
          if (cur is String && cur.isNotEmpty) _currentPath = cur;
          // 会话显示名（意见⑥）
          final titles = raw['sessionTitles'];
          if (titles is Map) {
            for (final e in titles.entries) {
              final k = e.key;
              final v = e.value;
              if (k is String &&
                  k.isNotEmpty &&
                  v is String &&
                  v.trim().isNotEmpty) {
                _sessionTitles[k] = v.trim();
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[dsh-ws] 读取工作区登记表失败（将重建）：$e');
      _workspaces.clear();
    }

    // 默认工作区永远存在（老用户升级上来时补一条）
    if (!_workspaces.any((w) => w.isDefault)) {
      _workspaces.insert(
        0,
        DshWorkspace(
          name: tr('默认工作区'),
          path: _defaultPath,
          isDefault: true,
          createdAt: 0,
        ),
      );
    }
    for (final w in _workspaces) {
      _ensureDir(w.path);
    }
    if (_currentPath == null ||
        !_workspaces.any((w) => w.path == _currentPath)) {
      _currentPath = _workspaces.first.path;
    }
    _loaded = true;
    debugPrint(
        '[dsh-ws] 载入 ${_workspaces.length} 个工作区，当前=${current.name}（${current.path}）');
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final payload = {
        'version': 1,
        'current': _currentPath,
        'workspaces': _workspaces.map((w) => w.toJson()).toList(),
        // 会话的显示名（意见⑥）。与工作区登记表同文件落盘，重装即丢。
        'sessionTitles': _sessionTitles,
      };
      writeStringAtomicSync(
          File(_filePath), const JsonEncoder.withIndent('  ').convert(payload));
    } catch (e) {
      debugPrint('[dsh-ws] 保存工作区登记表失败：$e');
    }
  }

  void _ensureDir(String path) {
    try {
      final d = Directory(path);
      if (!d.existsSync()) d.createSync(recursive: true);
    } catch (e) {
      debugPrint('[dsh-ws] 建目录失败 $path：$e');
    }
  }

  // ------------------------------------------------------------------ 操作

  /// 新建工作区：在 App 私有目录下**真的建目录**，然后加入列表。
  ///
  /// 返回新建的工作区；名字为空或建目录失败时返回 null（调用方如实提示）。
  Future<DshWorkspace?> createWorkspace(String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty) return null;

    // 目录名：能安全落盘就用名字本身，否则退化成 ws-<时间戳>。
    // （展示名一律用用户输入的原名，路径里不放不可控字符，避免 shell/工具踩坑。）
    final ts = DateTime.now().millisecondsSinceEpoch;
    var dirName = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    if (dirName.isEmpty) dirName = 'ws-$ts';
    var path = '$_workspacesRoot/$dirName';
    var n = 2;
    while (Directory(path).existsSync() &&
        allWorkspaces.any((w) => w.path == path)) {
      path = '$_workspacesRoot/$dirName-$n';
      n++;
    }

    final created = DshWorkspace(
      name: name,
      path: path,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      Directory(path).createSync(recursive: true);
      // 给这个工作区留一个可读的"门牌"：模型和人都能用它确认自己站在哪个 cwd。
      // 不是假数据 —— 它就是本 App 自己写的登记信息。
      File('$path/WORKSPACE-INFO.txt').writeAsStringSync(
        tr('workspace: {0}\ncreated: {1}\ncreatedBy: 泡泡猫的DSH (Android)\n',
            [name, DateTime.now().toIso8601String()]),
      );
    } catch (e) {
      debugPrint('[dsh-ws] 新建工作区失败 $path：$e');
      return null;
    }

    _workspaces.add(created);
    _currentPath = created.path;
    notifyListeners();
    await _save();
    debugPrint('[dsh-ws] 新建工作区 ${created.name} -> ${created.path}');
    return created;
  }

  /// 切到某个工作区（= 下一次开对话时用的 cwd）。
  Future<void> selectWorkspace(DshWorkspace w) async {
    if (_currentPath == w.path) return;
    _currentPath = w.path;
    _ensureDir(w.path);
    debugPrint('[dsh-ws] 切换工作区 -> ${w.name}（${w.path}）');
    notifyListeners();
    await _save();
  }

  /// 登记一条**本次运行真实发生过**的会话（由对话页在发出第一条消息时回调）。
  void noteSession(
      {required String id, required String cwd, required String title}) {
    final trimmed = title.trim();
    if (id.isEmpty || trimmed.isEmpty) return;
    // 用户改过名 → 用它，不被新的自动标题覆盖（意见⑥）。
    final custom = _sessionTitles[id];
    final effective = (custom != null && custom.isNotEmpty) ? custom : trimmed;
    for (final s in _live) {
      if (s.id == id) {
        if (!s.hasTitle) s.title = effective;
        return;
      }
    }
    _live.insert(0, DshSession(id: id, cwd: cwd, title: effective, live: true));
    debugPrint(
        '[dsh-ws] 登记会话 ${id.substring(0, 8)}（${cwd.split('/').last}）共 ${_live.length} 条');
    notifyListeners();
  }

  /// 用 ACP `session/list` 刷新磁盘上的历史会话索引。
  ///
  /// [loader] 由外层注入（它需要 DshRuntime，属于运行时层的事；
  /// 这里只负责状态与去重）。
  Future<void> refreshIndex(Future<List<DshSession>> Function() loader) async {
    if (_indexLoading) return;
    _indexLoading = true;
    _indexError = null;
    notifyListeners();
    try {
      final list = await loader();
      _disk = list;
      _indexLoaded = true;
      debugPrint('[dsh-ws] 磁盘会话索引：${list.length} 条');
    } catch (e) {
      _indexError = '$e';
      debugPrint('[dsh-ws] 磁盘会话索引失败：$e');
    } finally {
      _indexLoading = false;
      notifyListeners();
    }
  }
}
