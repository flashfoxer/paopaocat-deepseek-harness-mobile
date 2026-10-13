/// 口播/短剧的两个"自研零件"的测试：
///   * [NarrationSegmenter] —— 文稿怎么切段（照桌面端插件那份真实规则实现）；
///   * [SubtitleFrameRenderer] —— 字幕帧渲染（**字幕由 App 画**，因为随包 ffmpeg
///     里没有 subtitles/drawtext 滤镜）。
///
/// 后者在 headless 下也真能出图：它是纯 `dart:ui` 绘制，不依赖窗口或 GPU 后端。
/// ⚠️ 测试环境的字体与手机不同（可能没有中文字形），所以这里断言的是
/// **产出了正确尺寸的 PNG**，而不是"字形画对了没"。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_mobile/data/subtitle_frame.dart';
import 'package:dsh_mobile/data/tts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('dsh-narration-');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('文稿分段（口播要先切段，每段配一段音）', () {
    test('按句末标点切，太短的碎片并进上一段', () {
      final segs = NarrationSegmenter.split('今天讲三件事。第一件很重要！第二件也不小？');
      expect(segs.length, greaterThanOrEqualTo(1));
      // 每段都不超过上限
      for (final s in segs) {
        expect(s.length, lessThanOrEqualTo(NarrationSegmenter.maxChars),
            reason: '超长的段会一行放不下：$s');
      }
      // 合起来要包含原文的关键内容（不丢字）
      final joined = segs.join();
      for (final k in <String>['今天讲三件事', '第一件很重要', '第二件也不小']) {
        expect(joined.contains(k), isTrue, reason: '切段把「$k」弄丢了');
      }
    });

    test('短句会被合并（避免一句一停、听感很跳）', () {
      // 四个很短的句子，按"最短 1.6 秒 ≈ 6.7 字"应该被并起来
      final segs = NarrationSegmenter.split('好。行。可以。没问题。');
      expect(segs.length, lessThan(4),
          reason: '短句必须合并，否则 TTS 会一句一停：$segs');
    });

    test('超长的句子按逗号再切（在停顿处断，不硬切字）', () {
      final long = '${'这是一句很长的话' * 8}，${'后面还有很长的一段' * 8}。';
      final segs = NarrationSegmenter.split(long);
      expect(segs.length, greaterThan(1));
      for (final s in segs) {
        expect(s.length, lessThanOrEqualTo(NarrationSegmenter.maxChars));
      }
    });

    test('换行也算分段边界（用够长的两行，避免被"合并短句"并掉）', () {
      final segs = NarrationSegmenter.split(
          '这是第一行的内容，写长一点让它自己就够一段。\n这是第二行的内容，同样写长一点。');
      expect(segs.length, greaterThanOrEqualTo(2),
          reason: '换行应当成为分段边界（但如果两行都很短，会被有意合并）');
    });

    test('空文本 / 只有空白 → 空列表（不是 [""]）', () {
      expect(NarrationSegmenter.split(''), isEmpty);
      expect(NarrationSegmenter.split('   \n  '), isEmpty);
    });
  });

  group('字幕帧渲染（App 画字幕，替代 ffmpeg 的 subtitles/drawtext）', () {
    test('有底图：产出 1080x1920 的 PNG', () async {
      // 造一张 320x240 的"底图"（PNG 头 + 占位数据即可，渲染器只当它是图）
      final img = File('${tmp.path}/base.png');
      await _writeTinyPng(img, 320, 240);
      final out = '${tmp.path}/frame.png';
      final r = await SubtitleFrameRenderer.render(
        imagePath: img.path,
        text: '这是一句字幕，用来验证它真的被渲染出来了。',
        width: 1080,
        height: 1920,
        outPath: out,
      );
      expect(r, out, reason: '应该渲染成功并返回路径');
      final bytes = File(out).readAsBytesSync();
      expect(bytes.length, greaterThan(1000), reason: '不该是空文件');
      final size = pngSize(bytes);
      expect(size, isNotNull);
      expect(size!.width, 1080);
      expect(size.height, 1920);
    });

    test('没有底图（口播没选形象图）→ 用纯色底，照样出图', () async {
      final out = '${tmp.path}/nobase.png';
      final r = await SubtitleFrameRenderer.render(
        text: '没有形象图也要能出片。',
        width: 720,
        height: 1280,
        outPath: out,
      );
      expect(r, out);
      final size = pngSize(File(out).readAsBytesSync());
      expect(size!.width, 720);
      expect(size.height, 1280);
    });

    test('底图路径不存在 → 按"没有底图"处理，而不是抛异常', () async {
      final out = '${tmp.path}/missing.png';
      final r = await SubtitleFrameRenderer.render(
        imagePath: '${tmp.path}/does-not-exist.png',
        text: '底图丢了也别崩。',
        width: 480,
        height: 480,
        outPath: out,
      );
      expect(r, out, reason: '路径不存在应该退化成纯色底，不是失败');
      expect(File(out).existsSync(), isTrue);
    });

    test('字幕关闭时不画字（纯画面帧）', () async {
      final out = '${tmp.path}/nosub.png';
      final r = await SubtitleFrameRenderer.render(
        text: '这段不该出现',
        width: 320,
        height: 320,
        outPath: out,
        showSubtitle: false,
      );
      expect(r, out);
      expect(pngSize(File(out).readAsBytesSync())!.width, 320);
    });
  });

  group('MiMo 端点的两档路由（实测契约：套餐 Key 以 tp- 开头）', () {
    test('普通 Key 走标准端点，tp- 走套餐端点', () {
      expect(mimoBaseUrlFor('sk-abc'), kMimoUrl);
      expect(mimoBaseUrlFor('tp-abc'), kMimoTokenPlanUrl);
      expect(mimoBaseUrlFor('  tp-abc  '), kMimoTokenPlanUrl);
    });
  });
}

/// 造一张真实的小 PNG 当"底图"（用 dart:ui 编码，避免手写压缩数据）。
Future<void> _writeTinyPng(File dest, int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366CC),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await dest.writeAsBytes(bytes!.buffer.asUint8List());
}
