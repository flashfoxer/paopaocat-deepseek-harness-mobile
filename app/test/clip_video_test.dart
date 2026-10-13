/// 「剪辑」脚本（`assets/toolbox/clip-video.mjs`）的**端到端**测试。
///
/// ## 为什么这几条必须钉住
///
/// 这个脚本动的都是**用户自己的素材**，所以它的坏法都很贵：
///
/// * `-c copy` 那一刀如果写错参数，**剪出来的片子会静音 / 丢帧 / 播不了**，
///   而退出码仍是 0 —— 用户只会以为"剪坏了"；
/// * 拼接时几段参数不一致还硬拼（各按各的分辨率归一化），**能拼上、能播**，
///   只是画面中途变形 —— 这是"看着像成功"的失败里最典型的一种；
/// * 输出文件如果是**输入文件本身**，等于把用户的源素材剪没了（不可逆）。
///
/// 所以这里用**真 node 进程 + 真 ffmpeg** 跑完整链路：先用 ffmpeg 合成小测试片，
/// 再逐项验证产物（用 `ffprobe` 这个**独立工具**量时长/分辨率/音轨，
/// 不用我们自己的代码自证），并专门验证：
///   * 同参数拼接走 `-c copy` 时**声音还在**（不是静音）；
///   * 参数不一致时**直接报错、不产出文件**，而不是硬拼；
///   * `--reencode` 时**所有段都统一到第一段的尺寸**（含原本没有音轨的那段）；
///   * 参数错（--start 超长 / 坏时间串 / 同一文件进出）**退出码 2 且不落产物**。
///
/// ⚠️ 本机（Linux）用的是系统 ffmpeg 5.1；手机上是随包的 7.1 精简构建
///    （没有 subtitles/drawtext 滤镜）。所以这里能证明的是**命令与逻辑正确**，
///    "手机那套精简 ffmpeg 上也能跑"仍要靠真机 —— 脚本里已经避开了
///    只有完整构建才有的滤镜（只用了 scale/pad/setsar/fps/format）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 工具箱目录（测试的工作目录就是 app/）。
const String script = 'assets/toolbox/clip-video.mjs';

String which(String name) {
  for (final d in (Platform.environment['PATH'] ?? '').split(':')) {
    if (d.isEmpty) continue;
    final p = '$d/$name';
    if (File(p).existsSync()) return p;
  }
  return '';
}

final String ffmpegPath = which('ffmpeg');
final String ffprobePath = which('ffprobe');
final String? skipReason =
    (ffmpegPath.isEmpty || ffprobePath.isEmpty) ? '本机没有 ffmpeg/ffprobe' : null;

Future<ProcessResult> node(List<String> args, {Map<String, String>? env, bool parentEnv = true}) =>
    Process.run('node', <String>[script, ...args],
        environment: env, includeParentEnvironment: parentEnv);

Future<ProcessResult> sh(List<String> args) => Process.run(args.first, args.sublist(1));

/// 用 ffprobe 量一个文件（**独立工具**，不是我们的代码）。
Future<Map<String, dynamic>> probeOf(String file) async {
  final r = await sh([ffprobePath, '-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', file]);
  final j = jsonDecode('${r.stdout}') as Map<String, dynamic>;
  final streams = (j['streams'] as List).cast<Map<String, dynamic>>();
  return <String, dynamic>{
    'duration': double.tryParse('${(j['format'] as Map)['duration']}'),
    'video': streams.where((s) => s['codec_type'] == 'video').toList(),
    'audio': streams.where((s) => s['codec_type'] == 'audio').toList(),
  };
}

/// 抽 1 秒音频量平均音量（dB）。静音的实测值约 -91 dB，有声的约 -20 ~ -25 dB。
Future<double> meanVolume(String file, {double at = 0, double seconds = 1}) async {
  final r = await sh([
    ffmpegPath, '-ss', '$at', '-t', '$seconds', '-i', file,
    '-af', 'volumedetect', '-f', 'null', '-',
  ]);
  final m = RegExp(r'mean_volume:\s*(-?[\d.]+)').firstMatch('${r.stderr}');
  expect(m, isNotNull, reason: '量不出音量：${r.stderr}');
  return double.parse(m!.group(1)!);
}

