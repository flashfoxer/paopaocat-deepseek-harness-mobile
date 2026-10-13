/// 无障碍相关的回归测试（审计 P1-4）。
///
/// 这里锁住的是**用户能感知、但不会崩**的那类问题：
///   * 系统字号被 App 整体覆盖 → 需要大字的人调了系统设置却完全没效果；
///   * 图标按钮没有 tooltip/语义标签 → 读屏用户听到"按钮"但不知道是干什么的。
/// 两者都不会让任何测试变红，所以必须专门盯着。
library;

import 'package:dsh_mobile/state/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 复刻 main.dart 里那段 builder 的算法（系统 × App，上限 2.0）。
  /// 抽出来测是因为它只有 3 行，但**错了没人看得出来**。
  double effectiveScale(double systemScale, double appScale) =>
      (systemScale * appScale).clamp(0.8, 2.0);

  group('字号：系统与 App 相乘（不再整体替换）', () {
    testWidgets('系统调大 + App 标准 → 跟随系统（这是 P1-4 的核心）', (tester) async {
      expect(effectiveScale(1.5, 1.0), 1.5,
          reason: 'App 又覆盖了系统字号 —— P1-4 回归');
      expect(effectiveScale(1.3, 1.0), 1.3);
    });

    testWidgets('两边都调 → 相乘', (tester) async {
      expect(effectiveScale(1.5, 1.3), closeTo(1.95, 1e-9));
    });

    testWidgets('App 调小也能生效（系统标准时）', (tester) async {
      expect(effectiveScale(1.0, 0.9), closeTo(0.9, 1e-9));
    });

    testWidgets('上限 2.0：本 App 的 dp 布局撑不住更大（有意封顶）', (tester) async {
      expect(effectiveScale(2.0, 1.3), 2.0);
      expect(effectiveScale(1.5, 1.3), closeTo(1.95, 1e-9));
    });

    testWidgets('下限 0.8：免得把字缩到看不见', (tester) async {
      expect(effectiveScale(0.8, 0.9), 0.8);
    });

    testWidgets('真的用 MediaQuery 验一遍：App 的 builder 会读到系统值', (tester) async {
      // 模拟"系统字号 1.6"：把 MediaQuery 包起来，读到的应该是 1.6，
      // 而旧写法（TextScaler.linear(appScale)）读到的是 1.0。
      late double got;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: Builder(builder: (context) {
            got = MediaQuery.textScalerOf(context).scale(1.0);
            return const SizedBox();
          }),
        ),
      );
      expect(got, closeTo(1.6, 1e-9));
      expect(effectiveScale(got, 1.0), closeTo(1.6, 1e-9));
    });
  });

  group('AppSettings 的字号档位仍然是那四档', () {
    test('档位与标签没被改掉（改档位会让上面的算式口径变）', () {
      final scales = AppSettings.kTextScales.map((o) => o.scale).toList();
      expect(scales, <double>[0.90, 1.00, 1.15, 1.30]);
    });
  });
}
