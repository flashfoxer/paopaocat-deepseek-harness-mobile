import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../protocol/models.dart';
import '../state/bridge_state.dart';
import 'session_page.dart';

/// 会话列表：主机的会话索引 + 新建会话入口。
class SessionsPage extends StatelessWidget {
  const SessionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<BridgeState>();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(state.host?.name ?? 'DSH', style: const TextStyle(fontSize: 16)),
            Text(
              _subtitle(state),
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: state.isConnected ? () => state.loadSessions() : null,
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'reconnect') await state.reconnect();
              if (value == 'forget') await state.forgetDevice();
              if (value == 'logs') {
                if (!context.mounted) return;
                await showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  builder: (_) => _LogSheet(lines: state.logs),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'reconnect', child: Text('重新连接')),
              PopupMenuItem(value: 'logs', child: Text('连接日志')),
              PopupMenuItem(value: 'forget', child: Text('解除配对')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: !state.isConnected
            ? null
            : () async {
                final id = await state.createSession();
                if (id == null || !context.mounted) return;
                await state.openSession(id);
                if (!context.mounted) return;
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SessionPage()),
                );
              },
        icon: const Icon(Icons.add),
        label: const Text('新会话'),
      ),
      body: Column(
        children: [
          if (!state.isConnected) _StatusBanner(state: state),
          if (state.errorMessage != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Text(
                state.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
          Expanded(
            child: state.sessions.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        state.isConnected
                            ? '还没有可恢复的会话。\n点右下角新建一个。'
                            : '正在连接电脑上的 DSH…',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).colorScheme.outline),
                      ),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: state.loadSessions,
                    child: ListView.separated(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: state.sessions.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final session = state.sessions[index];
                        return _SessionTile(
                          session: session,
                          onTap: () async {
                            await state.openSession(session.id);
                            if (!context.mounted) return;
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(builder: (_) => const SessionPage()),
                            );
                          },
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  String _subtitle(BridgeState state) {
    switch (state.conn) {
      case ConnState.connected:
        return '${state.host?.permissionMode ?? ''} · ${state.sessions.length} 个会话';
      case ConnState.connecting:
        return '连接中…';
      case ConnState.error:
        return '连接失败';
      case ConnState.unpaired:
        return '未配对';
    }
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.onTap});

  final SessionInfo session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final running = session.isRunning;
    return ListTile(
      leading: Icon(
        running ? Icons.autorenew : Icons.chat_bubble_outline,
        color: running ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(session.displayName),
      subtitle: Text(
        session.cwd,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: running
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Text('${session.lastSeq}', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline)),
      onTap: onTap,
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.state});

  final BridgeState state;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (state.bridgeStatus) {
      'running' => ('正在连接桥…', Colors.orange),
      'restarting' => ('电脑端 DSH 正在重启：${state.bridgeDetail ?? ''}', Colors.orange),
      'failed' => ('电脑端 DSH 启动失败：${state.bridgeDetail ?? ''}', Colors.red),
      _ => ('电脑端状态：${state.bridgeStatus}', Colors.orange),
    };
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color))),
          TextButton(
            onPressed: () => state.reconnect(),
            child: const Text('重连'),
          ),
        ],
      ),
    );
  }
}

class _LogSheet extends StatelessWidget {
  const _LogSheet({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: lines.length,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            lines[lines.length - 1 - i],
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ),
    );
  }
}
