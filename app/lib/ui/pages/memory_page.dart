import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/api_error_text.dart';
import '../../data/memory_extract.dart';
import '../../data/memory_store.dart';
import '../../data/workspace_store.dart';
import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../../local/session_index.dart';
import '../../local/session_transcript.dart';
import '../theme/dsh_tokens.dart';
import '../widgets/common.dart';

/// 「记忆」页：管理**跨会话长期生效**的信息 —— 用户手写的，以及从真实会话里
/// 由模型提炼、经用户逐条确认后加进来的。
///
/// ## 这一页要把三件事讲清楚（否则用户会以为没生效）
///
/// 1. **写到哪**：`$DSH_HOME/AGENTS.md` 里的一段受管区块 —— DSH 内置插件
///    `dsh-agent-instructions` 会在**每个新会话的第一个请求之前**把它注入模型上下文
///    （与「专家」开关走同一条通道）。页面上把真实路径显示出来，可核对。
/// 2. **什么时候生效**：`AGENTS.md` 是**会话开始时**读的，所以对**已经打开的会话
///    不生效** —— 要新建一个会话。
/// 3. **有上限**：整个用户全局指令（含专家说明与"本机执行环境"那段）共享 DSH 的
///    64 KB 注入预算，超出是**截断尾部**。所以记忆自己限 8 KB，且**放在文件靠前**，
///    免得被截掉的是用户自己写的话。
///
/// ## 三条"不许含糊"的产品约束（都在这一页体现）
///
///   * **数字必须来自真实数据**：预算条读的是 `MemoryStore.usedBytes`，
///     条数是 `MemoryStore.count`，时间来自项目的相对时间格式化函数 ——
///     页面上不出现"可能/大约"这种含糊说法。
///   * **提炼结果不自动写盘**：模型写的东西可能记偏，进了 `AGENTS.md` 就是
///     每个新会话都注入的全局指令。所以必须先给用户看候选、勾选，才写进去。
///   * **失败要如实说**：提炼超时 / 通道没起来 / 输出不是 JSON，是**三种不同的
///     失败**，分别给中文原因，并且都留一条"也可以自己手写一条"的退路。
class MemoryPage extends StatefulWidget {
  const MemoryPage({
    super.key,
    required this.dshHome,
    required this.workspacePath,
    required this.runtime,
    this.workspaceLabel,
  });

  /// 设备的 `DSH_HOME`（Android 上 = `<filesDir>/dshhome`）。
  final String dshHome;

  /// 当前工作目录的绝对路径（写「仅当前工作区」记忆时用它）。
  final String workspacePath;

  /// 设备上的 DSH 运行时（提炼那条链路要起一次 headless 进程）。
  final DshRuntime runtime;

  /// 当前工作区的显示名（可空：取不到就直接显示路径末段）。
  final String? workspaceLabel;

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

/// 提炼的超时。150 秒：一次真实模型调用在手机上（含冷启动 node）够用，
/// 又不至于失败时让用户干等。
const Duration _kExtractTimeout = Duration(seconds: 150);

class _MemoryPageState extends State<MemoryPage> {
  late final MemoryStore _store = MemoryStore(dshHome: widget.dshHome);
  final TextEditingController _input = TextEditingController();
  final TextEditingController _search = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  bool _loading = true;

  // ---- 添加表单的状态
  MemoryKind _kind = MemoryKind.preference;
  int _importance = 2;
  MemoryScope _scope = MemoryScope.global;

  String _query = '';

  // ---- 提炼
  bool _extracting = false;
  String _extractStage = '';
  Completer<void>? _extractCancel;
  bool _cancelledByUser = false;

  // ---- 导入 / 导出
  bool _ioBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _search.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _store.load();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 所有写操作的统一出口：把 store 返回的中文错误如实弹出来。
  Future<void> _act(Future<String?> Function() op, String okMsg) async {
    final err = await op();
    if (!mounted) return;
    setState(() {});
    _toast(err ?? okMsg);
  }

  String get _workspacePath => widget.workspacePath.trim();

  bool get _canScopeWorkspace => _workspacePath.isNotEmpty;

