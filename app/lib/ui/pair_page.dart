import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/bridge_state.dart';

import '../i18n/dsh_i18n.dart';

/// 配对页：输入桥地址与一次性配对码，或粘贴 `dsh-mobile://pair?...` URI。
///
/// 同时负责 wss 设置：桥启用 TLS 时，App 必须拿到**证书指纹**才能连接
/// —— 我们不盲目信任自签证书。
class PairPage extends StatefulWidget {
  const PairPage({super.key});

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final _hostController = TextEditingController(text: '192.168.1.100');
  final _portController = TextEditingController(text: '8788');
  final _codeController = TextEditingController();
  late final _nameController = TextEditingController(text: context.tr('我的手机'));
  final _fingerprintController = TextEditingController();

  bool _useTls = false;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _codeController.dispose();
    _nameController.dispose();
    _fingerprintController.dispose();
    super.dispose();
  }

  /// 解析 `dsh-mobile://pair?host=…&port=…&code=…&protocol=wss&fp=…&v=1`
  void _applyUri(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;

    final hostMatch = RegExp(r'host=([^&\s]+)').firstMatch(text);
    final portMatch = RegExp(r'port=(\d+)').firstMatch(text);
    final codeMatch = RegExp(r'code=(\d+)').firstMatch(text);
    final protoMatch =
        RegExp(r'protocol=(wss|ws)', caseSensitive: false).firstMatch(text);
    final fpMatch = RegExp(r'fp=([^&\s]+)').firstMatch(text);

    if (hostMatch == null || codeMatch == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context
              .tr('无法识别该内容，应形如 dsh-mobile://pair?host=...&port=...&code=...')),
        ),
      );
      return;
    }

    setState(() {
      _hostController.text = hostMatch.group(1)!;
      if (portMatch != null) _portController.text = portMatch.group(1)!;
      _codeController.text = codeMatch.group(1)!;
      _useTls = (protoMatch?.group(1)?.toLowerCase() ?? 'ws') == 'wss';
      if (fpMatch != null) {
        try {
          _fingerprintController.text = Uri.decodeComponent(fpMatch.group(1)!);
        } catch (_) {
          _fingerprintController.text = fpMatch.group(1)!;
        }
      }
    });
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final port = int.tryParse(_portController.text.trim());
    if (port == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.tr('端口必须是数字'))));
      return;
    }
    if (_useTls && _fingerprintController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('启用 TLS 时必须填证书指纹（电脑端启动桥时会打印）'))),
      );
      return;
    }

    await context.read<BridgeState>().pair(
          host: _hostController.text.trim(),
          port: port,
          code: _codeController.text.trim(),
          deviceName: _nameController.text.trim(),
          useTls: _useTls,
          fingerprint: _useTls ? _fingerprintController.text.trim() : null,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<BridgeState>();
    final busy = state.conn == ConnState.connecting;

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('连接 DSH'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            context.tr(
                '在电脑上双击 dsh-mobile 目录里的：\n\n  start-bridge.cmd      （启用 TLS，推荐）\n  start-bridge-ws.cmd   （明文，仅私有网络）\n  pair-phone.cmd        （生成配对码）\n'),
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _codeController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: context.tr('配对码'),
              hintText: context.tr('6 位数字，120 秒内有效'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _hostController,
                  decoration: InputDecoration(
                    labelText: context.tr('电脑地址'),
                    hintText: context.tr('Tailscale IP 或局域网 IP'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      labelText: context.tr('端口'),
                      border: const OutlineInputBorder()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
                labelText: context.tr('这台设备的名字'),
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _useTls,
            onChanged: busy ? null : (v) => setState(() => _useTls = v),
            title: Text(context.tr('使用 TLS（wss）')),
            subtitle: Text(context.tr('桥启用证书时必须打开；需要填证书指纹'),
                style: const TextStyle(fontSize: 12)),
          ),
          if (_useTls) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _fingerprintController,
              maxLines: 2,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                labelText: context.tr('证书 SHA-256 指纹'),
                hintText: context.tr('AA:BB:CC:…（电脑端启动桥时打印）'),
                helperText: context.tr('只信任这个指纹的证书，其它一律拒绝'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: busy ? null : _submit,
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.link),
            label: Text(busy ? context.tr('正在配对…') : context.tr('配对并连接')),
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
            label: Text(context.tr('从剪贴板粘贴配对信息（含指纹）')),
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
            context.tr(
                '安全提醒：桥拥有你电脑的命令执行权。优先使用 Tailscale 私有网络，不要在公网上做端口转发，也不要把配对码或证书指纹发给别人。'),
            style: TextStyle(
                fontSize: 12, color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    );
  }
}
