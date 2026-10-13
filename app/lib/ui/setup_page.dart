import 'package:flutter/material.dart';

import '../local/dsh_runtime.dart';

import '../i18n/dsh_i18n.dart';
import 'theme/dsh_tokens.dart';

/// 首次使用的一步引导。
///
/// 存在的意义：解压前所有执行路径都不可用。与其让用户面对一堆技术按钮
/// （然后点下去得到一句 `Cannot find module`），不如只给一个按钮。
class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.runtime, required this.onReady});

  final DshRuntime runtime;

  /// 解压完成后的回调（由外层切到对话界面）。
  final VoidCallback onReady;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  int _done = 0;
  String _current = '';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    DshHost.bindProgress((done, current) {
      if (!mounted) return;
      setState(() {
        _done = done;
        _current = current;
      });
    });
  }

  Future<void> _unpack() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = 0;
    });
    try {
      final ok = await DshHost.unpackRuntime();
      if (!mounted) return;
      if (!ok) throw StateError(context.tr('宿主返回失败'));
      if (!widget.runtime.isUnpacked) {
        throw StateError(context.tr('解压完成但仍找不到运行时文件'));
      }
      widget.onReady();
    } catch (e) {
      debugPrint('[dsh-setup] unpack failed: $e');
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('泡泡猫的DSH'))),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          const SizedBox(height: 20),
          Icon(Icons.download_for_offline_outlined,
              size: 46, color: scheme.primary),
          const SizedBox(height: 18),
          Text(context.tr('首次使用：准备运行时'),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Text(
            context
                .tr('DSH 会在这台手机上运行，需要先把随包的运行环境解开（约 26000 个文件，75 秒左右）。这一步只做一次。'),
            style: TextStyle(color: scheme.outline, height: 1.6, fontSize: 13),
          ),
          const SizedBox(height: 26),
          if (_busy) ...[
            const LinearProgressIndicator(minHeight: 4),
            const SizedBox(height: 10),
            Text(context.tr('已解压 {0} 个文件', [_done]),
                style: const TextStyle(fontSize: 12)),
            Text(
              _current,
              style: TextStyle(
                  fontSize: 11, color: scheme.outline, fontFamily: 'monospace'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
          ],
          FilledButton.icon(
            onPressed: _busy ? null : _unpack,
            icon: const Icon(Icons.play_arrow),
            label: Text(_busy ? context.tr('正在解压…') : context.tr('开始准备')),
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          ),
          if (_error != null) ...[
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
              ),
              child: SelectableText(
                context.tr('准备失败：{0}', [_error]),
                style: TextStyle(
                    color: scheme.onErrorContainer, fontSize: 12, height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