  MemoryScope get _effectiveScope =>
      _canScopeWorkspace ? _scope : MemoryScope.global;

  // ------------------------------------------------------------------ 增删改

  Future<void> _add() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      _toast(context.tr('先写点内容再添加'));
      return;
    }
    final err = await _store.add(
      text,
      kind: _kind,
      importance: _importance,
      scope: _effectiveScope,
      workspace: _effectiveScope == MemoryScope.workspace ? _workspacePath : null,
    );
    if (!mounted) return;
    setState(() {});
    if (err != null) {
      // 失败时**不清空**输入框：用户写的东西不能因为一次超预算就丢掉
      _toast(err);
      return;
    }
    _input.clear();
    _toast(context.tr('已添加。新建会话后生效。'));
  }

  Future<void> _edit(MemoryEntry e) async {
    final draft = await showDialog<_MemoryDraft>(
      context: context,
      builder: (ctx) => _EditMemoryDialog(
        entry: e,
        workspacePath: _workspacePath,
        workspaceLabel: widget.workspaceLabel,
      ),
    );
    if (draft == null || !mounted) return;
    await _act(
      () => _store.update(
        e.id,
        text: draft.text,
        kind: draft.kind,
        importance: draft.importance,
        scope: draft.scope,
        workspace: draft.scope == MemoryScope.workspace ? _workspacePath : null,
      ),
      context.tr('已修改。新建会话后生效。'),
    );
  }

  Future<void> _delete(MemoryEntry e) async {
    final msgOk = context.tr('已删除。新建会话后生效。');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('删除这条记忆？')),
        content: Text(e.text),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _act(() => _store.remove(e.id), msgOk);
  }

  Future<void> _clearAll() async {
    final msgOk = context.tr('已清空。新建会话后生效。');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('清空全部记忆？')),
        content: Text(context.tr('这会删掉所有记忆条目，并从 AGENTS.md 里移除它们。不可恢复。')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('全部删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _act(() => _store.clearAll(), msgOk);
  }

  // ------------------------------------------------------------------ 提炼

  Future<void> _pickSession() async {
    final session = await showModalBottomSheet<DshSession>(
      context: context,
      isScrollControlled: true,
      backgroundColor: DshColors.bg,
      builder: (_) => _SessionPickerSheet(runtime: widget.runtime),
    );
    if (session == null || !mounted) return;
    await _runExtract(session);
  }

  Future<void> _runExtract(DshSession session) async {
    setState(() {
      _extracting = true;
      _cancelledByUser = false;
      _extractStage = context.tr('正在读取这条会话的历史…');
      _extractCancel = null;
    });

    SessionTranscript? transcript;
    try {
      transcript = await loadSessionTranscript(
        runtime: widget.runtime,
        sessionId: session.id,
      );
    } catch (e) {
      transcript = null;
      debugPrint('[dsh-memory] 读会话历史抛异常：$e');
    }
    if (!mounted) return;
    if (transcript == null) {
      setState(() {
        _extracting = false;
        _extractStage = '';
      });
      await _showExtractNotice(
        title: context.tr('读不到会话历史'),
        body: context.tr('这条会话的记录没读出来 —— 会话文件可能已经不在了。你可以换一条，'
            '或者自己手写一条。'),
      );
      return;
    }

    final cancel = Completer<void>();
    setState(() {
      _extractCancel = cancel;
      _extractStage = context.tr(
          '正在让模型提炼（最多等 {0} 秒，中途可以取消）…', <Object?>['${_kExtractTimeout.inSeconds}']);
    });

    // ⚠️ 异常先接住、**出了 async gap 再翻译**：在 catch 里直接 `context.tr`
    // 会踩 `use_build_context_synchronously`（而且那一刻页面可能已经被 pop 掉了）。
    MemoryExtraction? result;
    Object? thrown;
    try {
      result = await extractMemoryCandidates(
        runtime: widget.runtime,
        messages: transcript.messages,
        existingTexts: <String>[for (final e in _store.entries) e.text],
        timeout: _kExtractTimeout,
        cancel: cancel.future,
      );
    } catch (e) {
      thrown = e;
    }
    if (!mounted) return;
    setState(() {
      _extracting = false;
      _extractStage = '';
      _extractCancel = null;
    });

    if (_cancelledByUser) {
      _toast(context.tr('已取消 —— 没有写入任何记忆。'));
      return;
    }
    if (thrown != null) {
      await _showExtractNotice(
        title: context.tr('提炼失败'),
        body: context.tr('提炼没能跑起来：{0}', <Object?>['$thrown']),
      );
      return;
    }
    final outcome = result!;
    if (!outcome.ok) {
      await _showExtractNotice(
        title: context.tr('提炼失败'),
        body: outcome.failure!,
        detail: outcome.raw,
      );
      return;
    }
    if (outcome.items.isEmpty) {
      await _showExtractNotice(
        title: context.tr('没有提炼出内容'),
        body: context.tr('这次没有提炼出值得长期记住的内容 —— 这不代表失败，'
            '只是这段对话里没有跨会话有用的事实。你也可以自己手写一条。'),
      );
      return;
    }

    final chosen = await showModalBottomSheet<List<MemoryCandidate>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: DshColors.bg,
      builder: (_) => _CandidateSheet(items: outcome.items),
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;

    var added = 0;
    String? firstErr;
    for (final c in chosen) {
      final err = await _store.addFromCandidate(
        text: c.text,
        kind: c.kind,
        importance: c.importance,
      );
      if (err != null) {
        firstErr ??= err;
      } else {
        added++;
      }
    }
    if (!mounted) return;
    setState(() {});
    _toast(firstErr ??
        (added == 0
            ? context.tr('一条都没加进去。')
            : context.tr('已加入 {0} 条记忆。新建会话后生效。', <Object?>['$added'])));
  }

  void _cancelExtract() {
    final c = _extractCancel;
    if (c == null || c.isCompleted) return;
    _cancelledByUser = true;
    c.complete();
    setState(() => _extractStage = context.tr('正在取消（会终止这次模型调用）…'));
  }

  /// 失败/空结果的如实提示。**都留一条"自己手写一条"的退路**。
  Future<void> _showExtractNotice({
    required String title,
    required String body,
    String? detail,
  }) async {
    final write = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(body, style: TextStyle(color: DshColors.textDim, height: 1.5)),
              if (detail != null && detail.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  context.tr('原始信息（排查用）'),
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11),
                ),
                const SizedBox(height: 4),
                Text(
                  detail.trim().length > 400
                      ? '${detail.trim().substring(0, 400)}…'
                      : detail.trim(),
                  style: DshFonts.code(color: DshColors.textFaint, fontSize: 10.5),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.tr('知道了')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('自己手写一条')),
          ),
        ],
      ),
    );
    if (write != true || !mounted) return;
    // 退路：滚回顶部并把光标放进输入框
    if (_scroll.hasClients) {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
    _inputFocus.requestFocus();
  }

  // ------------------------------------------------------------------ 导入 / 导出

  String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
  }

  Future<void> _export() async {
    if (_ioBusy) return;
    setState(() => _ioBusy = true);
    try {
      final dir = Directory('${widget.dshHome}/exports');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final name = 'dsh-memory-${_stamp(DateTime.now())}.json';
      final f = File('${dir.path}/$name');
      await f.writeAsString(_store.exportJson());
      final r = await DshHost.exportTextFile(
        fileName: name,
        sourcePath: f.path,
        mime: 'application/json',
      );
      if (!mounted) return;
      if (r.startsWith('ok:')) {
        _toast(context.tr('已导出：{0}', <Object?>[name]));
      } else if (r == 'cancel') {
        _toast(context.tr(
            '你取消了导出 —— 文件已经生成，在 App 私有目录：{0}', <Object?>[f.path]));
      } else {
        _toast(context.tr('这台手机没有可用的「保存文件」界面（系统返回 {0}）。',
            <Object?>[r]));
      }
    } catch (e) {
      if (mounted) {
        _toast(context.tr('导出失败：{0}', <Object?>[translateException(e).zh]));
      }
    } finally {
      if (mounted) setState(() => _ioBusy = false);
    }
  }

  Future<void> _import() async {
    if (_ioBusy) return;
    String? path;
    try {
      path = await DshHost.pickAttachment('file');
    } catch (e) {
      if (mounted) {
        _toast(context.tr('选择文件失败：{0}', <Object?>[translateException(e).zh]));
      }
      return;
    }
    // 用户取消：不弹任何提示
    if (path == null || !mounted) return;
    if (!path.toLowerCase().endsWith('.json')) {
      _toast(context.tr('请选择记忆的 JSON 文件（.json）。'));
      return;
    }
    setState(() => _ioBusy = true);
    try {
      final raw = await File(path).readAsString();
      final r = await _store.importJson(raw);
      if (!mounted) return;
      setState(() {});
      if (!r.ok) {
        _toast(r.error!);
        return;
      }
      if (r.overBudget > 0) {
        _toast(context.tr(
            '导入完成：新增 {0} 条，跳过 {1} 条重复或不合法的条目；另有 {2} 条因为超出 {3} 字节预算没有导入。',
            <Object?>[
              '${r.added}',
              '${r.skipped}',
              '${r.overBudget}',
              '${MemoryStore.byteBudget}',
            ]));
        return;
      }
      _toast(context.tr('导入完成：新增 {0} 条，跳过 {1} 条重复或不合法的条目。',
          <Object?>['${r.added}', '${r.skipped}']));
    } catch (e) {
      if (mounted) {
        _toast(context.tr('读取文件失败：{0}', <Object?>[translateException(e).zh]));
      }
    } finally {
      if (mounted) setState(() => _ioBusy = false);
    }
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final shown = _store.search(_query);
    return Scaffold(
      backgroundColor: DshColors.bg,
      appBar: AppBar(
        title: Text(context.tr('记忆')),
        actions: <Widget>[
          if (_store.count > 0)
            IconButton(
              onPressed: _clearAll,
              tooltip: context.tr('清空全部'),
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(
                  DshMetrics.pagePad, 12, DshMetrics.pagePad, 24),
              children: <Widget>[
                _explainCard(),
                const SizedBox(height: 12),
                _addCard(),
                const SizedBox(height: 12),
                _searchRow(),
                const SizedBox(height: 8),
                if (_store.isEmpty)
                  DshRichText(
                    context.tr('还没有任何记忆。上面写一条，新建会话后模型就会看到它。'
                        '也可以往下翻，从最近一次会话里提炼。'),
                    style: TextStyle(
                        color: DshColors.textFaint, fontSize: 12, height: 1.5),
                  )
                else if (shown.isEmpty)
                  DshRichText(
                    context.tr('没有匹配「{0}」的记忆。', <Object?>[_query.trim()]),
                    style: TextStyle(
                        color: DshColors.textFaint, fontSize: 12, height: 1.5),
                  )
                else
                  for (final e in shown) ...<Widget>[
                    _entryCard(e),
                    const SizedBox(height: 8),
                  ],
                const SizedBox(height: 4),
                _extractCard(),
                const SizedBox(height: 12),
                _ioCard(),
              ],
            ),
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(DshMetrics.cardPad),
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
          border: Border.all(color: DshColors.divider, width: 0.8),
        ),
        child: child,
      );

  Widget _cardTitle(String text) => Text(
        text,
        style: TextStyle(
            color: DshColors.text, fontSize: 13, fontWeight: FontWeight.w600),
      );

  Widget _explainCard() {
    final used = _store.usedBytes;
    final pct = (used / MemoryStore.byteBudget * 100).clamp(0, 100).toDouble();
    final enabled = _store.enabled;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          DshRichText(
            context.tr('这里写的话会进 AGENTS.md，DSH 在**每个新会话的第一个请求前**'
                '把它注入模型上下文 —— 与「专家」开关同一条通道。'
                '**对已经打开的会话不生效**，要新建一个会话。'),
            style: TextStyle(
                color: DshColors.textDim, fontSize: 12, height: 1.55),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Icon(Icons.description_outlined,
                  size: 14, color: DshColors.textFaint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _store.agentsMdPath,
                  style: DshFonts.code(
                      color: DshColors.textFaint, fontSize: 10.5),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      context.tr('让模型记住这些（关闭后不再注入）'),
                      style: TextStyle(color: DshColors.text, fontSize: 12.5),
                    ),
                    if (!enabled) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        context.tr('已暂停注入：AGENTS.md 里那一整块已经移除，条目还留在这里。'),
                        style: TextStyle(
                            color: DshColors.err, fontSize: 10.5, height: 1.4),
                      ),
                    ],
                  ],
                ),
              ),
              Switch(
                value: enabled,
                onChanged: (v) => _act(
                  () => _store.setEnabled(v),
                  v
                      ? context.tr('已打开注入。新建会话后生效。')
                      : context.tr('已关闭注入。AGENTS.md 里的记忆块已移除。'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 预算条：显式告诉用户快到上限了，而不是等被截断才发现
          Row(
            children: <Widget>[
              Text(
                context.tr('记忆占用 {0} / {1} 字节',
                    <Object?>['$used', '${MemoryStore.byteBudget}']),
                style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
              ),
              const Spacer(),
              if (pct >= 80)
                Text(
                  context.tr('接近上限'),
                  style: TextStyle(
                      color: DshColors.err,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600),
                ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(DshMetrics.radius(3)),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 4,
              backgroundColor: DshColors.surfaceHigh,
              valueColor: AlwaysStoppedAnimation<Color>(
                  pct >= 80 ? DshColors.err : DshColors.accent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _addCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _cardTitle(context.tr('添加一条记忆')),
            const SizedBox(height: 8),
            TextField(
              controller: _input,
              focusNode: _inputFocus,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                hintText: context.tr('例如：我是中文用户，回答用中文；先给结论再给理由。'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              style: TextStyle(color: DshColors.text, fontSize: 12.5),
            ),
            const SizedBox(height: 10),
            _MemoryFields(
              kind: _kind,
              importance: _importance,
              scope: _effectiveScope,
              canScopeWorkspace: _canScopeWorkspace,
              workspacePath: _workspacePath,
              workspaceLabel: widget.workspaceLabel,
              onKind: (k) => setState(() => _kind = k),
              onImportance: (i) => setState(() => _importance = i),
              onScope: (s) => setState(() => _scope = s),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add, size: 16),
                label: Text(context.tr('添加')),
              ),
            ),
          ],
        ),
      );

  Widget _searchRow() => TextField(
        controller: _search,
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText: context.tr('搜索记忆（按内容或分类）'),
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: context.tr('清空搜索'),
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        style: TextStyle(color: DshColors.text, fontSize: 12.5),
      );

  Widget _badge(String text, {Color? color}) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: DshColors.surfaceHigh,
          borderRadius: BorderRadius.circular(DshMetrics.radius(6)),
          border: Border.all(color: color ?? DshColors.line, width: 0.8),
        ),
        child: Text(
          text,
          style: TextStyle(
              color: color ?? DshColors.textDim,
              fontSize: 10,
              fontWeight: FontWeight.w500),
        ),
      );

  Widget _entryCard(MemoryEntry e) {
    final all = _store.entries;
    final index = all.indexWhere((x) => x.id == e.id);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            runSpacing: 4,
            children: <Widget>[
              _badge(context.tr(e.kind.label)),
              _badge(context.tr('重要度 {0}',
                  <Object?>[context.tr(e.importanceName)])),
              if (e.isWorkspaceScoped)
                _badge(context.tr('仅当前工作区 · {0}',
                    <Object?>[lastPathSegment(e.workspace!)])),
              if (e.source == MemorySource.extracted)
                _badge(context.tr('从会话提炼'), color: DshColors.accent),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            e.text,
            style: TextStyle(color: DshColors.text, fontSize: 12.5, height: 1.5),
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              // 顺序有意义：注入顺序 = 这里的顺序，靠前的更"重要"，
              // 而且超预算被截断时它活得更久。
              IconButton(
                onPressed: index <= 0
                    ? null
                    : () => _act(() => _store.move(e.id, -1), ''),
                tooltip: context.tr('上移'),
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.arrow_upward,
                    size: 16,
                    color:
                        index <= 0 ? DshColors.textFaint : DshColors.textDim),
              ),
              IconButton(
                onPressed: index < 0 || index == all.length - 1
                    ? null
                    : () => _act(() => _store.move(e.id, 1), ''),
                tooltip: context.tr('下移'),
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.arrow_downward,
                    size: 16,
                    color: index < 0 || index == all.length - 1
                        ? DshColors.textFaint
                        : DshColors.textDim),
              ),
              IconButton(
                onPressed: index <= 0
                    ? null
                    : () => _act(
                        () => _store.moveToTop(e.id),
                        context.tr('已置顶。新建会话后生效。')),
                tooltip: context.tr('置顶'),
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.vertical_align_top,
                    size: 16,
                    color:
                        index <= 0 ? DshColors.textFaint : DshColors.textDim),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => _edit(e),
                child: Text(context.tr('修改')),
              ),
              TextButton(
                onPressed: () => _delete(e),
                style: TextButton.styleFrom(foregroundColor: DshColors.err),
                child: Text(context.tr('删除')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _extractCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _cardTitle(context.tr('从最近会话提炼')),
            const SizedBox(height: 6),
            DshRichText(
              context.tr('让模型读一段真实对话，提炼出长期有效的偏好与事实。'
                  '**提炼结果不会自动写入**，要你勾选确认；'
                  '每次提炼都会真实调用一次模型（会花额度）。'),
              style: TextStyle(
                  color: DshColors.textDim, fontSize: 12, height: 1.55),
            ),
            const SizedBox(height: 10),
            if (_extracting) ...<Widget>[
              Row(
                children: <Widget>[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _extractStage,
                      style: TextStyle(
                          color: DshColors.textDim, fontSize: 11.5, height: 1.4),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _cancelExtract,
                icon: const Icon(Icons.close, size: 16),
                label: Text(context.tr('取消提炼')),
              ),
            ] else
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _pickSession,
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: Text(context.tr('选择一条会话')),
                ),
              ),
          ],
        ),
      );

  Widget _ioCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _cardTitle(context.tr('导入 / 导出')),
            const SizedBox(height: 6),
            DshRichText(
              context.tr('导出会把全部记忆（含分类、重要度、作用范围与总开关）存成一个 JSON 文件；'
                  '导入按内容去重合并，**不会覆盖**已有条目。'),
              style: TextStyle(
                  color: DshColors.textDim, fontSize: 12, height: 1.55),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _ioBusy ? null : _export,
                    icon: const Icon(Icons.ios_share, size: 16),
                    label: Text(context.tr('导出 JSON')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _ioBusy ? null : _import,
                    icon: const Icon(Icons.file_open_outlined, size: 16),
                    label: Text(context.tr('导入 JSON')),
                  ),
                ),
              ],
            ),
            if (_ioBusy) ...<Widget>[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 3),
            ],
          ],
        ),
      );
}

