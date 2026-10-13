/// 去水印框的位置算法（`data/edit_box.dart`）。
///
/// ## 为什么这组数值必须钉死
///
/// 这个框有两处消费者，必须给出**同一个像素框**：
///   * 界面预览里画的那个红框（用户看到的）；
///   * 传给 `edit-image.mjs --delogo x:y:w:h` 的框（真被盖住的那块）。
///
/// 脚本那边是 JS 镜像实现，`install/test-edit-image.mjs` 用**同一组期望值**
/// （320x240 + `br` + 20%/10% → `251,211,64x24`）钉住它。
/// 所以这里改一个数，那边就会红 —— 这正是我们要的。
library;

import 'package:dsh_mobile/data/edit_box.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeDelogoBox', () {
    test('右下角（与脚本测试同一组期望值）：320x240 + 20%/10% → 251,211,64x24', () {
      final box = computeDelogoBox(
          imgW: 320, imgH: 240, pos: 'br', widthPct: 20, heightPct: 10);
      expect(box, isNotNull);
      // 320*20% = 64；240*10% = 24；边距 = 短边 240 的 2% = 5
      //   x = 320-64-5 = 251；y = 240-24-5 = 211
      expect(box!.x, 251);
      expect(box.y, 211);
      expect(box.w, 64);
      expect(box.h, 24);
    });

    test('四个角都贴着对应的那一边，且边距一致', () {
      const w = 1000, h = 500;
      final br = computeDelogoBox(imgW: w, imgH: h, pos: 'br')!;
      final bl = computeDelogoBox(imgW: w, imgH: h, pos: 'bl')!;
      final tr = computeDelogoBox(imgW: w, imgH: h, pos: 'tr')!;
      final tl = computeDelogoBox(imgW: w, imgH: h, pos: 'tl')!;
      final m = (500 * 0.02).round(); // 短边 500 的 2% = 10
      expect(<int>[tl.x, tl.y], <int>[m, m], reason: '左上：两个边距都该是 m');
      expect(<int>[tr.x + tr.w + m, tr.y], <int>[w, m], reason: '右上：右边距也是 m');
      expect(<int>[bl.x, bl.y + bl.h + m], <int>[m, h], reason: '左下：下边距也是 m');
      expect(<int>[br.x + br.w + m, br.y + br.h + m], <int>[w, h],
          reason: '右下：右下角都留 m');
      // 四个角的框大小一致（同一档位只改位置）
      for (final b in <({int x, int y, int w, int h})>[br, bl, tr, tl]) {
        expect(<int>[b.w, b.h], <int>[br.w, br.h]);
      }
    });

    test('底条：横跨整幅（左右各留边距），高度按比例', () {
      final box = computeDelogoBox(
          imgW: 1000, imgH: 500, pos: 'bottom', heightPct: 10)!;
      final m = (500 * 0.02).round();
      expect(box.x, m);
      expect(box.w, 1000 - 2 * m, reason: '底条要横跨整幅（水印常是一整条字幕）');
      expect(box.h, 50, reason: '500×10% = 50');
      expect(box.y + box.h, 500 - m, reason: '贴着底边留 m');
    });

    test('框太大/太靠边 → 收进画面内，绝不产生非法框（delogo 会报错的那种）', () {
      // 小图 + 大比例：这是最容易算出"越界框"的组合
      final cases = <({int imgW, int imgH, String pos})>[
        (imgW: 16, imgH: 16, pos: 'br'),
        (imgW: 64, imgH: 64, pos: 'bottom'),
        (imgW: 100, imgH: 40, pos: 'tr'),
        (imgW: 9, imgH: 9, pos: 'bl'),
      ];
      for (final c in cases) {
        for (final pct in <double>[40, 60]) {
          for (final pos in kDelogoPositions) {
            final b = computeDelogoBox(
                imgW: c.imgW, imgH: c.imgH, pos: pos, widthPct: pct, heightPct: pct);
            expect(b, isNotNull, reason: '$c $pos $pct% 应该给得出框');
            final box = b!;
            expect(box.w >= 4 && box.h >= 4, isTrue,
                reason: '框太小：$box（${c.imgW}x${c.imgH} $pos $pct%）—— delogo 不许');
            expect(box.x >= 1 && box.y >= 1, isTrue, reason: '框越界：$box');
            expect(box.x + box.w <= c.imgW - 1, isTrue, reason: '框右越界：$box');
            expect(box.y + box.h <= c.imgH - 1, isTrue, reason: '框下越界：$box');
          }
        }
      }
    });

    test('画面太小（短边 < 8）→ null，界面据此禁用去水印而不是瞎算', () {
      expect(computeDelogoBox(imgW: 7, imgH: 100), isNull);
      expect(computeDelogoBox(imgW: 100, imgH: 7), isNull);
      expect(computeDelogoBox(imgW: 8, imgH: 8), isNotNull);
    });

    test('不认识的 pos 走右下角（不是崩、也不是乱放）', () {
      final a = computeDelogoBox(imgW: 320, imgH: 240, pos: '不存在');
      final b = computeDelogoBox(imgW: 320, imgH: 240, pos: 'br');
      expect(a!.x, b!.x);
      expect(a.y, b.y);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 2026-10-12 追加：**自由框选**（用户第 3 条）
  //
  // 原话：「影视的去水印功能，只能选择固定位置，我记得以前说过把这个去水印改成
  //        擦除，用户可以选择照片任意位置进行擦除」。
  //
  // 之前只有"起点（右下/左上…）+ 拖动偏移"，尺寸还得靠两根滑杆 —— 位置和大小
  // 都不能在图上直接选。现在加 [boxFromRect]：用户在图上框哪块就是哪块。
  //
  // ⚠️ 它与 [computeDelogoBox] 产出**同一种东西**（像素框），所以脚本侧
  //    （`edit-image.mjs --delogo x:y:w:h`）一行都不用改 —— 它本来就只认像素框。
  //    但**收边界的口径必须一致**，否则"拖到边上的框"在两套模型之间会跳一下。
  // ══════════════════════════════════════════════════════════════════════════
  group('自由框选（用户想擦哪块就框哪块）', () {
    test('框在哪儿就是哪儿 —— 中间偏左上一小块', () {
      final b = boxFromRect(
          imgW: 1000, imgH: 500, xPct: 20, yPct: 10, wPct: 10, hPct: 20);
      expect(b, isNotNull);
      expect(b!.x, 200);
      expect(b.y, 50);
      expect(b.w, 100);
      expect(b.h, 100);
    });

    test('拖到右下角外面 → 收进画面（不会算出一个越界的框）', () {
      final b = boxFromRect(
          imgW: 1000, imgH: 500, xPct: 95, yPct: 95, wPct: 30, hPct: 30);
      expect(b, isNotNull);
      expect(b!.x + b.w, lessThanOrEqualTo(1000));
      expect(b.y + b.h, lessThanOrEqualTo(500));
      expect(b.x, greaterThanOrEqualTo(1));
      expect(b.y, greaterThanOrEqualTo(1));
    });

    test('负数/超大的百分比也不许算出画面外的框', () {
      for (final r in <List<double>>[
        <double>[-50, -50, 10, 10],
        <double>[0, 0, 500, 500],
        <double>[99, 99, 1, 1],
      ]) {
        final b = boxFromRect(
            imgW: 640, imgH: 480,
            xPct: r[0], yPct: r[1], wPct: r[2], hPct: r[3]);
        expect(b, isNotNull);
        expect(b!.x, greaterThanOrEqualTo(1));
        expect(b.y, greaterThanOrEqualTo(1));
        expect(b.x + b.w, lessThanOrEqualTo(640));
        expect(b.y + b.h, lessThanOrEqualTo(480));
        expect(b.w, greaterThanOrEqualTo(4));
        expect(b.h, greaterThanOrEqualTo(4));
      }
    });

    test('画面太小（短边 < 8）→ null，调用方要如实禁用这一项', () {
      expect(boxFromRect(imgW: 7, imgH: 100, xPct: 0, yPct: 0, wPct: 10, hPct: 10),
          isNull);
      expect(boxFromRect(imgW: 8, imgH: 8, xPct: 0, yPct: 0, wPct: 10, hPct: 10),
          isNotNull);
    });

    test('两套模型的**共同不变量**：都不越界、都有最小尺寸', () {
      // ⚠️ 刻意**不**断言两者结果相同 —— 它们的设计就不同：
      //   `computeDelogoBox` 的"起点"会留 2% 边距（水印通常不贴边）；
      //   `boxFromRect` 是用户自己框的，贴边就该允许贴边。
      //   真正必须一致的是"都不越界、都不会算出 0 尺寸"这两条不变量。
      final free = boxFromRect(
          imgW: 800, imgH: 600, xPct: 100, yPct: 100, wPct: 50, hPct: 50);
      final start = computeDelogoBox(
          imgW: 800, imgH: 600, pos: 'br', widthPct: 50, heightPct: 50);
      for (final b in <({int x, int y, int w, int h})>[free!, start!]) {
        expect(b.x, greaterThanOrEqualTo(1));
        expect(b.y, greaterThanOrEqualTo(1));
        expect(b.x + b.w, lessThanOrEqualTo(800));
        expect(b.y + b.h, lessThanOrEqualTo(600));
        expect(b.w, greaterThan(0));
        expect(b.h, greaterThan(0));
      }
    });
  });
}
