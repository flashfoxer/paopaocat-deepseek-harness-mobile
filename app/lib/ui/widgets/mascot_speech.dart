import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/mascot_lines.dart';
import '../../i18n/dsh_i18n.dart';
import '../theme/dsh_tokens.dart';
import 'brand_logo.dart';

/// 首页那只猫 + **点一下它会说一句话**（用户 2026-10-15 第 4 条）。
///
/// ## 怎么实现的（以及为什么这么做）
///
/// 气泡用 **Overlay**，不是塞在首页那一列里：
///   * 首页品牌区是**按屏高比例**排的固定高度块（见 `task_home_view.dart` 的
///     `_ScrollBody`），往里塞一个气泡会把下面的内容顶掉、还可能溢出；
///   * Overlay 画在所有内容之上，气泡可以自由地"盖"在标语上，几秒后自己消失。
///
/// ## 行为
///
///   * 点一下 → 按顺序说下一句（**轮换**，不是随机：轮换保证每次点的都不一样，
///     又不会连着两次撞同一句）；
///   * 再说一句会**顶掉**上一句（不会叠成一堆）；
///   * 5 秒后自己消失；气泡也可以点掉。
///
/// 文案本身在 `data/mascot_lines.dart`（本地写死、走 i18n、不发任何请求）。
class MascotSpeech extends StatefulWidget {
  const MascotSpeech({super.key, this.size = 70});

  final double size;

  @override
  State<MascotSpeech> createState() => _MascotSpeechState();
}

class _MascotSpeechState extends State<MascotSpeech> {
  final GlobalKey _anchor = GlobalKey();
  OverlayEntry? _entry;
  Timer? _timer;
  int _tick = 0;

  @override
  void dispose() {
    _timer?.cancel();
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  void _dismiss() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }

  void _speak() {
    _dismiss();
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !mounted) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    final topLeft = box.localToGlobal(Offset.zero);
    final bottom = topLeft.dy + box.size.height;
    final text = mascotLineAt(_tick++);

    _entry = OverlayEntry(
      builder: (ctx) => Positioned(
        left: DshMetrics.pagePad,
        right: DshMetrics.pagePad,
        // 放在猫**下面**：上面是顶栏与状态行，气泡会被挤到屏幕外。
        top: bottom + 4,
        child: _Bubble(text: text, onTap: _dismiss),
      ),
    );
    overlay.insert(_entry!);
    _timer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(_dismiss);
    });
    setState(() {}); // 让 Semantics/测试能看到"正在说话"
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.tr('泡泡猫（点一下它会说话）'),
      child: GestureDetector(
        key: _anchor,
        behavior: HitTestBehavior.opaque,
        onTap: _speak,
        child: BrandLogo(size: widget.size),
      ),
    );
  }
}

/// 那个"对话的样子"的气泡：一只小尾巴 + 圆角块，淡入 + 轻微放大。
class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 小尾巴：一个旋转 45° 的方块，指向上面的猫
            Padding(
              padding: const EdgeInsets.only(left: DshMetrics.pagePad),
              child: Transform.rotate(
                angle: 0.7854,
                child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: DshColors.surfaceStrong,
                      border: Border(
                        top: BorderSide(
                            color: DshColors.accent,
                            width: DshMetrics.borderWidth),
                        left: BorderSide(
                            color: DshColors.accent,
                            width: DshMetrics.borderWidth),
                      ),
                    )),
              ),
            ),
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: -4),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: DshColors.surfaceStrong,
                borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
                border: Border.all(
                    color: DshColors.accent, width: DshMetrics.borderWidth),
                boxShadow: DshColors.panelShadow,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('🐱', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        color: DshColors.text,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