/// 分类 / 重要度 / 作用范围三个选择器（添加卡与修改弹窗共用一份，免得口径不一）。
class _MemoryFields extends StatelessWidget {
  const _MemoryFields({
    required this.kind,
    required this.importance,
    required this.scope,
    required this.canScopeWorkspace,
    required this.workspacePath,
    required this.onKind,
    required this.onImportance,
    required this.onScope,
    this.workspaceLabel,
  });

  final MemoryKind kind;
  final int importance;
  final MemoryScope scope;
  final bool canScopeWorkspace;
  final String workspacePath;
  final String? workspaceLabel;
  final ValueChanged<MemoryKind> onKind;
  final ValueChanged<int> onImportance;
  final ValueChanged<MemoryScope> onScope;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _label(context, context.tr('分类')),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final k in MemoryKind.values)
              DshChip(
                label: context.tr(k.label),
                selected: k == kind,
                onTap: () => onKind(k),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          context.tr(kind.hint),
          style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
        ),
        const SizedBox(height: 10),
        _label(context, context.tr('重要度')),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final i in <int>[1, 2, 3])
              DshChip(
                label: context.tr(importanceLabel(i)),
                selected: i == importance,
                onTap: () => onImportance(i),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _label(context, context.tr('作用范围')),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            DshChip(
              label: context.tr(MemoryScope.global.label),
              selected: scope == MemoryScope.global || !canScopeWorkspace,
              onTap: () => onScope(MemoryScope.global),
            ),
            if (canScopeWorkspace)
              DshChip(
                label: context.tr(MemoryScope.workspace.label),
                selected: scope == MemoryScope.workspace,
                onTap: () => onScope(MemoryScope.workspace),
              ),
          ],
        ),
        if (canScopeWorkspace && scope == MemoryScope.workspace) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            context.tr('只在这个工作目录下适用：{0}',
                <Object?>[workspaceLabel ?? workspacePath]),
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 10.5, height: 1.4),
          ),
        ],
      ],
    );
  }

  Widget _label(BuildContext context, String text) => Text(
        text,
        style: TextStyle(
            color: DshColors.textDim,
            fontSize: 11.5,
            fontWeight: FontWeight.w600),
      );
}

