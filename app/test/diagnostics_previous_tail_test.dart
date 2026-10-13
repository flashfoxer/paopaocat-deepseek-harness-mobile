/// 「闪退现场」必须进报告（用户 2026-10-12）。
///
/// ## 用户的疑问
///
/// 「是不是每次退出再进日志就会重新开始，要不要先把日志生成改为不进行重置」
/// —— **一半猜对了**：
///   * 报告里的 DETAIL 来自**内存环形缓冲**，确实每次启动都从零开始；
///   * 但**落盘日志是跨启动追加的**（只在 512 KB 时轮转），现场其实一直在盘上，
///     只是**报告没把它带出来**。
///
/// 所以不重置落盘文件（那会毁掉历史线索），而是：启动时在写本次第一行**之前**
/// 把上一次的尾巴截下来，报告里单独一节。这个文件就是钉住这条的。
///
/// ⚠️ 也钉住"**不许下结论**"：Android 把进程直接杀掉时没有任何回调，
/// 从 App 侧分不出"正常退出"和"被杀"，所以只给最后几行。
library;

import 'dart:io';

import 'package:dsh_mobile/local/diagnostics_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Directory newDir() => Directory.systemTemp.createTempSync('dsh-log-tail-');

  /// 造一份"上次运行留下的落盘日志"（最后一行之后就是崩溃点）。
  void seedPreviousRun(String root, List<String> lines) {
    final logs = Directory('$root/logs')..createSync(recursive: true);
    File('${logs.path}/dsh-diagnostic.log')
        .writeAsStringSync('${lines.join('\n')}\n');
  }

  test('上次运行结束前的尾巴会被截下来，并真的写进报告', () async {
    final dir = newDir();
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    seedPreviousRun(dir.path, <String>[
      '0001|10:00:00.000|I|dsh-log|诊断日志启动：第 31 次启动',
      '0002|10:00:01.000|I|print:dsh-litertlm|加载模型：/x/Gemma4.litertlm（backend=gpu, maxNumTokens=32768）',
      '0003|10:00:09.000|I|print:dsh-litertlm|已就绪：127.0.0.1:39541（gpu）',
      '0004|10:00:20.000|I|print:chat|prompt: 你好', // ← 崩在这一行之后
    ]);

    await DiagnosticsLog.init(filesDir: dir.path);

    expect(DiagnosticsLog.previousRunTail, isNotEmpty,
        reason: '上次的尾巴没截下来 —— 闪退现场又丢了');
    expect(DiagnosticsLog.previousRunTail.last, contains('prompt: 你好'),
        reason: '最后一行就该是崩溃前的那一行');
    expect(DiagnosticsLog.previousRunTail.any((l) => l.contains('加载模型')), isTrue,
        reason: '崩前加载过什么模型，是最关键的线索之一');

    final path = await DiagnosticsLog.writeToFile(headerLines: <String>['测试头']);
    expect(path, isNotNull);
    final text = File(path!).readAsStringSync();
    expect(text, contains('上次运行结束前'),
        reason: '报告里没有"崩溃现场"那一节 —— 用户只能看到本次启动');
    expect(text, contains('已就绪：127.0.0.1:39541'), reason: '尾巴的内容没进报告');
    // 必须如实说这个现场可能是什么，**不许**断言"上次崩了"
    expect(text, contains('闪退/被杀'), reason: '标题该说清这一节的用途');
  });

  test('尾巴有上限，不许把报告撑爆', () async {
    final dir = newDir();
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    seedPreviousRun(dir.path, <String>[
      for (var i = 0; i < 400; i++) '0${i.toString().padLeft(3, '0')}|10:00:00|I|t|第 $i 行',
    ]);
    await DiagnosticsLog.init(filesDir: dir.path);
    expect(DiagnosticsLog.previousRunTail.length,
        DiagnosticsLog.maxPreviousTailLines,
        reason: '不截断的话，一份长会话的尾巴就能把报告撑成几百 KB');
    expect(DiagnosticsLog.previousRunTail.last, contains('第 399 行'),
        reason: '截断要保留**最后**那段（崩溃点在那头）');
  });

  test('第一次跑（还没有落盘日志）不许炸，尾巴为空', () async {
    final dir = newDir();
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    await DiagnosticsLog.init(filesDir: dir.path);
    expect(DiagnosticsLog.previousRunTail, isEmpty);
  });

  test('崩溃记录（crashes.json）能被读出来给报告用', () async {
    final dir = newDir();
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final models = Directory('${dir.path}/dshhome/models')
      ..createSync(recursive: true);
    File('${models.path}/crashes.json').writeAsStringSync(
        '{"Gemma4-E2B|gpu":3,"gemma-3-1b-it|cpu":1}');
    await DiagnosticsLog.init(filesDir: dir.path);

    final lines = await DiagnosticsLog.crashRecordLines();
    expect(lines, hasLength(2), reason: '崩溃记录没被读出来（"经常闪退"就对不上账）');
    // 次数多的排前面：先看最可疑的那个
    expect(lines.first, contains('Gemma4-E2B'));
    expect(lines.first, contains('3'));
    expect(lines.first, contains('gpu'));
  });

  test('读不到崩溃记录 / 文件坏了 → 返回空，不许把报告生成搞挂', () async {
    final dir = newDir();
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    await DiagnosticsLog.init(filesDir: dir.path);
    expect(await DiagnosticsLog.crashRecordLines(), isEmpty);
  });
}
