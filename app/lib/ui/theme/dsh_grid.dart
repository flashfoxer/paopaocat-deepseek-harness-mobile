import 'package:flutter/material.dart';

import 'dsh_tokens.dart';

/// 背景层（**不再是网格**）。
///
/// ## 为什么撤掉网格
///
/// 之前版本在底色上画了一层网格线（28px 格、3.5% 透明度，后来调到 7.5%）。
/// 用户实测反馈「网格线实在是不好看」—— 它既显得廉价，又会和正文抢注意力。
///
/// ## 深色背景的通行做法
///
/// 深色设计指南的共识有两条（见 Muzli《Dark Mode Design Systems》等）：
///   1. **纯黑 #000000 会造成眼疲劳**，应使用**近黑**（#0A0A0A ~ #161616）；
///   2. **层次不能靠阴影** —— 深色阴影叠在深色底上没有对比、信号直接消失，
///      要靠**亮度分级**（Material 的 "tonal elevation"）。
///
/// Linear / Arc / Raycast / Warp 这些深色优先的产品都是这个路子：
/// 干净的底 + 极克制的亮度过渡。所以这里只做两件事：
///
///   1. 铺一层底色（[DshGridBackground.bgColor]）；
///   2. 从屏幕**上方**往下扩散一层很淡的柔光（`glowColor`），让"上亮下沉"，
///      画面因此有纵深，而不是一块死黑。
///
/// 不再有任何线条、纹理或噪点。
class DshGridPainter extends CustomPainter {
  const DshGridPainter({this.glowColor});

  /// 柔光颜色。为 null 时读当前皮肤的 `DshColors.bgGlow`。
  final Color? glowColor;

  @override
  void paint(Canvas canvas, Size size) {
    // 圆心放在屏幕**上方之外**、半径大于屏幕 —— 可见区域只落到渐变的上半段，
    // 于是形成"自顶向下逐渐沉下去"的过渡（类似室内顶部打光）。
    final glow = glowColor ?? DshColors.bgGlow;
    final paint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, -1.15),
        radius: 1.35,
        colors: <Color>[
          glow.withValues(alpha: 0.90),
          glow.withValues(alpha: 0.35),
          glow.withValues(alpha: 0.0),
        ],
        stops: const <double>[0.0, 0.45, 1.0],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant DshGridPainter old) =>
      old.glowColor != glowColor;
}

/// 背景层：先铺底色，再叠一层自上而下的柔光。
///
/// 放在内容**下面**（不是水印）：卡片、输入区这些实底色的地方仍然干净，
/// 只有页面空白处能看到那层过渡。
class DshGridBackground extends StatelessWidget {
  const DshGridBackground({
    super.key,
    required this.bgColor,
    required this.glowColor,
  });

  /// 当前皮肤的底色。
  final Color bgColor;

  /// 当前皮肤的柔光色。
  final Color glowColor;

  @override
  Widget build(BuildContext context) {
    // ⚠️ 颜色**必须由调用方在 build 时传入**，不要在 paint 里现读 `DshColors`：
    // 否则新旧 painter 读到的永远是新值，`shouldRepaint` 比较恒等、换肤后
    // 背景层不会重绘（历史上踩过同类坑）。
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _BgPainter(bgColor: bgColor, glowColor: glowColor),
          isComplex: false,
        ),
      ),
    );
  }
}

class _BgPainter extends CustomPainter {
  const _BgPainter({required this.bgColor, required this.glowColor});

  final Color bgColor;
  final Color glowColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bgColor);
    DshGridPainter(glowColor: glowColor).paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _BgPainter old) =>
      old.bgColor != bgColor || old.glowColor != glowColor;
}