/// 修改一条记忆的结果（弹窗 → 页面）。
class _MemoryDraft {
  const _MemoryDraft({
    required this.text,
    required this.kind,
    required this.importance,
    required this.scope,
  });

  final String text;
  final MemoryKind kind;
  final int importance;
  final MemoryScope scope;
}

/// 修改弹窗：文本 / 分类 / 重要度 / 范围都能改。
class _EditMemoryDialog extends StatefulWidget {
  const _EditMemoryDialog({
    required this.entry,
    required this.workspacePath,
    this.workspaceLabel,
  });

  final MemoryEntry entry;
  final String workspacePath;
  final String? workspaceLabel;

  @override
  State<_EditMemoryDialog> createState() => _EditMemoryDialogState();
}

class _EditMemoryDialogState extends State<_EditMemoryDialog> {
  late final TextEditingController _text =
      TextEditingController(text: widget.entry.text);
  late MemoryKind _kind = widget.entry.kind;
  late int _importance = widget.entry.importance;
  late MemoryScope _scope = widget.entry.scope;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.tr('修改这条记忆')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _text,
                maxLines: 6,
                minLines: 2,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: context.tr('例如：回答尽量简短，先给结论。'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              _MemoryFields(
                kind: _kind,
                importance: _importance,
                scope: _scope,
                canScopeWorkspace: widget.workspacePath.trim().isNotEmpty,
                workspacePath: widget.workspacePath,
                workspaceLabel: widget.workspaceLabel,
                onKind: (k) => setState(() => _kind = k),
                onImportance: (i) => setState(() => _importance = i),
                onScope: (s) => setState(() => _scope = s),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_MemoryDraft(
            text: _text.text,
            kind: _kind,
            importance: _importance,
            scope: _scope,
          )),
          child: Text(context.tr('保存')),
        ),
      ],
    );
  }
}

