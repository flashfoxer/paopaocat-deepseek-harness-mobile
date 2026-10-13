/// 「修图 → 去水印」那个框的**位置算法**（纯函数，唯一一份 Dart 实现）。
///
/// ## 为什么单独放一个文件
///
/// 这个框有两处必须**完全一致**：
///   * 界面上**预览里画的那个框**（用户看到的）；
///   * 传给 `edit-image.mjs --delogo x:y:w:h` 的**像素框**（实际被盖住的那块）。
/// 两处不一致的后果很直白：用户以为盖住了水印，其实盖偏了 —— 而他还看不出来
/// （因为预览是对的）。所以算法只留一份、且抽成纯函数，用测试钉住具体数值。
///
/// ⚠️ 脚本那边（`app/assets/toolbox/edit-image.mjs` 的 `boxFromPosition()`）是
/// **同一套算法的 JS 镜像**，`install/test-edit-image.mjs` 与
/// `test/edit_box_test.dart` 用**同一组期望值**分别钉住两边 ——
/// 改了一边，两边的测试都会红。
library;

import 'dart:math' as math;

/// 位置码（与脚本的 `--box` 一致）：
///   * `br` 右下（水印最常见的位置，也是默认）
///   * `bl` 左下 · `tr` 右上 · `tl` 左上
///   * `bottom` 底部通条（左右留边距、横跨整幅 —— 视频底部的字幕水印多是这种）
const List<String> kDelogoPositions = <String>['br', 'bl', 'tr', 'tl', 'bottom'];

/// 算出去水印框（像素）。画面太小（短边 < 8）时返回 null —— 调用方要如实禁用这一项。
///
/// [dx] / [dy] 是用户拖着框微调出来的**像素**偏移（正 = 往右下）。
///
/// 规则（与 JS 侧逐条对应）：
///   1. 框宽 = 画面宽 × [widthPct]%，框高 = 画面高 × [heightPct]%（各有最小 8×6 像素；
///      `bottom` 的高度同样按这个算，宽度改成"整幅减两边距"）；
///   2. 边距 = 短边 × 2%（最少 2 像素）——水印通常贴着边，留一点点比贴死更稳；
///   3. **先收大小、再把位置推进画面内**（`delogo` 要求框完整落在画面里，
///      碰到边缘会直接报错 —— 所以这里要救回来，而不是让用户自己去调）。
({int x, int y, int w, int h})? computeDelogoBox({
  required int imgW,
  required int imgH,
  String pos = 'br',
  double widthPct = 18,
  double heightPct = 8,
  double dx = 0,
  double dy = 0,
}) {
  if (imgW < 8 || imgH < 8) return null;
  final boxW = math.max(8, (imgW * widthPct / 100).round());
  final boxH = math.max(6, (imgH * heightPct / 100).round());
  final m = math.max(2, (math.min(imgW, imgH) * 0.02).round());
  int x;
  int y;
  int w = boxW;
  int h = boxH;
  switch (pos) {
    case 'bl':
      x = m;
      y = imgH - boxH - m;
    case 'tr':
      x = imgW - boxW - m;
      y = m;
    case 'tl':
      x = m;
      y = m;
    case 'bottom':
      x = m;
      w = imgW - 2 * m;
      y = imgH - boxH - m;
    default: // br
      x = imgW - boxW - m;
      y = imgH - boxH - m;
  }
  // 先把大小收进画面（左右/上下各留 1 像素），再把位置推进去。
  w = w.clamp(4, imgW - 2);
  h = h.clamp(4, imgH - 2);
  x = x.clamp(1, imgW - 1 - w);
  y = y.clamp(1, imgH - 1 - h);

  // 用户在预览图上**拖出来的微调**（像素）。位置码给的是"常见位置"的起点，
  // 真正的水印不会正好在那就 —— 所以允许在他拖之后偏移，再收一次边界。
  // （用户 2026-10-11：「去除水印应该是用户自己选择」。）
  x = (x + dx).round().clamp(1, imgW - 1 - w);
  y = (y + dy).round().clamp(1, imgH - 1 - h);
  return (x: x, y: y, w: w, h: h);
}

/// **自由框选**算出来的框（像素）：左上角 + 宽高，都按画面百分比给。
///
/// 与 [computeDelogoBox] 的关系：
///   * 那个是"**常见位置起点** + 拖动偏移"的模型（`pos` + `dx/dy`），
///     用于"点一下右下角"这种快捷起点；
///   * 这个是"**用户在图上直接框/拖出来的矩形**"（用户 2026-10-12：
///     「去水印……只能选择固定位置……用户可以选择照片任意位置进行擦除」）。
///
/// 两条路最后都产出**同一种东西**：像素框 `(x, y, w, h)`，交给
/// `edit-image.mjs --delogo`。所以脚本侧一行都不用改 —— 它本来就只认像素框。
///
/// 收边界的口径与 [computeDelogoBox] **逐条一致**（最小 8×6、左右/上下各留 1 像素），
/// 否则"拖到边上的框"在两套模型之间会跳一下。
({int x, int y, int w, int h})? boxFromRect({
  required int imgW,
  required int imgH,
  required double xPct,
  required double yPct,
  required double wPct,
  required double hPct,
}) {
  if (imgW < 8 || imgH < 8) return null;
  var w = math.max(8, (imgW * wPct / 100).round());
  var h = math.max(6, (imgH * hPct / 100).round());
  // 先收大小（留出 1 像素边），再把左上角推进去 —— 顺序与 computeDelogoBox 相同。
  w = w.clamp(4, imgW - 2);
  h = h.clamp(4, imgH - 2);
  final x = (imgW * xPct / 100).round().clamp(1, imgW - 1 - w);
  final y = (imgH * yPct / 100).round().clamp(1, imgH - 1 - h);
  return (x: x, y: y, w: w, h: h);
}
