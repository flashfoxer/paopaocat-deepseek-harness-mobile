/// 随包技能（`assets/skills/`）的**本体门禁**。
///
/// ## 为什么值得一条测试
///
/// 技能装不到设备上**不会报错**：App 照常启动、界面照常能用，只是模型手边
/// 少一个流程可用 —— 表现是"它怎么没按我说的做"，而不是任何一条堆栈。
/// 这三件事各有一种静默失效的方式：
///
///   ① `BuiltinSkills.names` 里写了、`assets/skills/<name>/SKILL.md` 却没有
///      → `loadString` 抛异常，被 catch 成一行日志，装机后那个技能**永远不存在**；
///   ② 目录建了、`names` 里没写 → 文件随包进了 APK，但**没人安装它**（同样静默）；
///   ③ `pubspec.yaml` 里漏了这一个目录 → 打包时**不进 APK**（实测：写父目录
///      `- assets/skills/` 不会递归，APK 里一条技能都没有），
///      真机日志才会出现 `Unable to load asset: "assets/skills/<name>/SKILL.md"`。
///
/// 另外钉住**许可**：搬来的两个技能以 Apache-2.0 授权，要求随分发给一份许可副本，
/// 并标注改过 —— 这是"删掉 LICENSE.txt 也没人会发现"的那类回归。
library;

import 'dart:io';

import 'package:dsh_mobile/data/builtin_skills.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:flutter_test/flutter_test.dart';

/// 从 SKILL.md 里取 frontmatter（只认 `---` 包起来的第一段）。
({String name, String description})? _frontmatter(String text) {
  if (!text.startsWith('---')) return null;
  final end = text.indexOf('\n---', 3);
  if (end < 0) return null;
  final fm = text.substring(3, end);
  final name = RegExp(r'^name:\s*"?([^"\n]+)"?\s*$', multiLine: true)
      .firstMatch(fm)
      ?.group(1)
      ?.trim();
  final desc = RegExp(r'^description:\s*"?(.+?)"?\s*$', multiLine: true)
      .firstMatch(fm)
      ?.group(1)
      ?.trim();
  if (name == null || desc == null) return null;
  return (name: name, description: desc);
}

