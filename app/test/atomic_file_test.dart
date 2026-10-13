/// 落盘纪律的测试（审计 P0-9）。
///
/// ## 为什么这几条测试非有不可
///
/// P0-9 说的是一条**会静默吃掉用户数据**的链：
///
///   进程被杀 → 留下半份 JSON → 下次启动读成"空配置" → 下次保存把空写回去
///   → 用户的厂家与模型全没了，**且界面上没有任何提示**。
///
/// 修法有两半，两半都必须被钉住：
///   ① 写：`.part` + `rename`（不会留半份）；
///   ② 读：解析失败**不当成空**，而是把坏文件挪到 `.corrupt` 并报错。
/// 第 ② 半是真正堵住"数据全没了"的那一步 —— 只要原始字节还在，
/// 人就能救回来。所以这里专门断言"坏文件的字节**还在**"。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/data/atomic_file.dart';
import 'package:dsh_mobile/data/configured_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('atomic-file-test-');
    ConfiguredModels.lastReadError = null;
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('原子写', () {
    test('写出内容，并且不留下 .part', () async {
      final f = File('${tmp.path}/a.json');
      await writeStringAtomic(f, '{"x":1}');
      expect(f.readAsStringSync(), '{"x":1}');
      expect(File('${f.path}.part').existsSync(), isFalse,
          reason: '.part 应该已经被 rename 掉，不该留在盘上');
    });

    test('覆盖已有文件（rename 覆盖）', () async {
      final f = File('${tmp.path}/a.json');
      await writeStringAtomic(f, 'old');
      await writeStringAtomic(f, 'new');
      expect(f.readAsStringSync(), 'new');
    });

    test('目标目录不存在也会自己建出来', () async {
      final f = File('${tmp.path}/sub/dir/a.json');
      await writeStringAtomic(f, 'ok');
      expect(f.readAsStringSync(), 'ok');
    });

    test('同步版行为一致', () {
      final f = File('${tmp.path}/s.json');
      writeStringAtomicSync(f, 'sync');
      expect(f.readAsStringSync(), 'sync');
      expect(File('${f.path}.part').existsSync(), isFalse);
    });

    test('中途失败不会把目标文件截断成半份（.part 与目标互不影响）', () async {
      final f = File('${tmp.path}/a.json');
      await writeStringAtomic(f, '{"good":1}');
      // 模拟"写 .part 的时候崩了"：目标文件必须还是完整的那份。
      File('${f.path}.part').writeAsStringSync('{"half":');
      expect(f.readAsStringSync(), '{"good":1}',
          reason: '目标文件被 .part 的内容污染了 —— 原子性没了');
      // 复原：下一次写会把 .part 覆盖掉
      await writeStringAtomic(f, '{"good":2}');
      expect(f.readAsStringSync(), '{"good":2}');
      expect(File('${f.path}.part').existsSync(), isFalse);
    });
  });

  group('坏文件隔离', () {
    test('挪走且**保住字节**（这是"数据还能救回来"的前提）', () {
      final f = File('${tmp.path}/a.json');
      f.writeAsStringSync('{"providers":[{"id":"d');
      final moved = quarantineCorrupt(f);
      expect(moved, isNotNull);
      expect(f.existsSync(), isFalse, reason: '原文件应该已经被挪走');
      expect(moved!.readAsStringSync(), '{"providers":[{"id":"d',
          reason: '用户那半份原始字节必须还在 —— 否则没法人工恢复');
    });

    test('只保留最近一次（不堆垃圾）', () {
      final f = File('${tmp.path}/a.json');
      f.writeAsStringSync('first');
      quarantineCorrupt(f);
      f.writeAsStringSync('second');
      final moved = quarantineCorrupt(f);
      expect(moved!.readAsStringSync(), 'second');
      // 目录里只该有一个 .corrupt
      final corrupts = tmp
          .listSync()
          .where((e) => e.path.endsWith(kCorruptSuffix))
          .toList();
      expect(corrupts.length, 1);
    });

    test('文件不存在时返回 null，不改任何东西', () {
      expect(quarantineCorrupt(File('${tmp.path}/nope.json')), isNull);
    });
  });

  group('ConfiguredModels.readConfig：损坏不再被当成"空配置"', () {
    test('文件不存在 = 还没配过：返回空且**不报错**', () {
      final cfg = ConfiguredModels.readConfig(tmp.path);
      expect(cfg.providers, isEmpty);
      expect(ConfiguredModels.lastReadError, isNull,
          reason: '"还没配过"不该被说成"读坏了"');
    });

    test('文件在但解析不了 = 损坏：隔离原文件 + 置 lastReadError', () {
      final f = ConfiguredModels.fileOf(tmp.path);
      f.writeAsStringSync('{"providers":[{"id":"deep'); // 半份 JSON
      final cfg = ConfiguredModels.readConfig(tmp.path);
      expect(cfg.providers, isEmpty);
      expect(ConfiguredModels.lastReadError, isNotNull,
          reason: '读坏了必须让界面能说出来，不能假装"还没配"');
      expect(f.existsSync(), isFalse, reason: '坏文件应该被隔离');
      final moved = File('${f.path}$kCorruptSuffix');
      expect(moved.existsSync(), isTrue);
      expect(moved.readAsStringSync(), '{"providers":[{"id":"deep');
    });

    test('顶层不是对象（比如是数组/数字）= 同样按损坏处理', () {
      ConfiguredModels.fileOf(tmp.path).writeAsStringSync('[1,2,3]');
      ConfiguredModels.readConfig(tmp.path);
      expect(ConfiguredModels.lastReadError, isNotNull);
    });

    test('空文件当作"还没配过"（不是损坏）', () {
      ConfiguredModels.fileOf(tmp.path).writeAsStringSync('');
      ConfiguredModels.readConfig(tmp.path);
      expect(ConfiguredModels.lastReadError, isNull);
    });

    test('好的配置：正常读出来，且不置错误', () async {
      await ConfiguredModels.saveConfig(
        filesDir: tmp.path,
        config: const ConfiguredConfig(
          version: ConfiguredModels.currentVersion,
          providers: [
            ProviderSpec(
              id: 'deepseek',
              label: 'DeepSeek',
              baseUrl: 'https://api.deepseek.com/v1',
              api: 'openai-completions',
              apiKeyEnv: 'DEEPSEEK_API_KEY',
            ),
          ],
          models: [
            ModelSpec(provider: 'deepseek', id: 'deepseek-chat'),
          ],
          groups: <RotationGroupSpec>[],
          selected: 'deepseek/deepseek-chat',
        ),
      );
      final cfg = ConfiguredModels.readConfig(tmp.path);
      expect(ConfiguredModels.lastReadError, isNull);
      expect(cfg.providers.map((p) => p.id), contains('deepseek'));
      expect(cfg.models.map((m) => m.id), contains('deepseek-chat'));
    });

    test('保存成功后清掉上一次的"读坏了"状态', () async {
      ConfiguredModels.fileOf(tmp.path).writeAsStringSync('{broken');
      ConfiguredModels.readConfig(tmp.path);
      expect(ConfiguredModels.lastReadError, isNotNull);
      await ConfiguredModels.saveConfig(
        filesDir: tmp.path,
        config: ConfiguredConfig.empty,
      );
      expect(ConfiguredModels.lastReadError, isNull,
          reason: '写成功了，"读坏了"这个提示就该消失，否则界面会一直挂着它');
    });

    test('保存是原子的：写完之后盘上没有 .part', () async {
      await ConfiguredModels.saveConfig(
        filesDir: tmp.path,
        config: ConfiguredConfig.empty,
      );
      final stray = tmp.listSync().where((e) => e.path.endsWith('.part')).toList();
      expect(stray, isEmpty);
      // 且文件本身是合法 JSON
      final raw = ConfiguredModels.fileOf(tmp.path).readAsStringSync();
      expect(() => jsonDecode(raw), returnsNormally);
    });
  });

  group('完好的配置不会被误判成损坏', () {
    test('写坏再读的**典型流程**：坏文件被隔离，用户后续保存不再破坏它', () async {
      final f = ConfiguredModels.fileOf(tmp.path);
      f.writeAsStringSync('{"providers":[{"id":"d');
      ConfiguredModels.readConfig(tmp.path); // 隔离
      // 用户后续（在空配置基础上）保存一次 —— 老版本这一步会把用户数据永久抹掉
      await ConfiguredModels.saveConfig(
        filesDir: tmp.path,
        config: ConfiguredConfig.empty,
      );
      final moved = File('${f.path}$kCorruptSuffix');
      expect(moved.existsSync(), isTrue, reason: '原始字节必须还在，可人工恢复');
      expect(moved.readAsStringSync(), contains('"providers"'));
    });
  });
}
