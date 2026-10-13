import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_mobile/local/model_importer.dart';
import 'package:dsh_mobile/local/model_manifest.dart';
import 'package:dsh_mobile/local/model_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 导入器测试：不碰真实平台通道，用一个**假的选择器**模拟原生侧的行为
/// （把文件写进目标目录 + 回一份原生格式的结果）。
///
/// 这样测的是我们自己的纪律：成功要登记、取消不算失败、批量里一个坏的不拖垮其余的、
/// 清单外的文件只落盘不登记。

OnDeviceModel _model(String id, String fileName,
        {int bytes = 100, String? sha}) =>
    OnDeviceModel(
      id: id,
      family: id,
      name: id,
      kind: 'text',
      engine: 'llama.cpp',
      format: 'gguf',
      fileName: fileName,
      bytes: bytes,
      quant: 'Q4',
      license: 'Apache-2.0',
      minRamGb: 4,
      sha256: sha,
      sources: const <ModelSource>[
        ModelSource(label: 'x', url: 'https://example.com/x.gguf'),
      ],
    );

Map<String, dynamic> _okNative(String file,
        {int bytes = 100,
        bool matched = true,
        bool verified = true,
        String? sha}) =>
    <String, dynamic>{
      'ok': true,
      'file': file,
      'path': '/tmp/whatever/$file',
      'bytes': bytes,
      'sha256': sha ?? 'a' * 64,
      'matched': matched,
      'verified': verified,
    };

Map<String, dynamic> _errNative(String file, String code, String msg) =>
    <String, dynamic>{
      'ok': false,
      'file': file,
      'code': code,
      'message': msg,
      'bytes': 0,
    };

void main() {
  late Directory tmp;
  late LocalModelStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsh-import-test-');
    store = LocalModelStore(dir: tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ModelImporter importerWith(ModelFilePicker picker) =>
      ModelImporter(dir: tmp.path, store: store, picker: picker);

  test('导入成功 → 登记为已安装，来源标成"本地文件导入"', () async {
    final entry = _model('qwen', 'qwen.gguf', bytes: 100);
    late List<Map<String, dynamic>> got;
    final importer =
        importerWith(({required targetDir, required expected}) async {
      got = expected;
      // 模拟原生：把文件真的写进去
      File('$targetDir/qwen.gguf').writeAsBytesSync(Uint8List(100));
      return <Map<String, dynamic>>[_okNative('qwen.gguf', bytes: 100)];
    });

    final s = await importer.importFromDevice(<OnDeviceModel>[entry]);

    expect(s.cancelled, isFalse);
    expect(s.succeeded.length, 1);
    expect(s.failed, isEmpty);
    expect(s.message, contains('1'));
    // 期望值传下去了（原生要靠它校验）
    expect(got.single['fileName'], 'qwen.gguf');
    expect(got.single['bytes'], 100);
    // 登记进 registry
    final saved = await store.get('qwen', refresh: true);
    expect(saved, isNotNull);
    expect(saved!.sourceLabel, '本地文件导入');
    expect(saved.bytes, 100);
  });

  test('用户取消 → cancelled，不是失败，且不登记任何东西', () async {
    final importer =
        importerWith(({required targetDir, required expected}) async => null);
    final s =
        await importer.importFromDevice(<OnDeviceModel>[_model('a', 'a.gguf')]);

    expect(s.cancelled, isTrue);
    expect(s.outcomes, isEmpty);
    expect(s.message, contains('取消'));
    expect(await store.list(refresh: true), isEmpty);
  });

  test('批量：一个坏文件不拖垮其余，成功的照样登记', () async {
    final a = _model('a', 'a.gguf');
    final b = _model('b', 'b.gguf');
    final c = _model('c', 'c.gguf');
    final importer =
        importerWith(({required targetDir, required expected}) async {
      File('$targetDir/a.gguf').writeAsBytesSync(Uint8List(100));
      File('$targetDir/c.gguf').writeAsBytesSync(Uint8List(100));
      return <Map<String, dynamic>>[
        _okNative('a.gguf'),
        _errNative('b.gguf', 'HASH_MISMATCH', 'sha256 校验失败，已丢弃该文件'),
        _okNative('c.gguf'),
      ];
    });

    final s = await importer.importFromDevice(<OnDeviceModel>[a, b, c]);

    expect(s.succeeded.length, 2);
    expect(s.failed.length, 1);
    expect(s.failed.single.errorCode, 'HASH_MISMATCH');
    expect(s.message, contains('成功 2'));
    expect(s.message, contains('失败 1'));
    expect(await store.get('a', refresh: true), isNotNull);
    expect(await store.get('c', refresh: true), isNotNull);
    expect(await store.get('b', refresh: true), isNull, reason: '失败的不许登记');
  });

  test('清单外的文件：能落盘计入成功，但不登记（避免 UI 显示成"已安装某模型"）', () async {
    final known = _model('known', 'known.gguf');
    final importer =
        importerWith(({required targetDir, required expected}) async {
      File('$targetDir/stranger.gguf').writeAsBytesSync(Uint8List(50));
      return <Map<String, dynamic>>[
        _okNative('stranger.gguf', bytes: 50, matched: false, verified: false),
      ];
    });

    final s = await importer.importFromDevice(<OnDeviceModel>[known]);

    expect(s.succeeded.length, 1);
    expect(s.succeeded.single.matched, isFalse);
    expect(s.succeeded.single.verified, isFalse);
    expect(await store.list(refresh: true), isEmpty);
  });

  test('文件名大小写不同也能匹配登记（SAF 给的名字大小写不可控）', () async {
    final entry = _model('mixed', 'Qwen2.5-1.5B-Q4_K_M.GGUF');
    final importer =
        importerWith(({required targetDir, required expected}) async {
      return <Map<String, dynamic>>[_okNative('qwen2.5-1.5b-q4_k_m.gguf')];
    });

    final s = await importer.importFromDevice(<OnDeviceModel>[entry]);
    expect(s.succeeded.length, 1);
    expect(await store.get('mixed', refresh: true), isNotNull);
  });

  test('sha256 命中时如实带回来（UI 要能说"已校验"）', () async {
    final entry = _model('h', 'h.gguf', sha: 'b' * 64);
    final importer =
        importerWith(({required targetDir, required expected}) async {
      expect(expected.single['sha256'], 'b' * 64, reason: '哈希要传给原生做校验');
      File('$targetDir/h.gguf').writeAsBytesSync(Uint8List(100));
      return <Map<String, dynamic>>[_okNative('h.gguf', sha: 'b' * 64)];
    });

    final s = await importer.importFromDevice(<OnDeviceModel>[entry]);
    expect(s.succeeded.single.verified, isTrue);
    expect((await store.get('h', refresh: true))!.sha256, 'b' * 64);
  });

  test('一条都没选（返回空表）→ 明确说"没选中任何文件"', () async {
    final importer = importerWith((
            {required targetDir, required expected}) async =>
        <Map<String, dynamic>>[]);
    final s =
        await importer.importFromDevice(<OnDeviceModel>[_model('x', 'x.gguf')]);
    expect(s.outcomes, isEmpty);
    expect(s.cancelled, isFalse);
    expect(s.message, contains('没有选中'));
  });
}
