/// 知识库（本地大模型栏目下的「知识库」）的回归测试。
///
/// 这里锁住三件容易**悄悄坏掉**的事：
///
///   1. **清单解析要能容错** —— 磁盘/资产里的 JSON 坏掉时退回空清单，而不是把整页弄崩。
///   2. **落盘纪律**：登记 → 列出 → 删除要成对；`meta.json` 在、资料文件却被手删时
///      **不要列出来**（否则用户点一下就报错，比看不见更糟）。
///   3. **清单声明的随包样例必须真的在包里** —— 只写清单不写资源，是 Flutter
///      打包最常见的翻车方式（pubspec 里那段注释就是为此写的）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/local/kb_manifest.dart';
import 'package:dsh_mobile/local/kb_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('知识库清单解析', () {
    test('正常清单：包、字段、多源排序都对', () {
      final m = KbManifest.parse(jsonEncode(<String, Object>{
        'version': 1,
        'packs': <Object>[
          <String, Object>{
            'id': 'p1',
            'name': '测试库',
            'kind': 'encyclopedia',
            'format': 'json-array',
            'textField': 'completion',
            'bundled': false,
            'fileName': 'a.json',
            'bytes': 100,
            'entries': 7,
            'license': 'CC BY-SA 4.0',
            'note': '说明',
            'sources': <Object>[
              <String, Object>{'label': '慢源', 'url': 'https://b/x', 'priority': 5},
              <String, Object>{'label': '快源', 'url': 'https://a/x', 'priority': 0},
            ],
          },
        ],
      }));
      expect(m.packs.length, 1);
      final p = m.packs.first;
      expect(p.id, 'p1');
      expect(p.textField, 'completion');
      expect(p.entries, 7);
      // 源必须按 priority 从小到大试 —— 顺序错了就会先连老大难的源。
      expect(p.sortedSources.map((s) => s.label).toList(), <String>['快源', '慢源']);
      expect(m.byId('p1')!.name, '测试库');
      expect(m.byId('不存在'), isNull);
    });

    test('坏 JSON 退回空清单（不抛、不让整页崩）', () {
      expect(KbManifest.parse('{ 这不是 json').packs, isEmpty);
      expect(KbManifest.parse('[]').packs, isEmpty);
    });

    test('缺 id / fileName 的条目被丢掉，不污染列表', () {
      final m = KbManifest.parse(jsonEncode(<String, Object>{
        'packs': <Object>[
          <String, Object>{'id': 'ok', 'fileName': 'a.json'},
          <String, Object>{'name': '缺 id'},
          <String, Object>{'id': '缺文件名'},
        ],
      }));
      expect(m.packs.map((p) => p.id).toList(), <String>['ok']);
    });
  });

  group('知识库落盘', () {
    test('登记 → 列出 → 删除', () async {
      final root = Directory.systemTemp.createTempSync('kb_test_');
      final store = KbStore(dshHome: root.path);
      final d = Directory(store.dirOf('p1'))..createSync(recursive: true);
      File('${d.path}/a.json').writeAsStringSync('[]');

      await store.register(
        id: 'p1',
        name: '测试库',
        fileName: 'a.json',
        bytes: 2,
        entries: 0,
        license: '',
        source: 'import',
      );
      final list = await store.list();
      expect(list.length, 1);
      expect(list.first.name, '测试库');
      expect(list.first.source, 'import');
      expect(list.first.entries, 0);
      expect(store.isInstalled(list, 'p1'), isTrue);

      await store.delete('p1');
      expect(await store.list(), isEmpty);
    });

    test('meta 在、资料文件被手删 → 不列出来（免得点了报错）', () async {
      final root = Directory.systemTemp.createTempSync('kb_test_');
      final store = KbStore(dshHome: root.path);
      final d = Directory(store.dirOf('p2'))..createSync(recursive: true);
      final f = File('${d.path}/gone.json')..writeAsStringSync('[]');
      await store.register(
        id: 'p2',
        name: '文件后来没了',
        fileName: 'gone.json',
        bytes: 2,
        entries: 0,
        license: '',
        source: 'download',
      );
      f.deleteSync();
      expect(await store.list(), isEmpty);
    });

    test('随包样例：installBundled 写文件并登记成 bundled', () async {
      final root = Directory.systemTemp.createTempSync('kb_test_');
      final store = KbStore(dshHome: root.path);
      final kb = await store.installBundled(
        const KbPack(
          id: 'sample',
          name: '样例',
          kind: 'encyclopedia',
          format: 'json-array',
          textField: 'completion',
          bundled: true,
          fileName: 'sample.json',
          bytes: 0,
          entries: 3,
          license: 'CC BY-SA 4.0',
          note: '',
          sources: <KbSource>[],
        ),
        read: () async => utf8.encode('[{"completion":"甲"}]'),
      );
      expect(kb.source, 'bundled');
      expect(kb.bytes, greaterThan(0));
      expect(File(kb.path).existsSync(), isTrue);
      expect((await store.list()).first.entries, 3);
    });
  });

  group('去重与「参与检索」开关', () {
    test('按 sha256 能找到同内容的包（空 sha 不算命中）', () async {
      final root = Directory.systemTemp.createTempSync('kb_dup_');
      final store = KbStore(dshHome: root.path);
      final d = Directory(store.dirOf('p1'))..createSync(recursive: true);
      File('${d.path}/a.json').writeAsStringSync('[]');
      await store.register(
        id: 'p1',
        name: '甲',
        fileName: 'a.json',
        bytes: 2,
        entries: 0,
        license: '',
        source: 'import',
        sha256: 'abc123',
      );
      final list = await store.list();
      expect(store.findBySha(list, 'abc123')!.name, '甲');
      expect(store.findBySha(list, 'ABC123')!.name, '甲'); // 大小写不敏感
      expect(store.findBySha(list, 'zzz'), isNull);
      // 空 sha 绝不能互相匹配 —— 下载/随包的包没有 sha，否则会被当成"重复"
      expect(store.findBySha(list, '   '), isNull);
    });

    test('开关能落盘：关掉再读回来还是关的（默认是开）', () async {
      final root = Directory.systemTemp.createTempSync('kb_en_');
      final store = KbStore(dshHome: root.path);
      final d = Directory(store.dirOf('p2'))..createSync(recursive: true);
      File('${d.path}/b.json').writeAsStringSync('[]');
      final kb = await store.register(
        id: 'p2',
        name: '乙',
        fileName: 'b.json',
        bytes: 2,
        entries: 0,
        license: '',
        source: 'import',
      );
      expect(kb.enabled, isTrue);
      await store.setEnabled(kb, false);
      final back = (await store.list()).first;
      expect(back.enabled, isFalse);
      await store.setEnabled(back, true);
      expect((await store.list()).first.enabled, isTrue);
    });
  });

  group('知识库资产（防"只写清单不写文件"、防内置样本偷偷回来）', () {
    test('assets/kb 下的清单在、能解析，且不再有随包样例', () async {
      final manifestFile = File('assets/kb/kb_manifest.json');
      expect(manifestFile.existsSync(), isTrue,
          reason: '知识库清单不在仓库里');
      final m = KbManifest.parse(await manifestFile.readAsString());
      expect(m.packs, isNotEmpty, reason: '清单里一个包都没有');

      // 用户 2026-10-09 决定：**不内置样本库**。这里反过来钉住它 ——
      // 谁要是往清单里加了随包样例，这条会失败，逼他先看合规结论：
      // 原先那 400 条被逐条读出 5 条不宜预置的内容，而关键词扫描全部漏判
      // （见 docs/KB-COMPLIANCE-2026-10-09.md）。
      final bundled = m.packs.where((p) => p.bundled).toList();
      expect(bundled, isEmpty,
          reason: '清单里不应再有随包样例（用户要求：样本库不要内置）');

      // 被删掉的那份样例文件也不该再出现在 assets/kb/ 下（否则等于没删）。
      expect(File('assets/kb/sample-zhwiki.json').existsSync(), isFalse,
          reason: '内置样本已删除，不该再回到 assets/kb/');

      // 若将来确实要放回随包样例：文件必须真的在 assets/kb/ 下，
      // 否则界面上「装入样例」必然失败。
      for (final p in bundled) {
        final f = File('assets/kb/${p.fileName}');
        expect(f.existsSync(), isTrue, reason: '随包样例缺文件：${p.fileName}');
        expect(f.lengthSync(), greaterThan(0));
      }
      // 非随包的包必须有下载源（否则"可下载"里点了也没用）。
      for (final p in m.packs.where((p) => !p.bundled)) {
        expect(p.sources, isNotEmpty, reason: '${p.id} 没有下载源');
        expect(p.sources.first.url.startsWith('http'), isTrue);
      }
    });
  });
}
