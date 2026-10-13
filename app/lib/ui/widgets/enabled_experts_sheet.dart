import 'package:flutter/material.dart';

import '../../data/expert_catalog.dart';
import '../../data/expert_store.dart';
import '../theme/dsh_tokens.dart';

import '../../i18n/dsh_i18n.dart';

/// 会话页的「专家中心」弹层。
///
/// 用户要求：**点专家中心以后，显示"已经打开开关的专家"**。
/// 所以这里只列 [ExpertStore] 里已开启的那些，不显示整个专家库
/// （整个库在底部导航的「专家」页看）。
///
/// 数据是**真数据**：`$DSH_HOME/experts.json` 里的开关状态
/// + 内置的专家目录快照（用于取名字/简介）。空态会明确告诉用户去哪儿开。
Future<void> showEnabledExpertsSheet(
  BuildContext context, {
  required String dshHome,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: DshColors.surfaceStrong,
    isScrollControlled: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(DshMetrics.radius(18))),
    ),
    builder: (_) => _EnabledExpertsSheet(dshHome: dshHome),
  );
}

class _EnabledExpertsSheet extends StatefulWidget {
  const _EnabledExpertsSheet({required this.dshHome});

  final String dshHome;

  @override
  State<_EnabledExpertsSheet> createState() => _EnabledExpertsSheetState();
}

class _EnabledExpertsSheetState extends State<_EnabledExpertsSheet> {
  bool _loading = true;
  String? _error;
  List<ExpertEntry> _enabled = const [];
  String _agentsMdPath = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final store = ExpertStore(dshHome: widget.dshHome);
      await store.load();
      final catalog = await ExpertCatalog.load();
      ExpertCatalogCache.current = catalog;
      final list = [
        for (final e in catalog.experts)
          if (store.isEnabled(e.slug)) e,
      ];
      debugPrint('[dsh-expert] 会话专家中心：已开启 ${list.length} 名'
          '（${list.map((e) => e.name).join('、')}）');
      if (!mounted) return;
      setState(() {
        _enabled = list;
        _agentsMdPath = store.agentsMdPath;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[dsh-expert] 会话专家中心载入失败：$e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      maxChildSize: 0.9,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: DshColors.divider,
                borderRadius: BorderRadius.circular(DshMetrics.radius(2)),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.auto_awesome_outlined,
                  size: 17, color: DshColors.accent),
              const SizedBox(width: 8),
              Text(context.tr('专家中心'),
                  style: TextStyle(
                    color: DshColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  )),
              const Spacer(),
              Text(context.tr('已开启 {0} 名', [_enabled.length]),
                  style: TextStyle(color: DshColors.textDim, fontSize: 11.5)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            context.tr(
                '这里只显示你在「专家」页打开开关的专家；它们的角色摘要已写入下面这个文件，DSH 会在新会话的第一个请求前注入模型上下文。'),
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 11, height: 1.5),
          ),
          if (_agentsMdPath.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(_agentsMdPath,
                style: TextStyle(
                  color: DshColors.textFaint,
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                )),
          ],
          const Divider(height: 24),
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: DshColors.accent),
                ),
              ),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(context.tr('读取开关状态失败：{0}', [_error]),
                  style: TextStyle(color: DshColors.err, fontSize: 12)),
            )
          else if (_enabled.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Column(
                children: [
                  Icon(Icons.toggle_off_outlined,
                      size: 34, color: DshColors.textFaint),
                  const SizedBox(height: 12),
                  Text(context.tr('还没有开启任何专家'),
                      style:
                          TextStyle(color: DshColors.textDim, fontSize: 13.5)),
                  const SizedBox(height: 8),
                  Text(context.tr('去「专家」页打开开关，开启的专家会出现在这里。'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: DshColors.textFaint,
                          fontSize: 11.5,
                          height: 1.5)),
                ],
              ),
            )
          else
            for (final e in _enabled) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: DshColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(11)),
                  border: Border.all(color: DshColors.divider, width: 0.8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(e.emoji.isNotEmpty ? e.emoji : '🧠',
                            style: const TextStyle(fontSize: 13)),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(e.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: DshColors.text,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              )),
                        ),
                        const Spacer(),
                        Icon(Icons.check_circle,
                            size: 13, color: DshColors.accent),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(e.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: DshColors.textFaint,
                          fontSize: 11,
                          height: 1.4,
                        )),
                  ],
                ),
              ),
            ],
        ],
      ),
    );
  }
}
