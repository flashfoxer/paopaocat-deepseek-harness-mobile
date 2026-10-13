import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/bridge_state.dart';

/// 配对页：输入桥地址与一次性配对码，或粘贴 `dsh-mobile://pair?...` URI。
class PairPage extends StatefulWidget {
  const PairPage({super.key});

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final _hostController = TextEditingController(text: '192.168.1.100');
  final _portController = TextEditingController(text: '8788');
  final _codeController = TextEditingController();
  final _nameController = TextEditingController(text: '我的手机');

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  /// 解析 `dsh-mobile://pair?host=...&port=...&code=...&v=1`
  void _applyUri(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    final match = RegExp(r'host=([^&\s]+)').firstMatch(text);
    final portMatch = RegExp(r'port=(\d+)').firstMatch(text);
    final codeMatch = RegExp(r'code=(\d+)').firstMatch(text);
    if (match == null || codeMatch == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法识别该内容，应形如 dsh-mobile://pair?host=...&port=...&code=...')),
      );
      return;
    }
    setState(() {
      _hostController.text = match.group(1)!;
      if (portMatch != null) _portController.text = portMatch.group(1)!;
      _codeController.text = codeMatch.group(1)!;
    });
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final port = int.tryParse(_portController.text.trim());
    if (port == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('端口必须是数字')));
      return;
    }
    await context.read<BridgeState>().pair(
          host: _hostController.text.trim(),
          port: port,
          code: _codeController.text.trim(),
          deviceName: _nameController.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<BridgeState>();
    final busy = state.conn == ConnState.connecting;

    return Scaffold(
      appBar: AppBar(title: const Text('连接 DSH')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '在电脑上运行：\n\n'
            '  cd dsh-mobile/bridge\n'
            '  node src/bridge.mjs serve      # 启动桥\n'
            '  node src/bridge.mjs pair       # 生成配对码\n\n'
            '然后用下面任意一种方式连接。',
            style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _codeController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '配对码',
              hintText: '6 位数字',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _hostController,
                  decoration: const InputDecoration(
                    labelText: '电脑地址',
                    hintText: 'Tailscale IP 或局域网 IP',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '端口', border: OutlineInputBorder()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: '这台设备的名字', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: busy ? null : _submit,
            icon: busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.link),
            label: Text(busy ? '正在配对…' : '配对并连接'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () async {
                    final data = await Clipboard.getData('text/plain');
                    _applyUri(data?.text ?? '');
                  },
            icon: const Icon(Icons.content_paste),
            label: const Text('从剪贴板粘贴配对信息'),
          ),
          if (state.errorMessage != null) ...[
            const SizedBox(height: 20),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline),
                    const SizedBox(width: 10),
                    Expanded(child: Text(state.errorMessage!)),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          Text(
            '安全提醒：桥拥有你电脑的命令执行权。'
            '优先使用 Tailscale 私有网络，不要在公网上做端口转发，'
            '也不要把配对码发给别人。',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    );
  }
}
