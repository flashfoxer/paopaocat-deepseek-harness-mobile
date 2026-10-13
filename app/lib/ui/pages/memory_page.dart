import 'package:flutter/material.dart';

import '../../data/memory_store.dart';
import '../../i18n/dsh_i18n.dart';
import '../theme/dsh_tokens.dart';
import '../widgets/common.dart';

/// 「记忆」页：用户自己写一段长期生效的偏好/约定。
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
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key, required this.dshHome});

  final String dshHome;

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  late final MemoryStore _store = MemoryStore(dshHome: widget.dshHome);
  final TextEditingController _input = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
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

  Future<void> _add() async {
    final text = _input.text.trim();
    final msgEmpty = context.tr('先写点内容再添加');
    final msgOk = context.tr('已添加。新建会话后生效。');
    if (text.isEmpty) {
      _toast(msgEmpty);
      return;
    }
    await _act(() => _store.add(text), msgOk);
    if (!mounted) return;
    // 只有真的加进去了才清空输入框（失败时别把用户写的东西弄丢）
    if (_store.entries.any((e) => e.text == MemoryStore.sanitize(text).trim())) {
      _input.clear();
    }
    setState(() {});
  }

  Future<void> _edit(MemoryEntry e) async {
    // 文案在 await 之前取好：跨 await 再用 context 会被 lint 拦
    //（也不安全 —— 弹窗期间页面可能已经被 pop 掉）。
    final msgOk = context.tr('已修改。新建会话后生效。');
    final ctl = TextEditingController(text: e.text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('修改这条记忆')),
        content: TextField(
          controller: ctl,
          maxLines: 6,
          minLines: 2,
          autofocus: true,
          decoration: InputDecoration(
            hintText: context.tr('例如：回答尽量简短，先给结论。'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('保存')),
          ),
        ],
      ),
    );
    final text = ctl.text;
    ctl.dispose();
    if (ok != true) return;
    await _act(() => _store.update(e.id, text), msgOk);
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

  @override
  Widget build(BuildContext context) {
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
              padding: const EdgeInsets.fromLTRB(
                  DshMetrics.pagePad, 12, DshMetrics.pagePad, 24),
              children: <Widget>[
                _explainCard(),
                const SizedBox(height: 12),
                _addCard(),
                const SizedBox(height: 12),
                if (_store.isEmpty)
                  DshRichText(
                    context.tr('还没有任何记忆。上面写一条，新建会话后模型就会看到它。'),
                    style: TextStyle(
                        color: DshColors.textFaint, fontSize: 12, height: 1.5),
                  )
                else
                  for (var i = 0; i < _store.entries.length; i++) ...<Widget>[
                    _entryCard(_store.entries[i], i),
                    const SizedBox(height: 8),
                  ],
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

  Widget _explainCard() {
    final used = _store.usedBytes;
    final pct = (used / MemoryStore.byteBudget * 100).clamp(0, 100).toDouble();
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
          const SizedBox(height: 10),
          // 预算条：显式告诉用户快到上限了，而不是等被截断才发现
          Row(
            children: <Widget>[
              Text(
                context.tr('记忆占用 {0} / {1} 字节', ['$used', '${MemoryStore.byteBudget}']),
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
            Text(
              context.tr('添加一条记忆'),
              style: TextStyle(
                  color: DshColors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _input,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                hintText: context.tr('例如：我是中文用户，回答用中文；先给结论再给理由。'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              style: TextStyle(color: DshColors.text, fontSize: 12.5),
            ),
            const SizedBox(height: 8),
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

  Widget _entryCard(MemoryEntry e, int index) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SelectableText(
              e.text,
              style: TextStyle(
                  color: DshColors.text, fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                // 顺序有意义：注入顺序 = 这里的顺序，靠前的更"重要"，
                // 而且超预算被截断时它活得更久。
                IconButton(
                  onPressed:
                      index == 0 ? null : () => _act(() => _store.move(e.id, -1), ''),
                  tooltip: context.tr('上移'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.arrow_upward,
                      size: 16,
                      color: index == 0
                          ? DshColors.textFaint
                          : DshColors.textDim),
                ),
                IconButton(
                  onPressed: index == _store.count - 1
                      ? null
                      : () => _act(() => _store.move(e.id, 1), ''),
                  tooltip: context.tr('下移'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.arrow_downward,
                      size: 16,
                      color: index == _store.count - 1
                          ? DshColors.textFaint
                          : DshColors.textDim),
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