/// 「从最近会话提炼」的第一步：挑一条磁盘会话。
///
/// 列表来自 ACP `session/list`（[listPersistedSessions]）：**只列不删**，
/// 0 消息空壳不列（点开必然是空的）。取最近 10 条。
class _SessionPickerSheet extends StatefulWidget {
  const _SessionPickerSheet({required this.runtime});

  final DshRuntime runtime;

  @override
  State<_SessionPickerSheet> createState() => _SessionPickerSheetState();
}

class _SessionPickerSheetState extends State<_SessionPickerSheet> {
  List<DshSession>? _sessions;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final all = await listPersistedSessions(runtime: widget.runtime);
      final usable = all.where((s) => !s.emptyShell).toList()
        ..sort((a, b) => (b.createdAt?.millisecondsSinceEpoch ?? 0)
            .compareTo(a.createdAt?.millisecondsSinceEpoch ?? 0));
      if (!mounted) return;
      setState(() => _sessions = usable.take(10).toList());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = context.tr('读取会话列表失败：{0}', <Object?>['$e']));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = _sessions;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    context.tr('选择一条会话'),
                    style: TextStyle(
                        color: DshColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: context.tr('关闭'),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            Text(
              context.tr('只列出最近的 10 条磁盘会话（没有消息的空会话不列）。'),
              style: TextStyle(color: DshColors.textFaint, fontSize: 11),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '$_error\n${context.tr('也可以直接手写一条。')}',
                  style: TextStyle(
                      color: DshColors.err, fontSize: 12, height: 1.5),
                ),
              )
            else if (sessions == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      context.tr('正在读取磁盘上的会话列表…'),
                      style:
                          TextStyle(color: DshColors.textDim, fontSize: 12),
                    ),
                  ],
                ),
              )
            else if (sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  context.tr('这台设备上没有可以提炼的会话。'),
                  style: TextStyle(color: DshColors.textDim, fontSize: 12),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: sessions.length,
                  itemBuilder: (ctx, i) {
                    final s = sessions[i];
                    final time = s.createdLabel;
                    final dir = lastPathSegment(s.cwd);
                    final sub = <String>[
                      if (time.isNotEmpty) time,
                      if (dir.isNotEmpty) dir,
                    ].join(' · ');
                    return ListTile(
                      dense: true,
                      title: Text(
                        s.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: DshColors.text, fontSize: 13),
                      ),
                      subtitle: sub.isEmpty
                          ? null
                          : Text(
                              sub,
                              style: TextStyle(
                                  color: DshColors.textFaint, fontSize: 10.5),
                            ),
                      onTap: () => Navigator.of(ctx).pop(s),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 提炼候选的确认界面：每条一个勾选框，**分类与重要度可以直接改**。
///
/// 默认全选（用户点了"提炼"就是想看结果），但**不替用户做决定**：
/// 取消 / 一条不勾 = 什么都不写。
class _CandidateSheet extends StatefulWidget {
  const _CandidateSheet({required this.items});

  final List<MemoryCandidate> items;

  @override
  State<_CandidateSheet> createState() => _CandidateSheetState();
}

class _CandidateSheetState extends State<_CandidateSheet> {
  late final List<bool> _checked = List<bool>.filled(widget.items.length, true);
  late final List<MemoryKind> _kinds =
      <MemoryKind>[for (final c in widget.items) c.kind];
  late final List<int> _importances =
      <int>[for (final c in widget.items) c.importance];

  int get _selected => _checked.where((v) => v).length;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                context.tr('提炼出 {0} 条候选，勾选要加入的',
                    <Object?>['${widget.items.length}']),
                style: TextStyle(
                    color: DshColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                context.tr('分类和重要度可以直接改。加入后是「全局」记忆'
                    '（每个工作目录都注入）；想限定某个目录，可以在条目上再改。'),
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 11, height: 1.5),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (ctx, i) => _candidateCard(i),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(context.tr('取消')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _selected == 0
                          ? null
                          : () => Navigator.of(context).pop(<MemoryCandidate>[
                                for (var i = 0; i < widget.items.length; i++)
                                  if (_checked[i])
                                    widget.items[i].copyWith(
                                      kind: _kinds[i],
                                      importance: _importances[i],
                                    ),
                              ]),
                      child: Text(context.tr('加入记忆（{0} 条）',
                          <Object?>['$_selected'])),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _candidateCard(int i) {
    final c = widget.items[i];
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
        border: Border.all(color: DshColors.divider, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Checkbox(
                value: _checked[i],
                visualDensity: VisualDensity.compact,
                onChanged: (v) => setState(() => _checked[i] = v ?? false),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    c.text,
                    style: TextStyle(
                        color: DshColors.text, fontSize: 12.5, height: 1.5),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final k in MemoryKind.values)
                DshChip(
                  label: context.tr(k.label),
                  selected: _kinds[i] == k,
                  onTap: () => setState(() => _kinds[i] = k),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final v in <int>[1, 2, 3])
                DshChip(
                  label: context.tr('重要度 {0}',
                      <Object?>[context.tr(importanceLabel(v))]),
                  selected: _importances[i] == v,
                  onTap: () => setState(() => _importances[i] = v),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
