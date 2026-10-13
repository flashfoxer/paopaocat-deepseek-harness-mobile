import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/local/model_crash_store.dart';
import 'package:dsh_mobile/local/model_store.dart';

/// 这一组钉的是**真机日志暴露出来的三个问题**（2026-10-07），都属于
/// "不测就会再犯、而且用户会以为是自己手机坏了"的那类：
///
///   1. 引擎段错误崩掉（code=-11）后没有任何记忆 → 下次还用同一个后端再崩一遍；
///   2. 崩溃只能看到 `code=-11` 这种机器话 → 看不出是显存/驱动问题；
///   3. 登记表里的**空名字**让界面上那一行整块没有模型名（`?? id` 挡不住空串）。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dsh-crash-test');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('崩溃记录（崩了就换后端，靠它跨重启记住）', () {
    test('按「模型 + 后端」分别计数 —— 后端换掉就该重新算', () async {
      final s = ModelCrashStore(dir: dir.path);
      expect(await s.countFor('m1', 'vulkan'), 0);
      await s.record('m1', 'vulkan', -11);
      expect(await s.countFor('m1', 'vulkan'), 1);
      // 同模型换后端：独立（这是"GPU 崩了就用 CPU"的依据）
      expect(await s.countFor('m1', 'cpu'), 0);
      // 同后端换模型：也独立
      expect(await s.countFor('m2', 'vulkan'), 0);
    });

    test('必须落盘 —— 崩溃发生在用户发消息时，App 重启后还要记得', () async {
      await ModelCrashStore(dir: dir.path).record('m1', 'vulkan', -11);
      // 新实例 = 模拟 App 重启
      final afterRestart = ModelCrashStore(dir: dir.path);
      expect(await afterRestart.countFor('m1', 'vulkan'), 1);
    });

    test('记两次就是两次（界面会显示"崩过 N 次"）', () async {
      final s = ModelCrashStore(dir: dir.path);
      await s.record('m1', 'vulkan', -11);
      await s.record('m1', 'vulkan', -11);
      expect(await s.countFor('m1', 'vulkan'), 2);
    });

    test('clearFor 只清这个模型，不误伤别的', () async {
      final s = ModelCrashStore(dir: dir.path);
      await s.record('m1', 'vulkan', -11);
      await s.record('m1', 'cpu', -11);
      await s.record('m2', 'vulkan', -11);
      await s.clearFor('m1');
      expect(await s.countFor('m1', 'vulkan'), 0);
      expect(await s.countFor('m1', 'cpu'), 0);
      expect(await s.countFor('m2', 'vulkan'), 1);
    });

    test('记录文件坏了也不能挡住启动（当作空记录，不抛）', () async {
      File('${dir.path}/crashes.json').writeAsStringSync('{ 这不是 json');
      final s = ModelCrashStore(dir: dir.path);
      expect(await s.countFor('m1', 'vulkan'), 0);
      // 而且还要能继续正常记录
      await s.record('m1', 'vulkan', -11);
      expect(await s.countFor('m1', 'vulkan'), 1);
    });
  });

  group('退出码翻译（code=-11 这种机器话要给用户/我们一个说法）', () {
    test('-11 就是段错误 —— 真机日志里那个 code，常见于图形后端/显存', () {
      expect(exitCodeReason(-11), contains('段错误'));
      expect(exitCodeReason(-11), contains('SIGSEGV'));
    });

    test('-9 是被系统强杀（内存不足的典型表现）', () {
      expect(exitCodeReason(-9), contains('强杀'));
    });

    test('认不出的码如实带出数字，不编原因', () {
      expect(exitCodeReason(7), contains('7'));
    });
  });

  group('登记表空名字兜底（真机「看不到模型名」的根因）', () {
    test('name 是空字符串时退回 id（`?? id` 挡不住空串）', () {
      final m = InstalledModel.fromJson(<String, dynamic>{
        'id': 'qwen2.5-1.5b-instruct-q4_k_m',
        'name': '',
        'fileName': 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
        'bytes': 1,
        'installedAt': '2026-10-07T00:00:00Z',
      });
      expect(m.name, 'qwen2.5-1.5b-instruct-q4_k_m');
    });

    test('name 缺失时退回 id；name 正常时原样保留（别把好名字改坏）', () {
      final missing = InstalledModel.fromJson(<String, dynamic>{
        'id': 'x',
        'fileName': 'a.gguf',
        'bytes': 1,
        'installedAt': '2026-10-07T00:00:00Z',
      });
      expect(missing.name, 'x');

      final good = InstalledModel.fromJson(<String, dynamic>{
        'id': 'x',
        'name': 'Gemma 3 1B',
        'fileName': 'a.gguf',
        'bytes': 1,
        'installedAt': '2026-10-07T00:00:00Z',
      });
      expect(good.name, 'Gemma 3 1B');
    });

    test('name 只有空白也算没名字', () {
      final m = InstalledModel.fromJson(<String, dynamic>{
        'id': 'y',
        'name': '   ',
        'fileName': 'a.gguf',
        'bytes': 1,
        'installedAt': '2026-10-07T00:00:00Z',
      });
      expect(m.name, 'y');
    });
  });
}
