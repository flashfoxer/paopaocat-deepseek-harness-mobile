import 'package:flutter/material.dart';

import '../widgets/common.dart';

import '../../app_version.dart';
import '../../data/changelog.dart';
import '../theme/dsh_tokens.dart';

import '../../i18n/dsh_i18n.dart';

/// 「更新说明」整页（从「设置 → 关于 → 更新说明」推入）。
///
/// 为什么是整页而不是弹层：版本多了以后弹层会被高度憋住，整页天然能滚，
/// 也能一屏看到"这个 App 一路改了什么"。
///
/// 版面：顶部一句说明 → 版本列表（**新 → 旧**）→ 底部如实说明。
/// 每个版本一行：版本号（等宽字体）+ 日期 + 一句话摘要；点这一行展开 / 收起
/// 它下面那几条改动（手风琴，**默认展开最新那一版**）。
///
/// ⚠️ 主题约束（与项目里其它页面同一套规矩，别在这里破例）：
/// `DshColors.x` 现在是**运行时 getter**（换成浅色皮肤时读的是另一份色板），
/// 所以凡是 build 里读 [DshColors] 的组件，**调用点都不许写 `const`** ——
/// const 的 widget 实例在重建时会被 Flutter 原样复用，颜色会**静默不刷新**。
/// 本文件里刻意不给这类组件加 `const`；需要用 `const` 的地方都只放
/// 与皮肤无关的东西（间距、图标尺寸）。
class ReleaseNotesPage extends StatefulWidget {
  const ReleaseNotesPage({super.key});

  @override
  State<ReleaseNotesPage> createState() => _ReleaseNotesPageState();
}

class _ReleaseNotesPageState extends State<ReleaseNotesPage> {
  /// 当前展开的版本在 [kChangelog] 里的下标；`-1` = 全都收起。
  ///
  /// 默认 `0`：点开「更新说明」的人十有八九想看的是刚更新的这一版，
  /// 所以最新那版默认就是摊开的（不用再点一下）。
  int _expanded = 0;

  void _toggle(int index) {
    setState(() => _expanded = _expanded == index ? -1 : index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 皮肤是运行时变量：这里不能写 const（const 实例换肤时会被原样复用、颜色不刷新）
      backgroundColor: Colors.transparent,
      // AppBar 的颜色来自 ThemeData（appBarTheme 跟着皮肤走），标题本身与皮肤无关
      appBar: AppBar(title: Text(context.tr('更新说明'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          DshMetrics.pagePad,
          10,
          DshMetrics.pagePad,
          30,
        ),
        children: <Widget>[
          _intro(),
          const SizedBox(height: 14),
          for (var i = 0; i < kChangelog.length; i++) ...<Widget>[
            _versionCard(i),
            const SizedBox(height: 12),
          ],
          _footer(),
        ],
      ),
    );
  }

  /// 顶部一句说明：**先说清当前版本号**，再说这一页怎么用。
  Widget _intro() => Text(
        context.tr('当前版本 v{0}；下面是每个版本改了什么（点版本号展开 / 收起）。', [kAppVersion]),
        style: TextStyle(color: DshColors.textDim, fontSize: 12.5, height: 1.6),
      );

  /// 一个版本一张「玻璃卡」：标题行（版本号 + 日期 + 状态 + 摘要）永远可见，
  /// 下面那几条改动只在展开时出现。
  Widget _versionCard(int index) {
    final note = kChangelog[index];
    final open = _expanded == index;
    // 当前版本用强调色描边 + 「当前版本」小药丸双重标记：一眼能认出自己在用哪一版。
    final current = note.isCurrent;
    return Container(
      decoration: DshColors.panel(
        borderColor: current ? DshColors.accent : null,
        borderWidth: current ? 1.2 : 1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 语义：整行可点，读屏报"版本 X（日期）… 点一下展开/收起"，
          // 否则一屏文本会被读成一堆互不相干的碎片。
          Semantics(
            button: true,
            label: context.tr('版本 {0}{1}{2}：{3}（点一下{4}）', [
              note.version,
              note.date == null ? '' : '（${note.date}）',
              current ? '（当前版本）' : '',
              note.headline,
              open ? '收起' : '展开'
            ]),
            child: InkWell(
              onTap: () => _toggle(index),
              borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  DshMetrics.cardPad,
                  11,
                  DshMetrics.cardPad,
                  11,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        // 版本号是"机器标识"，走等宽字体族（与路径 / route / model id 同一套排版）
                        Text(
                          'v${note.version}',
                          style: DshFonts.code(
                            color: current ? DshColors.accent : DshColors.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (note.date != null) ...<Widget>[
                          const SizedBox(width: 8),
                          Text(
                            note.date!,
                            style: TextStyle(
                              color: DshColors.textFaint,
                              fontSize: 11,
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        if (current) _tag(context.tr('当前版本'), DshColors.accent),
                        const Spacer(),
                        Icon(
                          open ? Icons.expand_less : Icons.expand_more,
                          size: 20,
                          color: DshColors.textDim,
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    DshRichText(
                      note.headline,
                      style: TextStyle(
                        color: DshColors.textDim,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    if (note.status != null) ...<Widget>[
                      const SizedBox(height: 6),
                      Row(
                        children: <Widget>[
                          Icon(
                            Icons.schedule,
                            size: 12,
                            color: current
                                ? DshColors.accent
                                : DshColors.textFaint,
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              note.status!,
                              style: TextStyle(
                                color: current
                                    ? DshColors.accent
                                    : DshColors.textFaint,
                                fontSize: 11,
                                fontWeight:
                                    current ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (open) ..._changesBlock(note),
        ],
      ),
    );
  }

  /// 展开出来的那一块：一条改动一行（圆点 + 文字）。
  List<Widget> _changesBlock(ReleaseNote note) => <Widget>[
        Divider(height: 1, thickness: 1, color: DshColors.line),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            DshMetrics.cardPad,
            10,
            DshMetrics.cardPad,
            12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final change in note.changes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Icon(
                          Icons.circle,
                          size: 5,
                          color: DshColors.accent,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        // 正文里有 1082 处 `**` 与 548 处反引号 —— 用普通 Text 渲染
                        // 用户在界面上看到的就是裸星号（审计 P1-6）。这里起一次
                        // 就把整页清掉。
                        child: DshRichText(
                          change,
                          style: TextStyle(
                            color: DshColors.text,
                            fontSize: 12.5,
                            height: 1.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ];

  /// 底部如实说明：**不许暗示这里能"检查更新"** —— 本页只是随版本发出去的文字记录，
  /// App 并没有联网查版本的能力。
  Widget _footer() => Container(
        padding: const EdgeInsets.all(DshMetrics.cardPad),
        decoration: DshColors.panel(glow: false),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.info_outline, size: 14, color: DshColors.textFaint),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                context.tr(
                    '这些说明是随 App 版本一起发出来的文字记录（离线存在安装包里）；App 不会联网检查新版本，也不会提示你升级。'),
                style: TextStyle(
                  color: DshColors.textFaint,
                  fontSize: 11,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
      );

  /// 小药丸标签（「当前版本」）。默认灰，语义色由调用方给。
  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        margin: const EdgeInsets.only(left: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(DshMetrics.radius(20)),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 0.7),
        ),
        child: Text(
          text,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w600),
        ),
      );
}
