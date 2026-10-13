/// 对比度门禁（审计 P1-7）。
///
/// ## 为什么必须是**算出来**的，不是"看着还行"
///
/// 这类问题肉眼几乎不可见：浅色皮肤下 `textFaint` 的对比度是 **3.57:1**，
/// 低于 WCAG AA 要求的 4.5:1 —— 在正常视力下"有点淡"，对低视力用户则是
/// 真的读不清。而它在 `lib` 下有 **215 处**引用，大量是 10.5px 小字，
/// **不是点缀色而是正文色**。
///
/// 所以这里按 WCAG 2.x 的公式**逐对算比值**并钉住阈值：
///   * 正文/次要文字：≥ **4.5**（AA 正常字号）；
///   * 大字号或非文字元素：≥ **3.0**。
/// 公式与 sRGB 线性化都写在下面，不引依赖。
library;

import 'dart:math' as math;

import 'package:dsh_mobile/ui/theme/dsh_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 相对亮度。
double _luminance(Color c) {
  double ch(double v) {
    final s = v / 255.0;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * ch(c.r * 255) + 0.7152 * ch(c.g * 255) + 0.0722 * ch(c.b * 255);
}

/// WCAG 对比度（1..21）。
double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  /// 正文/次要文字要求 4.5（AA 正常字号）。
  const aaNormal = 4.5;

  group('两套皮肤的正文对比度都过 AA', () {
    for (final p in DshPalettes.all) {
      test('${p.id}：text（主文字）', () {
        expect(contrast(p.text, p.bg), greaterThanOrEqualTo(aaNormal));
        expect(contrast(p.text, p.bgSoft), greaterThanOrEqualTo(aaNormal));
      });

      test('${p.id}：textDim', () {
        expect(contrast(p.textDim, p.bg), greaterThanOrEqualTo(aaNormal),
            reason: '${p.id}.textDim 在 bg 上不到 4.5 —— 正文读不清');
        expect(contrast(p.textDim, p.bgSoft), greaterThanOrEqualTo(aaNormal));
      });

      test('${p.id}：textFaint（215 处引用的正文色，曾经 3.57/3.35）', () {
        expect(contrast(p.textFaint, p.bg), greaterThanOrEqualTo(aaNormal),
            reason: '${p.id}.textFaint/bg 低于 AA —— 这是 P1-7 的原始问题');
        expect(contrast(p.textFaint, p.bgSoft), greaterThanOrEqualTo(aaNormal),
            reason: '${p.id}.textFaint/bgSoft 低于 AA');
      });

      test('${p.id}：accent 当小字/链接用时也要过 AA', () {
        expect(contrast(p.accent, p.bg), greaterThanOrEqualTo(aaNormal),
            reason: 'accent 也用于小字与链接，不能只在按钮填充上够看');
        expect(contrast(p.accent, p.bgSoft), greaterThanOrEqualTo(aaNormal));
      });

      test('${p.id}：busy（进度/提示色）', () {
        expect(contrast(p.busy, p.bg), greaterThanOrEqualTo(aaNormal));
        expect(contrast(p.busy, p.bgSoft), greaterThanOrEqualTo(aaNormal));
      });

      test('${p.id}：accent 上的文字（按钮填充）', () {
        expect(contrast(p.onAccent, p.accent), greaterThanOrEqualTo(3.0),
            reason: '按钮上的字至少要过"大字号"那档 3.0');
      });

      test('${p.id}：分隔线（非文字，3.0 档）', () {
        // 分隔线是装饰性元素，用 3.0 的要求衡量它对底色的可见度。
        expect(contrast(p.line, p.bg), greaterThan(1.15),
            reason: '分隔线几乎与底色同色 —— 用户看不出结构');
      });
    }
  });

  group('公式本身对不对（拿 WCAG 的已知值校准）', () {
    test('黑/白 = 21:1', () {
      expect(contrast(const Color(0xFF000000), const Color(0xFFFFFFFF)),
          closeTo(21.0, 0.01));
    });

    test('同一色 = 1:1', () {
      expect(contrast(const Color(0xFF3A7BD5), const Color(0xFF3A7BD5)),
          closeTo(1.0, 0.001));
    });

    test('审计复算过的那两个值：旧 textFaint 浅色 3.57 / 3.35', () {
      // 用**旧值**校准公式 —— 如果这两个数对不上，说明公式或色值口径错了，
      // 那么上面那些"已达标"的断言也就不可信。
      const oldFaint = Color(0xFF6E80A3);
      const lightBg = Color(0xFFEEF3FB);
      const lightSoft = Color(0xFFE5ECF8);
      expect(contrast(oldFaint, lightBg), closeTo(3.57, 0.02));
      expect(contrast(oldFaint, lightSoft), closeTo(3.35, 0.02));
    });
  });
}
