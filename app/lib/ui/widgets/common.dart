import 'package:flutter/material.dart';

import '../theme/dsh_tokens.dart';

/// 各页共用的空态（设计稿里「暂无定时任务」就是这个形态）。
///
/// [centerY] 控制空态整体中心落在可用高度的哪个比例上。
/// 设计稿 page-06 的 `暂无定时任务` 在 y=1537~1577（屏高 58.2%~59.7%），
/// 折算到"顶栏下方剩余空间"里就是 0.60 —— 所以定时任务页传 0.6，
/// 其余页保持 0.5（居中）。
class DshEmptyState extends StatelessWidget {
  const DshEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.centerY = 0.5,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final double centerY;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final groupHeight = 38 + 14 + 20 + (hint != null ? (8 + 34) : 0);
        final top = (c.maxHeight * centerY - groupHeight / 2)
            .clamp(0.0, double.infinity);
        return Column(
          children: [
            SizedBox(height: top),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 38, color: DshColors.textFaint),
                const SizedBox(height: 14),
                Text(
                  title,
                  style: TextStyle(color: DshColors.textDim, fontSize: 14),
                ),
                if (hint != null) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Text(
                      hint!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: DshColors.textFaint,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 页面大标题（居中）。
///
/// 设计稿里 05/06/07 三页的大标题文字带都是 y≈199~255，中心 227/2640 = 8.6%，
/// 是**跨页一致**的，所以位置由 [DshPageHeader] 统一算，这里只管字形。
///
/// 字号 21pt 的来历：设计稿 `资料库` 字高 56 设计像素 = 2.1% 屏高，
/// 在 914dp 高的机型上 ≈ 19.4dp，加上中文 x-height 修正取 21。
class DshPageTitle extends StatelessWidget {
  const DshPageTitle({super.key, required this.text, this.subtitle});

  final String text;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: TextStyle(
            color: DshColors.text,
            fontSize: 21,
            fontWeight: FontWeight.w700,
            height: 1.15,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 10),
          Text(
            subtitle!,
            style: TextStyle(color: DshColors.textDim, fontSize: 12.5),
          ),
        ],
      ],
    );
  }
}

/// 统一页头：把「大标题中心落在设计稿 y=227」这件事集中实现一次。
///
/// 之所以做成组件而不是各页自己写 `SizedBox(height: 22)`：
/// 设计稿各页标题 y 完全一致（199~255），如果每页各写一个魔数，
/// 改一次基准就要改五处，而且很容易出现某页差几十像素。
///
/// [screenHeight] 传 `MediaQuery.size.height`（dp、不含状态栏）。
class DshPageHeader extends StatelessWidget {
  const DshPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  /// 由设计稿反推的纵向定位（详见 DshMetrics 的注释）：
  /// 标题中心=227/2640，状态栏=72/2640。用一元一次式表达，
  /// 保证任何屏高下"标题中心距状态栏底"这一段都等于设计稿的比例。
  static double paddingTop(double screenHeight) => screenHeight * 0.0562 - 21.3;

