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
  const DshGridPainter({
    this.glowColor,
    this.scanlines = false,
    this.scanlineColor,
  });

  /// 柔光颜色。为 null 时读当前皮肤的 `DshColors.bgGlow`。
  final Color? glowColor;

  /// 是否叠一层**扫描线**（CRT 那种横向细纹）。
  ///
  /// 只有像素/终端皮肤打开（见 `DshPalette.pixelStyle`）—— 用户 2026-10-15
  /// 第 6 条要的是"大变样子"，一层细密横纹是隔着屏幕都能立刻看出来的差别，
  /// 而且不像网格线那样抢正文（线距 3dp、透明度 4%，远看是质感不是线条）。
  ///
  /// ⚠️ 别把它调成全局：默认皮肤是"干净的近黑底 + 柔光"（用户当年明确否掉了
  /// 网格线，见本文件顶部），扫描线只属于像素皮肤。
  final bool scanlines;

  /// 扫描线颜色；为 null 时用当前皮肤的 `line` 再降透明度。
  final Color? scanlineColor;

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

    if (!scanlines) return;
    final line = (scanlineColor ?? DshColors.line).withValues(alpha: 0.05);
    final lp = Paint()
      ..color = line
      ..strokeWidth = 1;
    // 3dp 一条：比 1dp 密纹更省（真机上看不出来差别），也比网格"更像屏幕"。
    for (var y = 0.0; y < size.height; y += 3) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), lp);
    }
  }

  @override
  bool shouldRepaint(covariant DshGridPainter old) =>
      old.glowColor != glowColor ||
      old.scanlines != scanlines ||
      old.scanlineColor != scanlineColor;
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
    this.scanlines = false,
    this.scanlineColor,
  });

  /// 当前皮肤的底色。
  final Color bgColor;

  /// 当前皮肤的柔光色。
  final Color glowColor;

  /// 像素皮肤：叠一层扫描线（见 [DshGridPainter.scanlines]）。
  final bool scanlines;

  /// 扫描线颜色（与 [bgColor] 同理，**必须在 build 时传入**）。
  final Color? scanlineColor;

  @override
  Widget build(BuildContext context) {
    // ⚠️ 颜色**必须由调用方在 build 时传入**，不要在 paint 里现读 `DshColors`：
    // 否则新旧 painter 读到的永远是新值，`shouldRepaint` 比较恒等、换肤后
    // 背景层不会重绘（历史上踩过同类坑）。
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _BgPainter(
            bgColor: bgColor,
            glowColor: glowColor,
            scanlines: scanlines,
            scanlineColor: scanlineColor,
          ),
          isComplex: false,
        ),
      ),
    );
  }
}

class _BgPainter extends CustomPainter {
  const _BgPainter({
    required this.bgColor,
    required this.glowColor,
    this.scanlines = false,
    this.scanlineColor,
  });

  final Color bgColor;
  final Color glowColor;
  final bool scanlines;
  final Color? scanlineColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bgColor);
    DshGridPainter(
      glowColor: glowColor,
      scanlines: scanlines,
      scanlineColor: scanlineColor,
    ).paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _BgPainter old) =>
      old.bgColor != bgColor ||
      old.glowColor != glowColor ||
      old.scanlines != scanlines ||
      old.scanlineColor != scanlineColor;
}
