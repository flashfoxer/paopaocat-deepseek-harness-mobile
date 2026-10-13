import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';

/// 品牌 logo（**只用于 App 内首页那一处**）：泡泡猫的小白猫。
///
/// ⚠️ 桌面图标与 App 内 logo 用的是**两张不同的图**（用户明确要求，别再统一）：
///
/// | 去处 | 用哪张 |
/// |---|---|
/// | 桌面 / 启动器图标、自适应图标 | `design/launcher-icon-source.png`（来自 `paopaocat.ico` 的圆角徽章） |
/// | **App 内首页 logo** | **这只小白猫**（`mascot-cat.webp` 的抠图） |
///
/// 用户原话：「首页欢迎来到泡泡猫的DSH上边的图标还是换回小白猫，就这一个地方换就可以了」。
///
/// 两张图都由 `install/make-icon.py` 生成，换图请改那个脚本并重跑，
/// **不要**在这里手绘第二个 logo。
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 70});

  final double size;

  /// APK 内放的这一份位图（398×336 的抠图，宽大于高）。
  static const String assetPath = 'assets/images/paopaocat_mascot.png';

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        assetPath,
        // 卧猫是横向的，contain 之后实际绘制高度约 size * 336 / 398
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        semanticLabel: context.tr('泡泡猫'),
      ),
    );
  }
}