void main() {
  late Directory tmp;

  setUpAll(() {
    // ⚠️ 无条件创建：跳过了也要能安全清理（不然 tearDownAll 会碰未初始化的 late 变量）
    tmp = Directory.systemTemp.createTempSync('dsh-clip-');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ── 测试素材：a/b 同参数（有声），silent 不同参数（无音轨） ──
  late String a, b, silent;

  setUpAll(() async {
    if (skipReason != null) return;
    a = '${tmp.path}/a.mp4';
    b = '${tmp.path}/b.mp4';
    silent = '${tmp.path}/silent.mp4';
    // 320x240 / 25fps / 4 秒 + 440Hz
    await sh([ffmpegPath, '-v', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=25:duration=4',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-shortest', a]);
    // 同参数、3 秒、880Hz
    await sh([ffmpegPath, '-v', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=25:duration=3',
      '-f', 'lavfi', '-i', 'sine=frequency=880:duration=3',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-shortest', b]);
    // 640x360、2 秒、**没有音轨**
    await sh([ffmpegPath, '-v', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=30:duration=2',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-an', silent]);
    for (final f in <String>[a, b, silent]) {
      expect(File(f).existsSync(), isTrue, reason: '测试素材没造出来：$f');
    }
  });

  final skip = skipReason;
  group('probe：读得懂素材', () {
    test('时长/分辨率/编码/有无音轨', () async {
      final r = await node(['probe', a]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final out = '${r.stdout}';
      expect(out, contains('[clip] probe '));
      expect(out, contains('width=320'));
      expect(out, contains('height=240'));
      expect(out, contains('vcodec=h264'));
      expect(out, contains('acodec=aac'));
      expect(out, contains('has_audio=1'));
      // 给界面预填"剪到哪"用的 JSON 行
      final m = RegExp(r'\[clip\] json=(\{.*\})').firstMatch(out);
      expect(m, isNotNull, reason: '没有 json 行，界面就没法回填时长');
      final j = jsonDecode(m!.group(1)!) as Map<String, dynamic>;
      expect((j['seconds'] as num).toDouble(), closeTo(4.0, 0.2));
      expect(j['hasAudio'], isTrue);
    });

    test('没有音轨的文件要如实说 has_audio=0', () async {
      final r = await node(['probe', silent]);
      expect('${r.stdout}', contains('has_audio=0'));
    });
  }, skip: skip);

  group('trim：剪一段', () {
    test('不重编码：剪得出、时长对、配得上成功标记', () async {
      final out = '${tmp.path}/t1.mp4';
      final r = await node(['trim', a, out, '--start', '1', '--end', '3']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect('${r.stdout}', contains('[clip] ok file='));
      expect('${r.stdout}', contains(' file=$out '));
      // ⚠️ `-c copy` 会落在关键帧上，允许多一点偏差（这正是界面上要如实说的话）
      final p = await probeOf(out);
      expect(p['duration'] as double, closeTo(2.0, 0.7));
      expect((p['video'] as List).isNotEmpty, isTrue);
      expect((p['audio'] as List).isNotEmpty, isTrue, reason: '剪出来不能没声音');
    });

    test('--exact 重编码：时长要准到 0.1 秒内', () async {
      final out = '${tmp.path}/t2.mp4';
      final r = await node(['trim', a, out, '--start', '0:01', '--end', '0:02', '--exact']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final p = await probeOf(out);
      expect(p['duration'] as double, closeTo(1.0, 0.1));
    });

    test('不写 --end 就剪到结尾', () async {
      final out = '${tmp.path}/t3.mp4';
      final r = await node(['trim', a, out, '--start', '2']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final p = await probeOf(out);
      expect(p['duration'] as double, closeTo(2.0, 0.7));
    });

    test('--start 超过片长 → 退出码 2、说人话、不落产物', () async {
      final out = '${tmp.path}/t4.mp4';
      final r = await node(['trim', a, out, '--start', '999']);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('错误：'));
      expect('${r.stderr}', contains('超过了这段视频的长度'));
      expect(File(out).existsSync(), isFalse, reason: '失败了就不该留下半成品');
    });

    test('坏时间串 / --end 小于 --start → 退出码 2', () async {
      final out = '${tmp.path}/t5.mp4';
      var r = await node(['trim', a, out, '--start', 'abc']);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('--start 读不出来'));

      r = await node(['trim', a, out, '--start', '3', '--end', '1']);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('必须大于'));
    });

    test('输出不能是输入本身（否则把用户的源素材剪没了）', () async {
      final r = await node(['trim', a, a, '--start', '1']);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('不能和输入文件是同一个'));
      final p = await probeOf(a);
      expect(p['duration'] as double, closeTo(4.0, 0.2), reason: '源文件被动了');
    });
  }, skip: skip);

  group('concat：拼接', () {
    test('同参数 → 不重编码就拼起来，画面与声音都在', () async {
      final out = '${tmp.path}/c1.mp4';
      final r = await node(['concat', out, a, b]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect('${r.stdout}', contains(' op=concat'));
      final p = await probeOf(out);
      expect(p['duration'] as double, closeTo(7.0, 0.4), reason: '4 秒 + 3 秒');
      expect((p['audio'] as List).isNotEmpty, isTrue);
      // ⚠️ 专门量一下声音：`-c copy` 拼接最阴的坏法就是"拼上了但整条静音"
      expect(await meanVolume(out, at: 5), greaterThan(-60), reason: '第二段的声音丢了');
    });

    test('参数不一致 → 报错、不硬拼、不落产物', () async {
      final out = '${tmp.path}/c2.mp4';
      final r = await node(['concat', out, a, silent]);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('参数不一致'));
      expect('${r.stderr}', contains('--reencode'), reason: '要说清怎么办');
      expect(File(out).existsSync(), isFalse);
    });

    test('--reencode → 全部统一到第一段的尺寸，无音轨那段补静音', () async {
      final out = '${tmp.path}/c3.mp4';
      final r = await node(['concat', out, a, silent, '--reencode']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final p = await probeOf(out);
      expect(p['duration'] as double, closeTo(6.0, 0.6), reason: '4 秒 + 2 秒');
      final v = (p['video'] as List).first as Map<String, dynamic>;
      expect(v['width'], 320, reason: '所有段都要统一到第一段的宽度');
      expect(v['height'], 240);
      expect((p['audio'] as List).isNotEmpty, isTrue, reason: '无音轨那段要补静音，不能整条没音轨');
      expect(await meanVolume(out, at: 0), greaterThan(-60), reason: '第一段的声音应该还在');
      expect(await meanVolume(out, at: 5), lessThan(-70), reason: '第二段本来就无声，应是静音');
    });

    test('只给一段 → 退出码 2（拼接至少要两段）', () async {
      final r = await node(['concat', '${tmp.path}/c4.mp4', a]);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('用法'));
    });
  }, skip: skip);

  group('audio / frame / compress', () {
    test('抽音频：只要声音轨、时长对', () async {
      final out = '${tmp.path}/a1.m4a';
      final r = await node(['audio', a, out]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect('${r.stdout}', contains(' op=audio'));
      final p = await probeOf(out);
      expect((p['video'] as List).isEmpty, isTrue, reason: '抽音频不该带画面轨');
      expect((p['audio'] as List).isNotEmpty, isTrue);
      expect(p['duration'] as double, closeTo(4.0, 0.3));
    });

    test('没有声音的视频 → 明确说抽不出来', () async {
      final r = await node(['audio', silent, '${tmp.path}/a2.m4a']);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('没有声音轨'));
    });

    test('不认识的音频容器 → 列出能用的几种', () async {
      final r = await node(['audio', a, '${tmp.path}/a3.ogg']);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('.m4a'));
    });

    test('截一帧：JPEG 魔数、尺寸与源片一致', () async {
      final out = '${tmp.path}/f1.jpg';
      final r = await node(['frame', a, out, '--at', '2']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect('${r.stdout}', contains(' op=frame'));
      final bytes = File(out).readAsBytesSync();
      expect(bytes.sublist(0, 2), <int>[0xFF, 0xD8], reason: '这不像一张 JPEG');
      final p = await probeOf(out);
      final v = (p['video'] as List).first as Map<String, dynamic>;
      expect(v['width'], 320);
    });

    test('截图格式不认识 → 报错', () async {
      final r = await node(['frame', a, '${tmp.path}/f2.gif']);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('.jpg'));
    });

    test('压小：文件真的变小、宽不超上限、声音还在', () async {
      final out = '${tmp.path}/s1.mp4';
      final before = File(b).lengthSync();
      final r = await node(['compress', b, out, '--max-width', '320', '--crf', '30']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect('${r.stdout}', contains(' op=compress'));
      expect(File(out).lengthSync(), lessThan(before), reason: '压完应该更小');
      final p = await probeOf(out);
      final v = (p['video'] as List).first as Map<String, dynamic>;
      expect(v['width'], lessThanOrEqualTo(320));
      expect((p['audio'] as List).isNotEmpty, isTrue);
    });

    test('本来就没超上限的片**不放大**（只降码率）', () async {
      final out = '${tmp.path}/s2.mp4';
      final r = await node(['compress', b, out, '--max-width', '1920']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect('${r.stderr}', contains('没超'), reason: '没超上限时就该走"不缩放"那条路');
      final p = await probeOf(out);
      final v = (p['video'] as List).first as Map<String, dynamic>;
      expect(v['width'], 320, reason: '320 宽的片子不许被放大到 1920');
    });

    test('--crf 越界 → 报错', () async {
      final r = await node(['compress', b, '${tmp.path}/s3.mp4', '--crf', '99']);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('--crf'));
    });
  }, skip: skip);

  group('参数与环境', () {
    test('不认识的操作 → 列出可用的', () async {
      final r = await node(['nope', a, b]);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('不认识的操作'));
      expect('${r.stderr}', contains('trim'));
    });

    test('输入文件不存在 → 说清是哪个文件', () async {
      final r = await node(['trim', '${tmp.path}/nope.mp4', '${tmp.path}/o.mp4', '--start', '1']);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('输入文件不存在'));
    });

    test('⚠️ 认的是 DSH_ANDROID_FFMPEG（App 的约定），不是 PATH', () async {
      // PATH 指到一个空目录：在电脑上就等于"系统里没有 ffmpeg"。
      // ⚠️ 这个用例把父进程环境整个丢掉（`parentEnv: false`），所以 **node 本身**
      //    也必须写绝对路径 —— 否则 Dart 解析不到 `node`，测试会以
      //    「ProcessException: No such file or directory」失败（踩过）。
      final nodePath = which('node');
      expect(nodePath, isNotEmpty, reason: '这条用例需要 node 的绝对路径');
      final noPath = <String, String>{
        'PATH': '${tmp.path}/empty-path',
        'DSH_ANDROID_FFMPEG': ffmpegPath,
        'DSH_ANDROID_FFPROBE': ffprobePath,
      };
      Directory(noPath['PATH']!).createSync(recursive: true);

      final ok = await Process.run(nodePath, <String>[script, 'probe', a],
          environment: noPath, includeParentEnvironment: false);
      expect(ok.exitCode, 0, reason: '环境变量给了路径就该能用：${ok.stderr}');
      expect('${ok.stdout}', contains('width=320'));

      // 环境变量指到一个不存在的文件 → 必须报"找不到 ffmpeg"，而不是硬跑
      final bad = <String, String>{
        'PATH': noPath['PATH']!,
        'DSH_ANDROID_FFMPEG': '${tmp.path}/nope-ffmpeg',
      };
      final r = await Process.run(nodePath, <String>[script, 'probe', a],
          environment: bad, includeParentEnvironment: false);
      expect(r.exitCode, 2);
      expect('${r.stderr}', contains('找不到 ffmpeg'));
      expect('${r.stderr}', contains('DSH_ANDROID_FFMPEG'), reason: '要说清去哪儿配');
    });
  }, skip: skipReason);
}
