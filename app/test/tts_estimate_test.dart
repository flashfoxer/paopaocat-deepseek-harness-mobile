/// `estimateSpeechSeconds` 的行为测试。
///
/// 这个函数只在一个场景里用：**配音拿不到时**（手机没有 TTS 引擎、或云端 Key 不对），
/// 我们仍要把"画面 + 字幕"的片子做出来 —— 而静音镜必须有个时长。
/// 它以前会一律用 3 秒，一句话和一段话都 3 秒，节奏明显不对。
///
/// 为什么值得单测：它是**纯函数**，而且"估得离谱"这件事**不会报错**，
/// 只会让成片的节奏变怪（这种问题在真机上很难复现、也很难归因）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/data/tts.dart';

void main() {
  group('静音镜时长估算（没有配音时用）', () {
    test('空文本给一个兜底值（不是 0，也不是 NaN）', () {
      expect(estimateSpeechSeconds(''), 3);
      expect(estimateSpeechSeconds('   '), 3);
    });

    test('常规中文句子落在合理区间（按 4.5 字/秒 + 标点/收尾）', () {
      // 15 个字、没有标点：15/4.5 + 0.4 ≈ 3.7s
      final s = estimateSpeechSeconds('这是一句十五个字的测试文本');
      expect(s, greaterThan(3.0));
      expect(s, lessThan(4.5));
    });

    test('越长越久（单调）', () {
      final a = estimateSpeechSeconds('短句测试');
      final b = estimateSpeechSeconds('这是一个明显更长的句子，用来验证估算是单调递增的，不应该出现长的反而更短。');
      expect(b, greaterThan(a));
    });

    test('标点比汉字便宜（停顿短于念字）', () {
      // 同样 10 个"字符位"，全是标点的那份必须更短
      final allPunct = estimateSpeechSeconds('，。，。，。，。，。');
      final allHan = estimateSpeechSeconds('天地玄黄宇宙洪荒日月盈昃');
      expect(allPunct, lessThan(allHan));
    });

    test('超长文本钳在上限 12 秒（避免一镜占满整片）', () {
      final long = '很长的一段话。' * 60;
      expect(estimateSpeechSeconds(long), 12.0);
    });

    test('极短文本钳在下限 1.5 秒（避免闪一下就过）', () {
      expect(estimateSpeechSeconds('好'), 1.5);
    });
  });
}
