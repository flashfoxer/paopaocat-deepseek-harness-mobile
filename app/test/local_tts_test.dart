/// 本机离线配音（B 方案）里**不需要真机、也不需要真模型**的那部分测试。
///
/// 为什么这几条最值得测：
///   * `pcm16WavBytes` 是纯函数，但**写错了不会报错** —— 只会得到一个
///     "某些播放器打不开 / 有爆音"的文件，真机归因极其困难；
///   * `untar-bz2.mjs` 是**手机上装模型的唯一通路**（Android 没有 tar/bzip2），
///     它要是把 tar 解歪了，模型就是坏的；而它的安全闸（`../` 越权写）
///     一旦失效就是真的安全漏洞 —— 所以这里既测"能解对"，也测"该拒绝的必须拒绝"。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/local/local_tts.dart';

import '_tar_fixture.dart';

const String toolbox = 'assets/toolbox';

void main() {
  group('WAV 写入（离线合成的产物格式）', () {
    test('44 字节标准头：RIFF/WAVE/fmt/data 与各字段都算对', () {
      final wav = pcm16WavBytes(Float32List.fromList(<double>[0, 0.5, -0.5]), 24000);
      expect(wav.length, 44 + 3 * 2);
      String ascii(int off, int n) =>
          String.fromCharCodes(wav.sublist(off, off + n));
      expect(ascii(0, 4), 'RIFF');
      expect(ascii(8, 4), 'WAVE');
      expect(ascii(12, 4), 'fmt ');
      expect(ascii(36, 4), 'data');
      final bd = ByteData.sublistView(wav);
      expect(bd.getUint32(4, Endian.little), 36 + 6); // RIFF size
      expect(bd.getUint32(16, Endian.little), 16); // fmt 长度
      expect(bd.getUint16(20, Endian.little), 1); // PCM
      expect(bd.getUint16(22, Endian.little), 1); // 单声道
      expect(bd.getUint32(24, Endian.little), 24000); // 采样率
      expect(bd.getUint32(28, Endian.little), 48000); // 字节率
      expect(bd.getUint16(32, Endian.little), 2); // 块对齐
      expect(bd.getUint16(34, Endian.little), 16); // 位深
      expect(bd.getUint32(40, Endian.little), 6); // data 长度
    });

    test('采样转换：0→0、满幅不溢出、越界要**截断**而不是回绕', () {
      final wav = pcm16WavBytes(
        Float32List.fromList(<double>[0, 1.0, -1.0, 2.0, -2.0, double.nan]),
        8000,
      );
      final bd = ByteData.sublistView(wav);
      int at(int i) => bd.getInt16(44 + i * 2, Endian.little);
      expect(at(0), 0);
      expect(at(1), 32767);
      expect(at(2), -32767);
      // 越界：截断到满幅。若写成不截断的乘法，2.0 会回绕成负数（听感是爆音）
      expect(at(3), 32767);
      expect(at(4), -32767);
      expect(at(5), 0, reason: 'NaN 不该变成奇怪的值');
    });

    test('空采样也能出一个合法的（空）WAV，而不是崩', () {
      final wav = pcm16WavBytes(Float32List(0), 16000);
      expect(wav.length, 44);
      final bd = ByteData.sublistView(wav);
      expect(bd.getUint32(40, Endian.little), 0);
    });
  });

  group('模型目录与状态（不需要真模型）', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('dsh-tts-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('没装模型时：installed=false，且能列出缺哪些文件', () {
      final tts = LocalTts(tmp.path);
      expect(tts.installed, isFalse);
      expect(tts.missingFiles, containsAll(<String>['model.onnx', 'lexicon.txt', 'tokens.txt']));
      expect(tts.modelDir, '${tmp.path}/tts/${LocalTts.modelId}');
    });

    test('必需文件齐了就 installed=true；规则 fst 缺不影响出声（但要能查出来）', () {
      final dir = Directory('${tmp.path}/tts/${LocalTts.modelId}')..createSync(recursive: true);
      for (final f in LocalTts.requiredFiles) {
        File('${dir.path}/$f').writeAsStringSync('x');
      }
      final tts = LocalTts(tmp.path);
      expect(tts.installed, isTrue);
      expect(tts.hasRuleFsts, isFalse, reason: '规则 fst 没放，应当如实查出来');
      for (final f in LocalTts.ruleFstFiles) {
        File('${dir.path}/$f').writeAsStringSync('x');
      }
      expect(LocalTts(tmp.path).hasRuleFsts, isTrue);
    });

    test('模型没装就调用合成 → 明确报 notInstalled（而不是抛底层异常）', () {
      final tts = LocalTts(tmp.path);
      expect(
        () => tts.synthesizeToWav(text: '你好', outPath: '${tmp.path}/o.wav'),
        throwsA(isA<LocalTtsException>().having(
            (e) => e.error, 'error', LocalTtsError.notInstalled)),
      );
    });

    test('空文本先被挡住（不报 notInstalled，因为那不是模型的问题）', () {
      final tts = LocalTts(tmp.path);
      expect(
        () => tts.synthesizeToWav(text: '   ', outPath: '${tmp.path}/o.wav'),
        throwsA(isA<LocalTtsException>()
            .having((e) => e.error, 'error', LocalTtsError.emptyText)),
      );
    });

    test('说话人表：行号即 sid；空行跳过；文件缺失时退化成只有 0 号', () {
      final dir = Directory('${tmp.path}/tts/${LocalTts.modelId}')..createSync(recursive: true);
      expect(LocalTts(tmp.path).speakers(), <String>['0'], reason: '没有表就别编说话人');
      File('${dir.path}/${LocalTts.speakersFile}')
          .writeAsStringSync('SSB0005\n\nSSB0009\n  SSB0011  \n');
      expect(LocalTts(tmp.path).speakers(), <String>['SSB0005', 'SSB0009', 'SSB0011']);
    });
  });

  group('手机上装模型的唯一通路：untar-bz2.mjs（端到端跑真 node）', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('dsh-untar-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// 用系统 bzip2 压成 `<tarPath>.bz2`（本机有；没有就跳过，如实标注）。
    ///
    /// ⚠️ 这里踩过一次：原来写完又 `copySync` 到同一个路径 —— 目标会先被截断，
    ///    于是"压缩包"变成 0 字节，被测脚本报 "bad magic"。
    ///    **夹具错了会看起来像被测代码错了**，所以夹具本身也要按"能证伪"来写：
    ///    现在直接返回 bzip2 自己写出的路径，不再复制。
    Future<bool> makeBz2(String tarPath) async {
      final has = await Process.run('sh', <String>['-c', 'command -v bzip2']);
      if (has.exitCode != 0) return false;
      final r = await Process.run('bzip2', <String>['-z', '-f', '-k', tarPath]);
      return r.exitCode == 0 && File('$tarPath.bz2').existsSync();
    }

    test('正常包：能解出文件、内容逐字节一致', () async {
      final tarPath = '${tmp.path}/ok.tar';
      final body = List<int>.generate(1000, (i) => i % 251);
      File(tarPath).writeAsBytesSync(
          tarWithFiles(<String, List<int>>{'vits-icefall-zh-aishell3/model.onnx': body}));
      if (!await makeBz2(tarPath)) {
        markTestSkipped('本机没有 bzip2，跳过');
        return;
      }
      final bz2 = '$tarPath.bz2';
      final out = '${tmp.path}/out';
      final r = await Process.run('node',
          <String>['$toolbox/untar-bz2.mjs', bz2, out]);
      expect(r.exitCode, 0, reason: '解包应当成功：${r.stdout}\n${r.stderr}');
      expect('${r.stdout}', contains('[untar] ok'));
      final extracted = File('$out/vits-icefall-zh-aishell3/model.onnx');
      expect(extracted.existsSync(), isTrue, reason: '目录结构要按包里的路径还原');
      expect(extracted.readAsBytesSync(), body, reason: '内容必须逐字节一致');
    });

    test('路径越权（../）必须**拒绝**，且不能往目标外面写东西', () async {
      final tarPath = '${tmp.path}/evil.tar';
      File(tarPath).writeAsBytesSync(
          tarWithFiles(<String, List<int>>{'../evil.txt': 'pwned'.codeUnits}));
      if (!await makeBz2(tarPath)) {
        markTestSkipped('本机没有 bzip2，跳过');
        return;
      }
      final bz2 = '$tarPath.bz2';
      final out = '${tmp.path}/out';
      final r = await Process.run('node',
          <String>['$toolbox/untar-bz2.mjs', bz2, out]);
      expect(r.exitCode, 2, reason: '不安全路径必须失败退出');
      expect('${r.stdout}', contains('中止'));
      expect(File('${tmp.path}/evil.txt').existsSync(), isFalse,
          reason: '越权文件绝不能真的被写出来');
      expect(File('/tmp/evil.txt').existsSync(), isFalse);
    });

    test('不是 bz2 / 文件不存在：给人话 + 退出码 2，而不是抛栈', () async {
      final notBz2 = '${tmp.path}/nope.tar.bz2';
      File(notBz2).writeAsStringSync('这不是 bz2');
      final r = await Process.run('node',
          <String>['$toolbox/untar-bz2.mjs', notBz2, '${tmp.path}/out']);
      expect(r.exitCode, 2);
      expect('${r.stdout}', contains('错误：'));

      final r2 = await Process.run('node',
          <String>['$toolbox/untar-bz2.mjs', '${tmp.path}/不存在.tar.bz2', '${tmp.path}/out']);
      expect(r2.exitCode, 2);
      expect('${r2.stdout}', contains('找不到输入文件'));
    });
  });
}
