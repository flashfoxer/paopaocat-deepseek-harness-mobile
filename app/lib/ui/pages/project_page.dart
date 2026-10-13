import 'package:flutter/material.dart';

import '../theme/dsh_tokens.dart';
import '../widgets/common.dart';

import '../../i18n/dsh_i18n.dart';

/// 项目空间（设计稿 `page-07`）。
///
/// 设计稿结构（y / 屏高，源：`pdf-images/ocr-all.txt` page-07 节）：
///   | 元素 | y | 屏高 |
///   |---|---|---|
///   | 标题 `项目空间` | 200~254 | 7.6%~9.6% |
///   | 副标题 `多人协同，打造超级团队` | 789~829 | 29.9%~31.4% |
///   | 分组 `我的项目` | 968~1022 | 36.7%~38.7% |
///   | 项目卡 1 `陵川那些事` + `最近更新于9小时前` | 1157~1279 | 43.8%~48.4% |
///   | 项目卡 2 `项目新手指引` + `最近更新于 2026-07-11` | 1423~1542 | 53.9%~58.4% |
///
/// 注意副标题的位置：设计稿把它放在**很靠下**的地方（30% 屏高），
/// 离标题有 20% 屏高的空白。上一轮把它紧贴在标题下面，本轮按设计稿拉开。
///
/// 数据来源：设计稿里的两个项目是样例。本地没有项目存储层，所以这里
/// **把这两个项目作为"新手引导"内置**（`项目新手指引` 本身就是引导条目），
/// 并明确标注是样例 —— 不谎称已接入项目后端。
class ProjectPage extends StatelessWidget {
  const ProjectPage({super.key});

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    return Column(
      children: [
        // 皮肤是运行时变量：这里不能 const（const 实例换肤时会被原样复用、颜色不刷新）
        // ignore: prefer_const_constructors
        DshPageHeader(title: context.tr('项目空间')),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              // 标题带底（≈255）→ 副标题顶（789）：534 设计像素 = 20.2% 屏高。
              // 减去标题带自身高度（约 46dp）后剩这么多。
              // 模拟器实测副标题偏高 1.4% 屏高（[657,710] vs 设计 [789,829]），
              // 所以再加 30dp 把它压到设计位置。
              SizedBox(height: screenH * 0.202 - 46 + 30),
              Center(
                child: Text(
                  context.tr('多人协同，打造超级团队'),
                  style: TextStyle(color: DshColors.textDim, fontSize: 13),
                ),
              ),
              // 副标题底 829 → 分组 968：139 设计像素 = 5.3% 屏高。
              // 实测分组偏低 0.7%，收一点。
              SizedBox(height: screenH * 0.040),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: DshMetrics.pagePad),
                child: DshSectionLabel(context.tr('我的项目')),
              ),
              SizedBox(height: screenH * 0.012),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: DshMetrics.pagePad),
                child: Column(
                  children: [
                    // ⚠️ 这两张是**设计稿样例**（页尾自己也说明了"本地项目存储尚未
                    // 接入"）。原来它们还带 onTap，点了只弹「详情页尚未实现」
                    // —— 假数据 + 假入口，两层都在骗人（审计 P1-8）。
                    // 既然数据不是真的，就不该让它看起来能点。
                    _ProjectCard(
                      name: context.tr('陵川那些事'),
                      updatedAt: context.tr('最近更新于 9 小时前'),
                      icon: Icons.photo_album_outlined,
                    ),
                    _ProjectCard(
                      name: context.tr('项目新手指引'),
                      updatedAt: context.tr('最近更新于 2026-07-11'),
                      icon: Icons.menu_book_outlined,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: DshMetrics.pagePad),
                child: Container(
                  padding: const EdgeInsets.all(DshMetrics.cardPad),
                  decoration: BoxDecoration(
                    color: DshColors.surface.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
                    border: Border.all(color: DshColors.divider, width: 0.8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 15, color: DshColors.textFaint),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          context.tr(
                              '本地项目存储尚未接入：上面两条是设计稿样例，用来对齐卡片形态。新建项目后会在本地目录落盘。'),
                          style: TextStyle(
                            color: DshColors.textFaint,
                            fontSize: 11.5,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ],
    );
  }

}

/// 项目卡：设计稿单卡跨 y≈1157~1279（122 设计像素 ≈ 4.6% 屏高 ≈ 42dp 内容）。
/// 卡片之间的间距：卡 1 底 1279 → 卡 2 顶 1423 = 144 设计像素 ≈ 5.5% 屏高。
class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.name,
    required this.updatedAt,
    required this.icon,
  });

  final String name;
  final String updatedAt;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    // 数据是设计稿样例且页面暂无入口 → 不再声明成 button、不再有波纹，
    // 免得读屏用户听到"按钮"却点不出东西（审计 P1-8）。
    return Semantics(
      label: '$name $updatedAt',
      child: Container(
          // 设计稿卡 1 底 1279 → 卡 2 顶 1423 = 144 设计像素 ≈ 60dp 行距。
          // 实测按 46dp 时卡片比设计稿紧，所以放大约 15%。
          margin: EdgeInsets.only(bottom: (screenH * 0.055 - 40).clamp(8, 40)),
          padding: const EdgeInsets.all(DshMetrics.cardPad),
          decoration: BoxDecoration(
            color: DshColors.surface,
            borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
            border: Border.all(color: DshColors.divider, width: 0.8),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: DshColors.accentDim,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
                ),
                child: Icon(icon, size: 19, color: DshColors.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: DshColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      updatedAt,
                      style:
                          TextStyle(color: DshColors.textFaint, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              // 箭头也去掉：它是"点我进去"的暗示，而这页点不出东西。
            ],
          ),
        ),
    );
  }
}
