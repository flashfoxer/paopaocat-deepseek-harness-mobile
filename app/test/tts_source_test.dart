/// 配音来源的测试（**默认必须是手机自带的 TTS**）。
///
/// ## 为什么这件事必须钉住
///
/// 这个 App 是给**网友**用的。最初的实现把配音写死成 MiMo（小米）—— 结果就是
/// "没注册过 MiMo 的人用不了口播/短剧"。所以现在：
///   * 默认 [TtsSource.system]（手机自带、零配置、免费）；
///   * MiMo 只是可选升级，而且界面上写清"需要 Key"；
///   * 系统 TTS 的每种失败都要给出**可执行的下一步**（装语音包 / 换 MiMo），
///     不能只说一句"配音失败"。
library;

import 'dart:io';

import 'package:dsh_mobile/data/tts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dsh/native');
  late List<String> calls;

  void mockNative(String Function(String method, Map<dynamic, dynamic> args) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?)?.cast<dynamic, dynamic>() ??
          <dynamic, dynamic>{};
      calls.add('${call.method}:${args['path'] ?? ''}');
      return handler(call.method, args);
    });
  }

  setUp(() => calls = <String>[]);
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('默认来源就是系统 TTS（不是 MiMo）', () {
    // 默认值写在这里是为了"改默认值时必须有意识地改测试"
    expect(TtsSource.system.index, 0);
  });

  test('系统 TTS 成功 → 路由到 ttsToFile 且返回文件与字节数', () async {
    final tmp = Directory.systemTemp.createTempSync('dsh-tts-');
    final out = '${tmp.path}/a.wav';
    mockNative((method, args) {
      expect(method, 'ttsToFile');
      expect(args['text'], '你好');
      // 原生侧会写文件，这里模拟它
      File(args['path'] as String).writeAsBytesSync(List<int>.filled(1200, 1));
      return 'ok';
    });
    final r = await synthesizeSpeech(text: '你好', outPath: out);
    expect(r.ok, isTrue, reason: r.error);
    expect(r.file, out);
    expect(r.bytes, 1200);
    expect(calls.single.startsWith('ttsToFile:'), isTrue);
    tmp.deleteSync(recursive: true);
  });

  test('没装中文语音数据 → 给出"怎么办"（装语音包 或 改 MiMo）', () async {
    mockNative((m, a) => 'no_lang');
    final r = await synthesizeSpeech(
        text: '你好', outPath: '${Directory.systemTemp.path}/x.wav');
    expect(r.ok, isFalse);
    expect(r.error, contains('中文语音'), reason: '要说清是缺中文语音包：${r.error}');
    expect(r.error, contains('MiMo'), reason: '要给出替代方案：${r.error}');
  });

  test('没有 TTS 引擎 → 同样要说清替代方案', () async {
    mockNative((m, a) => 'no_engine');
    final r = await synthesizeSpeech(text: '你好', outPath: '/tmp/x.wav');
    expect(r.ok, isFalse);
    expect(r.error, contains('引擎'));
    expect(r.error, contains('MiMo'));
  });

  test('写了空文件 → 当失败（不能把 0 字节的 wav 当成功）', () async {
    mockNative((m, a) {
      File(a['path'] as String).writeAsBytesSync(<int>[]);
      return 'ok';
    });
    final r = await synthesizeSpeech(
        text: '你好', outPath: '${Directory.systemTemp.path}/empty.wav');
    expect(r.ok, isFalse);
    expect(r.error, contains('空文件'));
  });

  test('选了 MiMo 但没配 Key → 明确让人去设置里填（而不是静默失败）', () async {
    // 安全区没有 mock → read 会抛，read 内部已 catch 成 null → 走"没配 Key"分支
    final r = await synthesizeSpeech(
      text: '你好',
      outPath: '${Directory.systemTemp.path}/m.wav',
      source: TtsSource.mimo,
    );
    expect(r.ok, isFalse);
    expect(r.error, contains('MiMo'));
    expect(r.error, contains('设置'), reason: '要告诉用户去哪填：${r.error}');
  });

  test('每一种系统返回码都有对应的中文（不许漏成空串）', () {
    for (final code in <String>[
      'no_engine', 'no_lang', 'no_text', 'bad_path', 'error:timeout', 'error:synth_failed_1',
    ]) {
      final msg = systemTtsMessage(code);
      expect(msg, isNotEmpty, reason: '$code 没有对应文案');
      expect(msg, isNot(contains('null')));
    }
    expect(systemTtsMessage('ok'), isEmpty);
  });
}
