/// App 里「板块」这一层的共享组件。
///
/// ## 为什么要有这个文件
///
/// 设置页原本把「玻璃卡 / 板块标题 / 可折叠板块 / 入口行」都写在自己的私有类里
/// （`_card` / `_SectionTitle` / `_CollapsibleSection` / `_aboutTile`）。
/// 后来新增的「本地大模型」页需要**同一套观感**——复制一份的代价是：
/// 以后改圆角、改间距、改箭头动画，两处会慢慢跑偏，用户看到的就是"两个 App"。
///
/// 所以这里把它们提成共享组件，两页共用**同一份实现**：
///   * [DshGlassCard]      —— 玻璃卡（半透明面板 + 1px 边 + 圆角 + 柔光）
///   * [DshSectionTitle]   —— 板块标题字（15pt / w600）
///   * [DshCollapsibleSection] —— 可折叠板块（点标题展开/收起，收起时画一条分隔线）
///   * [DshStaticSection]  —— 常驻展开的板块（如「关于」），**与折叠板块共用同一套标题间距**
///   * [DshTileRow]        —— 一行入口（图标 + 标题 + 说明 + 箭头）
library;

import 'package:flutter/material.dart';

import '../theme/dsh_tokens.dart';

/// 玻璃卡：板块内容的统一容器。
class DshGlassCard extends StatelessWidget {
  const DshGlassCard({super.key, required this.child, this.padding});

  final Widget child;

  /// 默认 [DshMetrics.cardPad]（与设置页一致）。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding ?? const EdgeInsets.all(DshMetrics.cardPad),
        decoration: DshColors.panel(),
        child: child,
      );
}

/// 板块标题字。
class DshSectionTitle extends StatelessWidget {
  const DshSectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          // 栏目行是设置/模型页的视觉锚点。字太小、颜色太淡会像"说明文字"而不是"标题"。
          color: DshColors.text,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      );
}

/// 可折叠板块：标题与箭头一起渲染，展开才显示内容；收起时画一条分隔线。
///
/// 默认**收起** —— 用户要的是"下拉"，不是默认全摊开（这是本项目的既有约定）。
class DshCollapsibleSection extends StatefulWidget {
  const DshCollapsibleSection({
    super.key,
    required this.title,
    required this.child,
    this.initiallyOpen = false,
  });

  final String title;
  final Widget child;

  /// 极少数情况需要默认展开（例如"服务状态"这种一眼要看的东西）。
  final bool initiallyOpen;

  @override
  State<DshCollapsibleSection> createState() => _DshCollapsibleSectionState();
}

class _DshCollapsibleSectionState extends State<DshCollapsibleSection> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          button: true,
          label: '${widget.title}，${_open ? '已展开' : '已收起'}',
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 10, 2, 10),
              child: Row(
                children: <Widget>[
                  DshSectionTitle(widget.title),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 160),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 22,
                      color: DshColors.textDim,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_open)
          widget.child
        else
          Divider(height: 1, thickness: 0.5, color: DshColors.line),
      ],
    );
  }
}

/// 常驻展开的板块（如「关于」）。
///
/// ⚠️ 它存在的意义就是**标题间距**：折叠板块的标题自带 `10/10` 内边距，
/// 而常驻板块如果直接 `Text + 卡片`，标题就会**贴着**卡片 —— 显得很挤。
/// 用这个组件，两种板块的节奏一致。
class DshStaticSection extends StatelessWidget {
  const DshStaticSection({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 2, 10),
            child: DshSectionTitle(title),
          ),
          child,
        ],
      );
}

/// 一行入口：图标 + 标题 + 说明 + 箭头。
///
/// 观感逐字沿用设置页原来的 `_aboutTile`（含语义节点的写法 —— 这里用
/// `container: true` 而不是 `excludeSemantics`，否则 uiautomator 里这个节点会被
/// 并进父节点，测试点不到它）。
class DshTileRow extends StatelessWidget {
  const DshTileRow({
    super.key,
    required this.icon,
    required this.title,
    required this.note,
    required this.onTap,
    this.tint,
  });

  final IconData icon;
  final String title;
  final String note;
  final VoidCallback onTap;

  /// 图标颜色（默认 accent）。用于"接下来这一步"的强调。
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$title：$note',
      container: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          decoration: BoxDecoration(
            color: DshColors.surfaceHigh,
            borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
            border: Border.all(color: DshColors.line, width: 1),
          ),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 16, color: tint ?? DshColors.accent),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        color: DshColors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      note,
                      style: TextStyle(
                        color: DshColors.textFaint,
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 18, color: DshColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}
