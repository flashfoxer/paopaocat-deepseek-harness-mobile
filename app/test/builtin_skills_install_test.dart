/// 内置技能**整目录安装**的测试（`lib/data/builtin_skills.dart`）。
///
/// ## 为什么这几条必须钉住
///
/// 这个安装器管的是"**设备上到底有没有这些技能**"，而它坏掉的方式**全是静默的**：
///
///   * `pubspec.yaml` 漏了一个技能目录 → 打包时不进 APK → 设备上那个技能**永远不存在**
///     （日志里只有一行 `loadString` 失败，界面上什么都看不出来）；
///   * 多文件技能只装了 `SKILL.md` → 正文里 `references/xxx.md` 全是死链，
///     模型读不到、**质量悄悄掉一档**，谁都不会知道；
///   * "用户改过就不覆盖"这条判定写错 → 要么把用户的修改冲掉（不可接受），
///     要么把**所有技能**都误判成"用户改过"从而永远不再更新（同样静默）。
///
/// 所以这里用**真实 asset**（真打好的包清单 + 真文件）跑一遍完整安装，
/// 再把上面每种坏法都钉一条：
///   ① 每个技能都能装且非空（含 pubspec 漏配）；
///   ② 多文件技能的两个文件都到位（`frontend-design` 有 SKILL.md + LICENSE.txt）；
///   ③ 幂等：没变化时不动文件；
///   ④ 用户改过其中一个文件 → **整个技能让位**（含不再补新文件）；
///   ⑤ 用户删了我们记过的文件 → 也算改过，不偷偷恢复；
///   ⑥ 老格式（v1）清单能平滑升级，且**新增的文件会被补齐**。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_mobile/data/builtin_skills.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsh-skills-');
    home = tmp.path;
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 按字节读 asset（**必须带 offset/length**：`buffer.asUint8List()` 不给参数
  /// 会把整个底层 buffer 算进来，在有对齐填充时长度就不对了）。
  Future<Uint8List> bytesOfAsset(String key) async {
    final d = await rootBundle.load(key);
    return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
  }

  Future<String> readAsset(String key) async => utf8.decode(await bytesOfAsset(key));

  Future<String> shaOfAsset(String key) async {
    final d = await rootBundle.load(key);
    return sha256
        .convert(d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes))
        .toString();
  }

  Map<String, dynamic> readManifest() => jsonDecode(
      File(BuiltinSkills.manifestPath(home)).readAsStringSync())
      as Map<String, dynamic>;

  group('安装：每个技能都要真的落到设备上', () {
    test('① 14 个技能全部装上，且每个技能的 SKILL.md 非空', () async {
      final r = await BuiltinSkills.install(home);
      expect(r.errors, isEmpty, reason: '安装出错：${r.errors}');
      expect(r.installed, BuiltinSkills.names.length);
      for (final name in BuiltinSkills.names) {
        final f = File('$home/skills/$name/SKILL.md');
        expect(f.existsSync(), isTrue, reason: '$name 的 SKILL.md 没装上');
        expect(f.readAsStringSync().length, greaterThan(200),
            reason: '$name 的 SKILL.md 看起来是空的');
      }
    });

    test('① 每个技能在 asset 清单里都查得到文件（pubspec 漏配就红）', () async {
      for (final name in BuiltinSkills.names) {
        final files = await BuiltinSkills.filesFor(name);
        expect(files, isNotEmpty,
            reason: '$name 在 AssetManifest 里一个文件都没有 —— '
                '多半是 pubspec.yaml 漏了 `- assets/skills/$name/`');
        expect(files, contains('assets/skills/$name/SKILL.md'));
      }
    });

    test('② 多文件技能：SKILL.md 之外的随包文件也要装过去（否则正文里是死链）',
        () async {
      await BuiltinSkills.install(home);
      final lic = File('$home/skills/frontend-design/LICENSE.txt');
      expect(lic.existsSync(), isTrue,
          reason: 'frontend-design 的 LICENSE.txt 没装 —— '
              'Apache-2.0 的许可副本必须随技能到设备上');
      expect(lic.readAsStringSync(), contains('Apache License'));
      // 与包里的内容逐字一致
      expect(lic.readAsStringSync(),
          await readAsset('assets/skills/frontend-design/LICENSE.txt'));
    });

    test('② 装过去的文件与 asset 逐字节一致（二进制安全：按字节写、按字节算哈希）',
        () async {
      await BuiltinSkills.install(home);
      for (final name in BuiltinSkills.names) {
        for (final key in await BuiltinSkills.filesFor(name)) {
          final rel = key.substring('assets/skills/$name/'.length);
          final onDisk = File('$home/skills/$name/$rel').readAsBytesSync();
          final asset = await bytesOfAsset(key);
          expect(onDisk.length, asset.length, reason: '$key 字节数不一致');
          expect(onDisk, asset, reason: '$key 内容不一致');
        }
      }
    });

    test('清单写成 v2：按文件记哈希', () async {
      await BuiltinSkills.install(home);
      final m = readManifest();
      expect(m['version'], 2);
      final owned = m['owned'] as Map<String, dynamic>;
      final fd = owned['frontend-design'] as Map<String, dynamic>;
      expect(fd.keys, containsAll(<String>['SKILL.md', 'LICENSE.txt']));
      expect((fd['SKILL.md'] as String).length, 64, reason: '应该是 sha256 十六进制');
    });
  });

  group('幂等与"用户改过就让位"', () {
    test('③ 再装一次：没有变化就不动（installed/updated 都是 0）', () async {
      await BuiltinSkills.install(home);
      final before = File('$home/skills/make-slides/SKILL.md').lastModifiedSync();
      final r = await BuiltinSkills.install(home);
      expect(r.installed, 0);
      expect(r.updated, 0);
      expect(r.keptUser, 0);
      expect(File('$home/skills/make-slides/SKILL.md').lastModifiedSync(), before,
          reason: '没变化还去写一遍 = 无谓 IO，也会让"文件被改过"的判定失去意义');
    });

    test('④ 用户改了一个文件 → 整个技能让位（不许覆盖，也不许补别的文件）', () async {
      await BuiltinSkills.install(home);
      const skill = 'frontend-design';
      const mine = '# 我自己改的\n用户手写的内容\n';
      File('$home/skills/$skill/SKILL.md').writeAsStringSync(mine);
      // 制造"我们记过、但用户删了"的另一个文件，验证不会被偷偷补回来
      File('$home/skills/$skill/LICENSE.txt').deleteSync();

      final r = await BuiltinSkills.install(home);
      expect(r.keptUser, greaterThanOrEqualTo(1));
      expect(File('$home/skills/$skill/SKILL.md').readAsStringSync(), mine,
          reason: '用户的修改被冲掉了');
      expect(File('$home/skills/$skill/LICENSE.txt').existsSync(), isFalse,
          reason: '用户删掉的随包文件不该被偷偷恢复（否则等于没尊重"让位"）');
      final owned = readManifest()['owned'] as Map<String, dynamic>;
      expect(owned.containsKey(skill), isFalse,
          reason: '让位之后不该再跟踪它（否则下次又会被当成"我们的"覆盖）');
    });

    test('④ 让位是**按技能**的，不会连累别的技能继续更新', () async {
      await BuiltinSkills.install(home);
      File('$home/skills/study-cards/SKILL.md').writeAsStringSync('用户版');
      // 删掉另一个技能的文件，模拟"包里多了一个文件"的升级场景
      File('$home/skills/make-image/SKILL.md').deleteSync();

      await BuiltinSkills.install(home);
      // study-cards 让位 → 保留用户版
      expect(File('$home/skills/study-cards/SKILL.md').readAsStringSync(), '用户版');
      // make-image 是"我们记过的文件被删" → 也让位（不恢复）
      expect(File('$home/skills/make-image/SKILL.md').existsSync(), isFalse);
      // 另一个没动过的技能照常可用
      expect(File('$home/skills/weekly-report/SKILL.md').existsSync(), isTrue);
    });
  });

  group('⑥ 老清单（v1）平滑升级', () {
    test('v1 只记了 SKILL.md 的哈希 → 不误判成"用户改过"，且**新增文件会补齐**',
        () async {
      // 先造一个"老版本装出来的设备状态"：只有 SKILL.md，清单是 v1 格式
      const skill = 'frontend-design';
      final dir = Directory('$home/skills/$skill')..createSync(recursive: true);
      final skillText = await readAsset('assets/skills/$skill/SKILL.md');
      File('${dir.path}/SKILL.md').writeAsStringSync(skillText);
      File(BuiltinSkills.manifestPath(home)).writeAsStringSync(jsonEncode({
        'version': 1,
        'owned': {skill: await shaOfAsset('assets/skills/$skill/SKILL.md')},
      }));

      final r = await BuiltinSkills.install(home);
      expect(r.keptUser, 0, reason: 'v1 清单被误判成用户改动 → 技能将永远不再更新');
      // 新增的 LICENSE.txt 应该被补齐（这就是"整目录安装"对老用户的意义）
      expect(File('$home/skills/$skill/LICENSE.txt').existsSync(), isTrue);
      // SKILL.md 内容仍然是包里那份
      expect(File('$home/skills/$skill/SKILL.md').readAsStringSync(), skillText);
    });

    test('v1 清单 + 用户真的改过 SKILL.md → 仍然要让位（不能借"迁移"之名覆盖）',
        () async {
      const skill = 'make-slides';
      final dir = Directory('$home/skills/$skill')..createSync(recursive: true);
      File('${dir.path}/SKILL.md').writeAsStringSync('用户自己写的一版');
      File(BuiltinSkills.manifestPath(home)).writeAsStringSync(jsonEncode({
        'version': 1,
        'owned': {skill: await shaOfAsset('assets/skills/$skill/SKILL.md')},
      }));

      await BuiltinSkills.install(home);
      expect(File('${dir.path}/SKILL.md').readAsStringSync(), '用户自己写的一版');
    });
  });

  group('健壮性', () {
    test('坏清单（不是 JSON）→ 按空处理，照常安装而不是崩', () async {
      File(BuiltinSkills.manifestPath(home)).writeAsStringSync('{这不是 json');
      final r = await BuiltinSkills.install(home);
      expect(r.errors, isEmpty);
      expect(File('$home/skills/make-slides/SKILL.md').existsSync(), isTrue);
    });

    test('DSH_HOME 为空 → 明确报出来，不静默成功', () async {
      final r = await BuiltinSkills.install('   ');
      expect(r.installed, 0);
      expect(r.errors, isNotEmpty);
    });
  });
}