void main() {
  // `rootBundle` 需要 binding（下面那条"asset bundle 里读得出来"要用）。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('随包技能：表 ↔ 文件 ↔ pubspec 三处必须对齐', () {
    test('names 里每一个都有 SKILL.md，且 frontmatter 的 name 与目录名一致', () {
      final problems = <String>[];
      for (final name in BuiltinSkills.names) {
        final f = File(BuiltinSkills.assetPathFor(name));
        if (!f.existsSync()) {
          problems.add('$name：缺 ${f.path}');
          continue;
        }
        final fm = _frontmatter(f.readAsStringSync());
        if (fm == null) {
          problems.add('$name：frontmatter 读不出来（要有 name 与 description）');
          continue;
        }
        if (fm.name != name) {
          problems.add('$name：frontmatter 的 name 写的是 "${fm.name}"（必须与目录名一致）');
        }
        if (fm.description.isEmpty) problems.add('$name：description 是空的');
      }
      expect(problems, isEmpty, reason: '这些技能装不到设备上（or 装了也没法用）：\n  ${problems.join('\n  ')}');
    });

    test('assets/skills/ 下的目录都在 names 里（否则它白随包、没人安装）', () {
      final dir = Directory('assets/skills');
      expect(dir.existsSync(), isTrue, reason: 'assets/skills 不在当前目录');
      final onDisk = dir
          .listSync()
          .whereType<Directory>()
          .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toList()
        ..sort();
      expect(onDisk, isNotEmpty);
      final declared = BuiltinSkills.names.toSet();
      final ghosts = onDisk.where((n) => !declared.contains(n)).toList();
      expect(ghosts, isEmpty,
          reason: '这些目录在 assets/skills/ 里，但没有写进 BuiltinSkills.names —— '
              '它们随包进了 APK 却不会被安装（静默失效）：\n  ${ghosts.join('、')}');
    });

    test('每个技能目录都在 pubspec.yaml 里逐个列出（写父目录不会递归打包）', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final missing = BuiltinSkills.names
          .where((n) => !pubspec.contains('- assets/skills/$n/'))
          .toList();
      expect(missing, isEmpty,
          reason: '这些技能没有在 pubspec.yaml 里逐目录声明 —— 打包时不会进 APK，'
              '真机上只会看到 `Unable to load asset`：\n  ${missing.join('、')}\n'
              '（补 `- assets/skills/<名字>/` 即可；**不能**只写 `- assets/skills/`）');
    });

    test('每个技能都能从 asset bundle 里读出来（pubspec 漏了只有真机才发现）', () async {
      // ⚠️ 这一条与上面的"文件在不在磁盘上"**不是同一件事**：测试进程里
      //    `File('assets/skills/...')` 读的是**源码目录**，而设备上走的是
      //    **打包后的 asset bundle**。pubspec 里漏一个目录时，磁盘上一切正常、
      //    这个测试（用文件读的那条）也会过，只有 bundle 这条会红 ——
      //    这正是"装到手机上才发现 `Unable to load asset`"那个坑。
      for (final name in BuiltinSkills.names) {
        final t = await rootBundle.loadString(BuiltinSkills.assetPathFor(name));
        expect(t, contains('name: $name'),
            reason: '$name 从 asset bundle 里读出来了，但内容不像这个技能');
      }
    });

    test('技能简介要短（每轮都要把名字 + 简介递给模型，长简介是固定开销）', () {
      final tooLong = <String>[];
      var total = 0;
      for (final name in BuiltinSkills.names) {
        final fm = _frontmatter(File(BuiltinSkills.assetPathFor(name)).readAsStringSync());
        final d = fm?.description ?? '';
        total += d.length;
        if (d.length > 60) tooLong.add('$name（${d.length} 字符）');
      }
      expect(tooLong, isEmpty,
          reason: '这些技能的简介超过 60 字符，会变成每一轮的固定开销：\n  ${tooLong.join('、')}');
      // 保护性上限：技能简介合计（每轮都要递给模型，是固定开销）。
      //   * 0.29 那次把 12 条从 927 压到 242；
      //   * 2026-10-12 加两个（frontend-design / discernment-nudge）→ 309；
      //   * 2026-10-12 再加**小说改游戏那 7 个**（一条流水线的七个阶段，
      //     名字必须互相区分得开，否则模型选错阶段）→ 约 503；
      // 所以上限提到 800。涨可以，但要**有意识地涨** —— 这条测试就是那个"意识"。
      expect(total, lessThanOrEqualTo(800),
          reason: '技能简介合计 $total 字符，超过 800 了 —— 每轮固定开销太大，该压了');
    });
  });

  group('⚠️ 磁盘 → 包：子目录也必须进包（这是"死链"的唯一门禁）', () {
    test('磁盘上有的技能文件，asset 包里一个都不能少（含 references/ 与 assets/）', () async {
      // 为什么必须查 **AssetManifest** 而不是查磁盘：
      //   Flutter 的 `- assets/skills/<name>/` 只收**直接子文件**，**不进子目录** ——
      //   所以 `references/xxx.md`、`assets/template.html` 这类文件会**悄悄不进包**，
      //   而技能正文里那些相对路径就成了死链（模型读不到，谁都不会报错）。
      //   2026-10-12 就是这么中招的：7 个小说改游戏技能的 references/ **一个都没进包**，
      //   而当时那条"磁盘上有 references"的测试**照样是绿的**（它查的是磁盘）。
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final bundled = manifest.listAssets().toSet();
      final missing = <String>[];
      for (final name in BuiltinSkills.names) {
        final dir = Directory('assets/skills/$name');
        if (!dir.existsSync()) continue;
        for (final f in dir.listSync(recursive: true).whereType<File>()) {
          // 测试的工作目录就是 app/，所以 f.path 正好就是 asset key
          if (!bundled.contains(f.path)) missing.add(f.path);
        }
      }
      expect(missing, isEmpty,
          reason: '这些文件在磁盘上、但**没进包**（技能正文里的相对路径会变成死链）：\n'
              '  ${missing.take(20).join('\n  ')}\n'
              '（多半是 pubspec 少了某一层：Flutter 的目录声明不进子目录）');
    });
  });

  group('小说改游戏那七个：随包、署名、MIT 副本都在', () {
    const seven = <String>[
      'novel-to-game',
      'novel-game-analyze',
      'game-concept',
      'game-world-design',
      'game-art-direction',
      'game-build',
      'game-qa',
    ];

    test('七个都在随包列表里（缺一个 = 那条流水线断一环）', () {
      for (final n in seven) {
        expect(BuiltinSkills.names, contains(n), reason: '$n 没登记');
      }
    });

    test('每个都带多条 references/（它们是"渐进式披露"的参考文件）', () {
      // ⚠️ 这条同时盯住两件事：① pubspec 必须**逐目录**列（否则 references 进不了包）；
      //    ② 安装器必须**整目录装**（只装 SKILL.md 的话正文里那些引用全是死链）。
      var withRefs = 0;
      for (final n in seven) {
        final dir = Directory('assets/skills/$n/references');
        if (dir.existsSync() && dir.listSync().whereType<File>().isNotEmpty) withRefs += 1;
      }
      expect(withRefs, greaterThanOrEqualTo(5),
          reason: '只有 $withRefs 个技能带 references/ —— 是不是没从上游整目录搬过来？');
    });

    test('MIT 许可副本随包，且正文开头写明来源与"只改了两处"', () {
      final lic = File('assets/skills/novel-to-game/LICENSE.txt');
      expect(lic.existsSync(), isTrue, reason: 'MIT 要求随分发给一份许可副本');
      final t = lic.readAsStringSync();
      expect(t, contains('MIT License'));
      expect(t, contains('NovelToGame contributors'));

      for (final n in seven) {
        final body = File(BuiltinSkills.assetPathFor(n)).readAsStringSync();
        expect(body, contains('NovelToGame v0.4.0'), reason: '$n 没写来源');
        expect(body, contains('MIT'), reason: '$n 没写许可');
        expect(body, contains('只改了两处'), reason: '$n 没写"本 App 改了什么"');
      }
    });
  });

  group('搬来的两个技能：许可与"已修改"标注', () {
    test('frontend-design / discernment-nudge 都在随包列表里', () {
      expect(BuiltinSkills.names, containsAll(<String>['frontend-design', 'discernment-nudge']));
    });

    test('两个都带 Apache-2.0 许可副本（Apache-2.0 要求随分发给一份）', () {
      for (final name in <String>['frontend-design', 'discernment-nudge']) {
        final lic = File('assets/skills/$name/LICENSE.txt');
        expect(lic.existsSync(), isTrue, reason: '$name 少了 LICENSE.txt');
        final t = lic.readAsStringSync();
        expect(t, contains('Apache License'), reason: '$name 的 LICENSE.txt 不是 Apache 许可全文');
        expect(t, contains('Version 2.0'), reason: '$name 的 LICENSE.txt 版本不对');
        expect(t.length, greaterThan(9000), reason: '$name 的 LICENSE.txt 看起来被截断了');
      }
    });

    test('正文里写明来源与"已修改"（原版是英文、且假设有 python/截图能力）', () {
      for (final name in <String>['frontend-design', 'discernment-nudge']) {
        final t = File(BuiltinSkills.assetPathFor(name)).readAsStringSync();
        expect(t, contains('anthropics/skills'), reason: '$name 没写来源');
        expect(t, contains('Apache-2.0'), reason: '$name 没写许可');
        expect(t, contains('修改'), reason: '$name 没标注"已修改"（Apache-2.0 的要求）');
      }
    });

    test('改写必须落在本机真做不到的地方：frontend-design 不许再让人"截图回看"', () {
      final t = File(BuiltinSkills.assetPathFor('frontend-design')).readAsStringSync();
      // 原版有一句 "taking screenshots to review if your environment supports it"
      // —— 本机没有浏览器、也不能截图，所以这里必须是"明确说做不到"的口径
      expect(t, contains('不能截图'), reason: '要把"本机不能截图"如实写进去，否则模型会去试');
    });
  });
}
