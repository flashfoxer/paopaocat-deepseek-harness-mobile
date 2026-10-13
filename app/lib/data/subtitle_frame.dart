import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;

/// 把「一张底图 + 一句字幕」渲染成 PNG —— **字幕由 App 画，不由 ffmpeg 烧**。
///
/// ## 为什么是 App 画（这不是偷懒，是构建决定）
///
/// 随包的 ffmpeg 里**没有** `subtitles` / `drawtext` / `ass` 滤镜 ——
/// NDK 里没有 libass / freetype / harfbuzz，编不进去（已实测：`ffmpeg -filters`
/// 里这三条都不存在）。所以字幕只能自己画。好处反而更多：
///   * 用**手机自带的中文字体**，不用像桌面端那样到处找字体、也不用处理"缺字体"的报错；
///   * 样式（位置、字号、描边、底色）完全可控，不需要懂 ASS 语法；
///   * 在 Flutter 里画 = 能写测试（这一层是纯 Dart 绘制，headless 下也能出图）。
///
/// 产出的 PNG 交给 `make-narration.mjs` 与配音一起合成，见那个脚本的说明。
class SubtitleFrameRenderer {
  SubtitleFrameRenderer._();

  /// 渲染一帧。成功返回写出的文件路径；失败返回 null（并打日志）。
  ///
  /// * [imagePath] 为 null/不存在时 → 用**纯深色底**（口播没选形象图时用）。
  /// * [text] 会自动换行；`fontScale` 是字号相对画幅高度的比例。
  static Future<String?> render({
    String? imagePath,
    required String text,
    required int width,
    required int height,
    required String outPath,
    double fontScale = 0.042,
    bool showSubtitle = true,
  }) async {
    try {
      ui.Image? base;
      if (imagePath != null && imagePath.isNotEmpty) {
        final f = File(imagePath);
        if (f.existsSync()) {
          final codec = await ui.instantiateImageCodec(await f.readAsBytes());
          final frame = await codec.getNextFrame();
          base = frame.image;
        }
      }
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder,
          ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));

      // ① 底：把图按 "cover" 铺满（不留黑边），没有图就铺一个深灰渐变底
      final full = ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      if (base != null) {
        final scale = (width / base.width) > (height / base.height)
            ? width / base.width
            : height / base.height;
        final dw = base.width * scale;
        final dh = base.height * scale;
        canvas.drawImageRect(
          base,
          ui.Rect.fromLTWH(0, 0, base.width.toDouble(), base.height.toDouble()),
          ui.Rect.fromLTWH((width - dw) / 2, (height - dh) / 2, dw, dh),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
      } else {
        canvas.drawRect(
          full,
          ui.Paint()
            ..shader = ui.Gradient.linear(
              full.topCenter,
              full.bottomCenter,
              <ui.Color>[const ui.Color(0xFF1B1B22), const ui.Color(0xFF0D0D12)],
            ),
        );
      }

      // ② 字幕：底部一条半透明底 + 居中白字（加一点描边阴影，浅色画面也读得清）
      if (showSubtitle && text.trim().isNotEmpty) {
        final fontSize = (height * fontScale).clamp(18.0, 96.0);
        final para = _buildParagraph(
          text: text.trim(),
          fontSize: fontSize,
          maxWidth: width * 0.86,
        );
        final barHeight = para.height + fontSize * 1.5;
        final barTop = height - barHeight;
        canvas.drawRect(
          ui.Rect.fromLTWH(0, barTop, width.toDouble(), barHeight),
          ui.Paint()
            ..shader = ui.Gradient.linear(
              ui.Offset(0, barTop),
              ui.Offset(0, height.toDouble()),
              <ui.Color>[const ui.Color(0x00000000), const ui.Color(0xB3000000)],
            ),
        );
        canvas.drawParagraph(
          para,
          ui.Offset((width - width * 0.86) / 2, barTop + fontSize * 0.7),
        );
      }

      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      picture.dispose();
      image.dispose();
      base?.dispose();
      if (bytes == null) {
        debugPrint('[dsh-frame] toByteData 返回空');
        return null;
      }
      final out = File(outPath);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(bytes.buffer.asUint8List());
      return outPath;
    } catch (e, st) {
      debugPrint('[dsh-frame] 渲染字幕帧失败：$e\n$st');
      return null;
    }
  }

  /// 造一段可自动换行、居中、带阴影的文本。
  static ui.Paragraph _buildParagraph({
    required String text,
    required double fontSize,
    required double maxWidth,
  }) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: ui.TextAlign.center,
      fontSize: fontSize,
      maxLines: 4,
      // 用系统默认字体族（手机上就是中文字体）；显式给字体名反而可能找不到。
      ellipsis: '…',
    ))
      ..pushStyle(ui.TextStyle(
        color: const ui.Color(0xFFFFFFFF),
        fontSize: fontSize,
        height: 1.25,
        fontWeight: ui.FontWeight.w600,
        // 阴影让白字压在浅色画面上也清楚
        shadows: <ui.Shadow>[
          ui.Shadow(
            color: const ui.Color(0xCC000000),
            blurRadius: fontSize * 0.18,
            offset: ui.Offset(0, fontSize * 0.05),
          ),
        ],
      ))
      ..addText(text);
    return builder.build()..layout(ui.ParagraphConstraints(width: maxWidth));
  }
}

/// 便于测试：把 PNG 的宽高读出来（不引第三方图片库，直接解 PNG 头）。
({int width, int height})? pngSize(Uint8List bytes) {
  if (bytes.length < 24) return null;
  // PNG 签名
  const sig = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < sig.length; i++) {
    if (bytes[i] != sig[i]) return null;
  }
  int be32(int off) =>
      (bytes[off] << 24) | (bytes[off + 1] << 16) | (bytes[off + 2] << 8) | bytes[off + 3];
  return (width: be32(16), height: be32(20));
}