  /// 标题带到内容区（搜索框 / Tab 行）的留白。
  static double gapAfter(double screenHeight) =>
      DshMetrics.kContentTopY / kDesignH * screenHeight - 46;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          DshMetrics.pagePad,
          paddingTop(h),
          DshMetrics.pagePad,
          0,
        ),
        child: Row(
          children: [
            // 左占位 + 右占位等宽，保证标题**永远居中**（不受 trailing 宽度影响）
            SizedBox(width: trailing == null ? 0 : 64),
            Expanded(child: DshPageTitle(text: title, subtitle: subtitle)),
            // ⚠️ 这里以前写的是 `SizedBox(width: 64, child: trailing)` —— **把右侧写死 64px**。
            //    调用方塞进来的东西可能远宽于 64（本地对话页曾塞 3 个 IconButton = 144px），
            //    多出来的部分直接被挤到**屏幕外**（用户 2026-10-09 真机反馈：
            //    "界面图标都挤出屏幕以外"、"右上角的图标也是"）。
            //
            //    现在：**最小 64、最大 168**，居中。
            //    · 窄的（单个 IconButton 48px）→ 仍是 64，**和以前逐像素一致**；
            //    · 宽的（多个按钮 / 带字按钮）→ 涨到自己的宽度，但不超过 168；
            //    · 再宽就收敛到上限，标题让位 —— 宁可标题变窄，也不让图标跑出屏幕。
            if (trailing != null)
              ConstrainedBox(
                constraints:
                    const BoxConstraints(minWidth: 64, maxWidth: 168),
                child: Align(
                  alignment: Alignment.center,
                  widthFactor: 1,
                  child: trailing,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 小型筛选胶囊（专家页分类、资料库 Tab 都用这个形状）。
class DshChip extends StatelessWidget {
  const DshChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            // 当前项 = 青→紫渐变（网站 --grad），未选中 = 玻璃面板 + 1px 细边
            color: selected ? null : DshColors.surface,
            gradient: selected ? DshColors.grad : null,
            borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
            border: Border.all(
              color: selected ? Colors.transparent : DshColors.line,
              width: 1,
            ),
            boxShadow: selected ? DshColors.accentShadow : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: selected ? DshColors.onAccent : DshColors.textDim,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// 文件类型角标：pdf / docx / pptx / html / md …
///
/// 设计稿的资料库与产物列表都用「彩色小方块 + 扩展名」表示类型。
class DshFileTypeBadge extends StatelessWidget {
  const DshFileTypeBadge({super.key, required this.extension});

  final String extension;

  /// 按扩展名给一个稳定的颜色（同类型永远同色，便于扫读）。
  static Color colorFor(String ext) {
    switch (ext.toLowerCase()) {
      case 'pdf':
        return const Color(0xFFE06C6C);
      case 'doc':
      case 'docx':
        return const Color(0xFF5B8DEF);
      case 'ppt':
      case 'pptx':
        return const Color(0xFFE0934D);
      case 'xls':
      case 'xlsx':
      case 'csv':
        return const Color(0xFF4ED08A);
      case 'html':
        return const Color(0xFFD0714D);
      case 'md':
      case 'markdown':
        return const Color(0xFF9AA5B1);
      case 'json':
        return const Color(0xFFC9A227);
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'webp':
        return const Color(0xFF8E6CE0);
      default:
        return DshColors.textDim;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = colorFor(extension);
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
        border: Border.all(color: c.withValues(alpha: 0.5), width: 0.8),
      ),
      child: Text(
        extension.toUpperCase(),
        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: c),
      ),
    );
  }
}

/// 区块小标题（「我的项目」「产物」这类）。
class DshSectionLabel extends StatelessWidget {
  const DshSectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          text,
          style: TextStyle(
            color: DshColors.text,
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// 把带 `**粗体**` 与 `` `代码` `` 标记的文案渲染成**富文本**（审计 P1-6）。
///
/// ## 为什么需要它
///
/// 更新说明那 50 条记录的正文里，非注释部分有 **1082 处 `**`（541 对）与
/// 548 处反引号**，而渲染它们是普通 `Text` —— 于是用户在界面上看到的是
/// **裸星号**：`**为什么以前没暴露**：…`。50 条里有 45 条中招。
///
/// 对照（说明仓库本来就有正确姿势）：**模型输出**走的是 `flutter_markdown`
/// （见 message_stream），所以"模型说的 `**` 是粗体、App 自己写的 `**` 是星号"
/// —— 同一个界面里两套排版。
///
/// ## 为什么自己写 15 行而不是引 flutter_markdown
///
/// 这里只需要两种标记。引入整套 Markdown 解析器会把大量规则带进**渲染热路径**
/// （还有 XSS 式的样式面），而我们只想要"星号变成粗体"。
/// 渲染点只有更新说明页那几处，自己切足够，也好解释。
///
/// ⚠️ 认不出来的标记**原样显示**（不吞字符）—— 宁可看到 `**` 也不要把用户的
/// 文字吃掉。
class DshRichText extends StatelessWidget {
  const DshRichText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow = TextOverflow.clip,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;

  /// `**粗体**` 或 `` `代码` ``（非贪婪，先匹配到的先生效）。
  ///
  /// ⚠️ 两条 `(?<!\*)(?!\*)` 是必需的：文案里有 `***已脱敏***` 这种
  /// **星号本身就是内容**的写法（脱敏占位符）。不加这两条，它会被切成
  /// "粗体 + 一个漏出来的星号"，用户看到的就是错字 —— 这一条是写测试时
  /// 拿真实文案试出来的（`send_log_button` 里那句）。
  static final RegExp _marker =
      RegExp(r'(?<!\*)\*\*(?!\*)(.+?)(?<!\*)\*\*(?!\*)|`([^`]+)`');

  @override
  Widget build(BuildContext context) {
    final base = style ?? TextStyle(color: DshColors.text, fontSize: 12.5, height: 1.6);
    final spans = <TextSpan>[];
    var at = 0;
    for (final m in _marker.allMatches(text)) {
      if (m.start > at) {
        spans.add(TextSpan(text: text.substring(at, m.start)));
      }
      final bold = m.group(1);
      final code = m.group(2);
      if (bold != null) {
        spans.add(TextSpan(
          text: bold,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ));
      } else if (code != null) {
        spans.add(TextSpan(
          text: code,
          style: DshFonts.code(
            color: base.color ?? DshColors.text,
            fontSize: (base.fontSize ?? 12.5) - 0.5,
          ),
        ));
      }
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    // 一个标记都没有时也要走 Text.rich（保持一致的行高/换行行为）。
    if (spans.isEmpty) spans.add(TextSpan(text: text));

    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
