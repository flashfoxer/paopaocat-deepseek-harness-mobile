import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../protocol/models.dart';
import '../state/bridge_state.dart';

/// 会话界面：消息流 + 工具卡片 + 审批 + 输入。
class SessionPage extends StatefulWidget {
  const SessionPage({super.key});

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    await context.read<BridgeState>().sendPrompt(text);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<BridgeState>();
    final session = state.activeSession;
    final running = session?.isRunning ?? false;

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session?.displayName ?? '会话', style: const TextStyle(fontSize: 16)),
            Text(
              running ? '执行中…' : '空闲 · ${state.entries.length} 条',
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
        actions: [
          if (running)
            TextButton.icon(
              onPressed: () => state.cancelTurn(),
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('取消'),
            ),
        ],
      ),
      body: Column(
        children: [
          if (state.usageUsed != null)
            LinearProgressIndicator(
              value: state.usageSize != null && state.usageSize! > 0
                  ? (state.usageUsed! / state.usageSize!).clamp(0.0, 1.0)
                  : null,
              minHeight: 2,
            ),
          Expanded(
            child: state.entries.isEmpty
                ? Center(
                    child: Text(
                      '在下面输入第一条消息。\nAgent 会在你的电脑上读写文件、执行命令。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.outline),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    itemCount: state.entries.length,
                    itemBuilder: (context, i) => _EntryView(entry: state.entries[i]),
                  ),
          ),
          if (state.pendingPermission != null)
            _PermissionCard(
              request: state.pendingPermission!,
              onDecide: (decision) => state.decidePermission(decision),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: running ? '等待当前轮次结束或先取消…' : '输入消息…',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                      enabled: !running,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: running ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry});

  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (entry.kind) {
      case 'user':
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(entry.text, style: TextStyle(color: scheme.onPrimaryContainer)),
          ),
        );

      case 'assistant':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: SelectableText(entry.text, style: const TextStyle(height: 1.45)),
        );

      case 'thought':
        return Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(left: 8, bottom: 12),
            title: Row(
              children: [
                Icon(Icons.psychology_outlined, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Text('思考过程', style: TextStyle(fontSize: 12, color: scheme.outline)),
              ],
            ),
            children: [
              SelectableText(
                entry.text,
                style: TextStyle(fontSize: 12, height: 1.4, color: scheme.outline),
              ),
            ],
          ),
        );

      case 'tool':
        return _ToolCard(entry: entry);

      default:
        return const SizedBox.shrink();
    }
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.entry});

  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = entry.toolStatus ?? 'unknown';
    final (icon, color) = switch (status) {
      'completed' => (Icons.check_circle_outline, Colors.green),
      'failed' => (Icons.error_outline, scheme.error),
      'in_progress' || 'pending' => (Icons.autorenew, Colors.orange),
      _ => (Icons.build_outlined, scheme.outline),
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.toolTitle ?? '工具调用',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
                Text(status, style: TextStyle(fontSize: 11, color: color)),
              ],
            ),
            if (entry.toolCommand != null && entry.toolCommand!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  entry.toolCommand!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
            if (entry.toolOutput != null && entry.toolOutput!.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                entry.toolOutput!.length > 1500
                    ? '${entry.toolOutput!.substring(0, 1500)}\n…（已截断）'
                    : entry.toolOutput!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.35),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 审批卡片：高风险命令必须醒目，且永不自动允许。
class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.request, required this.onDecide});

  final PermissionRequest request;
  final void Function(String decision) onDecide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final high = request.isHighRisk;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: high ? scheme.errorContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: high ? scheme.error : scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(high ? Icons.gpp_maybe : Icons.shield_outlined, color: high ? scheme.error : null),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  high ? '高风险操作，请确认' : 'Agent 请求执行操作',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (high && request.riskLabel.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              request.riskLabel,
              style: TextStyle(color: scheme.error, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 10),
          if (request.command != null && request.command!.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                request.command!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            )
          else
            Text('（未能取到命令详情，toolCallId=${request.toolCallId ?? '无'}）',
                style: TextStyle(fontSize: 12, color: scheme.outline)),
          const SizedBox(height: 6),
          Text('工作目录：${request.cwd}', style: TextStyle(fontSize: 11, color: scheme.outline)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () => onDecide('allow_once'),
                child: const Text('仅本次允许'),
              ),
              OutlinedButton(
                onPressed: high ? null : () => onDecide('allow_session'),
                child: const Text('本次会话始终允许'),
              ),
              TextButton(
                onPressed: () => onDecide('reject_once'),
                child: const Text('拒绝'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
