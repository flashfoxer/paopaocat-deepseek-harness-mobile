import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_mobile/local/model_downloader.dart';
import 'package:dsh_mobile/local/model_manifest.dart';
import 'package:dsh_mobile/local/model_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用真实 HTTP 服务器测下载器：断点续传、Range 被忽略、换源、校验。
///
/// 为什么不用 mock：这里要验证的正是**协议层行为**（206/200 的语义差别、
/// Content-Length 与实际字节不一致、连接中途断开）。mock 掉 socket 就测不到了。

/// 300 KB 的确定性内容（可复现哈希，不要随机）。
final Uint8List kPayload = Uint8List.fromList(
    List<int>.generate(300 * 1024, (i) => (i * 31 + 7) & 0xFF));

String get kPayloadSha => sha256.convert(kPayload).toString();

class Harness {
  Harness(this.server);

  final HttpServer server;
  int rangeResponses = 0;
  int fullResponses = 0;
  int? lastRangeStart;
  int boomCount = 0;

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> close() => server.close(force: true);
}

Future<Harness> startServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final h = Harness(server);
  server.listen((req) => unawaited(_serve(req, h)));
  return h;
}

Future<void> _serve(HttpRequest req, Harness h) async {
  final path = req.uri.path;
  final res = req.response;

  Future<void> full() async {
    h.fullResponses++;
    res.headers.contentLength = kPayload.length;
    res.add(kPayload);
    await res.close();
  }

  switch (path) {
    case '/boom':
      h.boomCount++;
      res.statusCode = HttpStatus.internalServerError;
      await res.close();
      return;
    // 探测（带 Range）能过，真正下载（不带 Range）报 500 —— 模拟"换源"最真实的场景。
    case '/half':
      if (req.headers.value(HttpHeaders.rangeHeader) == null) {
        h.boomCount++;
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
        return;
      }
      break;
    case '/slow':
      await Future<void>.delayed(const Duration(milliseconds: 80));
      break;
    // 故意忽略 Range：永远整段 200。下载器必须丢掉 .part 重写，不能接着拼。
    case '/norange':
      await full();
      return;
    // "内容比清单短"这种坏源：用 chunked 正常结束，但**只发一半**。
    // ⚠️ 别用 `contentLength = 全长 + 只写一半`：那会让服务器自己抛
    // HttpException（"Content size below specified contentLength"），
    // 变成测试骨架的异步错误，测不到下载器的行为。
    case '/truncate':
      h.fullResponses++;
      res.headers.chunkedTransferEncoding = true;
      res.add(kPayload.sublist(0, kPayload.length ~/ 2));
      await res.close();
      return;
  }

  final range = req.headers.value(HttpHeaders.rangeHeader);
  if (range == null) {
    await full();
    return;
  }
  final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
  if (m == null) {
    res.statusCode = HttpStatus.badRequest;
    await res.close();
    return;
  }
  final start = int.parse(m.group(1)!);
  final end =
      m.group(2)!.isEmpty ? kPayload.length - 1 : int.parse(m.group(2)!);
  final slice = kPayload.sublist(start, end + 1);
  h.rangeResponses++;
  h.lastRangeStart = start;
  res.statusCode = HttpStatus.partialContent;
  res.headers.set(
      HttpHeaders.contentRangeHeader, 'bytes $start-$end/${kPayload.length}');
  res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  res.headers.contentLength = slice.length;
  res.add(slice);
  await res.close();
}

OnDeviceModel entryWith(
  List<ModelSource> sources, {
  int? bytes,
  String? sha,
  String fileName = 'test-model.gguf',
  List<ModelCompanion> companions = const <ModelCompanion>[],
}) =>
    OnDeviceModel(
      id: 'test-model',
      family: 'test-model',
      name: '测试模型',
      kind: 'text',
      engine: 'llama.cpp',
      format: 'gguf',
      quant: 'Q4_K_M',
      fileName: fileName,
      bytes: bytes ?? kPayload.length,
      sha256: sha,
      license: 'Apache-2.0',
      minRamGb: 4,
      sources: sources,
      companions: companions,
    );

void main() {
  late Directory tmp;
  late ModelDownloader dl;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsh-model-test-');
    // probeBytes 调小：测速只需要证明"谁快"，不需要真下 512 KB。
    dl = ModelDownloader(dir: tmp.path, probeBytes: 16 * 1024);
  });

  tearDown(() async {
    dl.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File target(String name) => File('${tmp.path}/$name');
  File part(String name) => File('${tmp.path}/$name.part');

  test('完整下载：内容一致、sha256 通过、不留 .part', () async {
    final h = await startServer();
    addTearDown(h.close);
    final entry = entryWith([
      ModelSource(label: 'ok', url: h.url('/ok').toString()),
    ], sha: kPayloadSha);

    final progress = <ModelDownloadProgress>[];
    final r = await dl.download(entry, onProgress: progress.add);

    expect(r.bytes, kPayload.length);
    expect(r.hashVerified, isTrue);
    expect(r.resumed, isFalse);
    expect(r.sourceLabel, 'ok');
    expect(target(entry.fileName).readAsBytesSync(), kPayload);
    expect(part(entry.fileName).existsSync(), isFalse,
        reason: '.part 必须被 rename 走');
    expect(progress, isNotEmpty);
    expect(progress.last.fraction, 1.0);
  });

  test('断点续传：已有 1/3 的 .part，就只补剩下的部分', () async {
    final h = await startServer();
    addTearDown(h.close);
    final entry = entryWith([
      ModelSource(label: 'ok', url: h.url('/ok').toString()),
    ], sha: kPayloadSha);

    final cut = kPayload.length ~/ 3;
    part(entry.fileName).writeAsBytesSync(kPayload.sublist(0, cut));

    final r = await dl.download(entry);

    expect(r.resumed, isTrue, reason: '这次真的用了 Range 续传');
    expect(h.lastRangeStart, cut, reason: '必须从断点开始，不是从 0');
    expect(target(entry.fileName).readAsBytesSync(), kPayload);
    expect(h.rangeResponses, greaterThanOrEqualTo(1));
  });

  test('服务器不认 Range：丢弃旧 .part 从头写，不能拼出坏文件', () async {
    final h = await startServer();
    addTearDown(h.close);
    final entry = entryWith([
      ModelSource(label: 'norange', url: h.url('/norange').toString()),
    ], sha: kPayloadSha);

    // 故意塞一段**错误内容**当旧 .part：如果实现是"接着写"，哈希必然对不上。
    part(entry.fileName).writeAsBytesSync(List<int>.filled(1000, 9));

    final r = await dl.download(entry);

    expect(r.resumed, isFalse, reason: '服务器返回 200，本次是从头写的');
    expect(r.hashVerified, isTrue);
    expect(target(entry.fileName).readAsBytesSync(), kPayload);
  });

  test('sha256 不匹配：抛错、不留正式文件、不留 .part', () async {
    final h = await startServer();
    addTearDown(h.close);
    final entry = entryWith([
      ModelSource(label: 'ok', url: h.url('/ok').toString()),
    ], sha: 'f' * 64);

    await expectLater(
      dl.download(entry),
      throwsA(isA<ModelDownloadException>()
          .having((e) => e.message, 'message', contains('校验失败'))),
    );
    expect(target(entry.fileName).existsSync(), isFalse);
    expect(part(entry.fileName).existsSync(), isFalse,
        reason: '坏文件要删掉，别留着重试时又用上');
  });

  test('体积与清单不符：不落正式文件（可续传重试）', () async {
    final h = await startServer();
    addTearDown(h.close);
    final entry = entryWith([
      ModelSource(label: 'ok', url: h.url('/ok').toString()),
    ], bytes: kPayload.length + 4096);

    await expectLater(
        dl.download(entry), throwsA(isA<ModelDownloadException>()));
    expect(target(entry.fileName).existsSync(), isFalse);
  });

  test('主源在下载阶段挂掉 → 自动换到备用源', () async {
    final h = await startServer();
    addTearDown(h.close);
    final entry = entryWith([
      ModelSource(label: 'half（探测能过、下载报错）', url: h.url('/half').toString()),
      ModelSource(label: 'slow（慢但可用）', url: h.url('/slow').toString()),
    ], sha: kPayloadSha);

    final r = await dl.download(entry);

    expect(h.boomCount, greaterThanOrEqualTo(1), reason: '主源确实被尝试过并失败');
    expect(r.sourceLabel, contains('slow'));
    expect(target(entry.fileName).readAsBytesSync(), kPayload);
  });

  test('所有源都失败 → 明确报错，不假装成功', () async {
    final h = await startServer();
    addTearDown(h.close);
    final entry = entryWith([
      ModelSource(label: 'boom1', url: h.url('/boom').toString()),
      ModelSource(label: 'boom2', url: h.url('/truncate').toString()),
    ]);

    await expectLater(
      dl.download(entry),
      throwsA(isA<ModelDownloadException>()
          .having((e) => e.message, 'message', contains('所有下载源'))),
    );
    expect(target(entry.fileName).existsSync(), isFalse);
  });

  test('测速：把快的源排在前面', () async {
    final h = await startServer();
    addTearDown(h.close);
    final fast = ModelSource(label: 'fast', url: h.url('/ok').toString());
    final slow = ModelSource(label: 'slow', url: h.url('/slow').toString());

    final ranked = await dl.rankSources(<ModelSource>[slow, fast]);

    expect(ranked.first.label, 'fast');
    expect(ranked.last.label, 'slow');
  });

  test('测速把连不上的源放最后（仍会尝试，不当成"没有源"）', () async {
    final h = await startServer();
    addTearDown(h.close);
    final dead = ModelSource(label: 'dead', url: h.url('/boom').toString());
    final ok = ModelSource(label: 'ok', url: h.url('/ok').toString());

    final ranked = await dl.rankSources(<ModelSource>[dead, ok]);

    expect(ranked.length, 2);
    expect(ranked.first.label, 'ok');
    expect(ranked.last.label, 'dead');
  });

  test('取消：立刻停，不再换源重下', () async {
    final h = await startServer();
    addTearDown(h.close);
    final entry = entryWith([
      ModelSource(label: 'ok', url: h.url('/ok').toString()),
    ]);
    final token = DownloadCancelToken()..cancel();

    await expectLater(
      dl.download(entry, cancel: token),
      throwsA(isA<ModelDownloadException>()
          .having((e) => e.message, 'message', contains('取消'))),
    );
  });

  test('sha256OfFile 与 crypto 一致（分块哈希不能算错）', () async {
    final f = target('hash-me.bin')..writeAsBytesSync(kPayload);
    expect(await ModelDownloader.sha256OfFile(f.path), kPayloadSha);
  });

  group('登记表 LocalModelStore', () {
    test('登记 / 读取 / 体积 / 卸载，且能识别文件缺失', () async {
      final store = LocalModelStore(dir: tmp.path);
      final entry = entryWith(const [
        ModelSource(label: 'ok', url: 'https://example.com/x.gguf'),
      ]);

      // 文件不存在时不算已装好。
      await store.register(InstalledModel.fromEntry(entry,
          sha256: null, bytes: kPayload.length));
      expect(store.fileOk((await store.get('test-model'))!), isFalse);

      target(entry.fileName).writeAsBytesSync(kPayload);
      expect(store.fileOk((await store.get('test-model'))!), isTrue);
      expect(await store.totalBytes(), kPayload.length);

      // 大小被改动 → 判定为损坏，不骗 UI。
      target(entry.fileName).writeAsBytesSync(kPayload.sublist(0, 100));
      expect(store.fileOk((await store.get('test-model'))!), isFalse);

      await store.remove('test-model');
      expect(await store.get('test-model', refresh: true), isNull);
      expect(target(entry.fileName).existsSync(), isFalse);
    });

    test('登记表坏掉时当作空表，不炸', () async {
      File('${tmp.path}/registry.json').writeAsStringSync('{不是 JSON');
      final store = LocalModelStore(dir: tmp.path);
      expect(await store.list(), isEmpty);
    });

    test('登记表能被重新读回（字段不掉）', () async {
      final store = LocalModelStore(dir: tmp.path);
      final entry = entryWith(
          const [ModelSource(label: 'ok', url: 'https://example.com/x.gguf')]);
      await store.register(InstalledModel.fromEntry(entry,
          sha256: kPayloadSha, bytes: kPayload.length, sourceLabel: 'ok'));

      final reloaded =
          await LocalModelStore(dir: tmp.path).get('test-model', refresh: true);
      expect(reloaded, isNotNull);
      expect(reloaded!.sha256, kPayloadSha);
      expect(reloaded.bytes, kPayload.length);
      expect(reloaded.sourceLabel, 'ok');
      expect(reloaded.engine, 'llama.cpp');
      expect(jsonDecode(File('${tmp.path}/registry.json').readAsStringSync()),
          isA<Map<String, dynamic>>());
    });
  });
  test('伴生文件（mmproj）会跟着一起下，进度分母是总量', () async {
    final h = await startServer();
    addTearDown(h.close);
    final entry = entryWith(
      [ModelSource(label: 'ok', url: h.url('/ok').toString())],
      companions: <ModelCompanion>[
        ModelCompanion(
          fileName: 'mmproj-test.gguf',
          bytes: kPayload.length,
          sources: <ModelSource>[
            ModelSource(label: 'ok', url: h.url('/ok').toString()),
          ],
        ),
      ],
    );
    expect(entry.totalBytes, kPayload.length * 2, reason: '总大小要算上伴生文件');

    final totals = <int>[];
    await dl.download(entry, onProgress: (p) => totals.add(p.total));

    // 两个文件都落到盘上、字节数都对。
    expect(target(entry.fileName).readAsBytesSync(), kPayload);
    expect(target('mmproj-test.gguf').readAsBytesSync(), kPayload,
        reason: '视觉编码器必须一起下完 —— 只下本体的话多模态看不了图');

    // 进度分母始终是"本体 + 编码器"，不会先冲到 100% 再跳回 0%。
    expect(totals, isNotEmpty);
    expect(totals.every((t) => t == kPayload.length * 2), isTrue,
        reason: '进度分母要一直是总量，否则进度条会先满再跳回去');
  });

  test('伴生文件下不全 → 抛错，不留半个正式文件', () async {
    final h = await startServer();
    addTearDown(h.close);
    final entry = entryWith(
      [ModelSource(label: 'ok', url: h.url('/ok').toString())],
      companions: <ModelCompanion>[
        ModelCompanion(
          fileName: 'mmproj-bad.gguf',
          // 故意写成比服务器能给的更多：体积校验必然不过。
          bytes: kPayload.length + 4096,
          sources: <ModelSource>[
            ModelSource(label: 'ok', url: h.url('/ok').toString()),
          ],
        ),
      ],
    );

    await expectLater(
      dl.download(entry),
      throwsA(isA<ModelDownloadException>()),
    );
    expect(target('mmproj-bad.gguf').existsSync(), isFalse,
        reason: '校验没过的伴生文件不能以正式文件名留下');
  });

  group('requireHash：清单要求"必须有哈希"时不许静默放行（审计 P1-10）', () {
    test('requireHash=true 且清单没有 sha256 → 抛错，并删掉下好的半截', () async {
      final h = await startServer();
      addTearDown(h.close);
      final entry = entryWith([
        ModelSource(label: 'ok', url: h.url('/ok').toString()),
      ]); // sha 为 null

      await expectLater(
        dl.download(entry, requireHash: true),
        throwsA(isA<ModelDownloadException>()),
      );
      expect(target(entry.fileName).existsSync(), isFalse,
          reason: '被拒绝的下载不能留下正式文件');
      expect(part(entry.fileName).existsSync(), isFalse,
          reason: '半截 .part 也要删：下次续传会把它当成"已下好的部分"，'
              '而它恰恰是没被校验过的那一份');
    });

    test('requireHash=false（默认）且没有 sha256 → 放行，但**如实**标为未校验', () async {
      final h = await startServer();
      addTearDown(h.close);
      final entry = entryWith([
        ModelSource(label: 'ok', url: h.url('/ok').toString()),
      ]);

      final r = await dl.download(entry);

      expect(r.hashVerified, isFalse,
          reason: '没有哈希就不能声称"已校验" —— 界面据此显示"仅体积校验"');
      expect(target(entry.fileName).existsSync(), isTrue);
      expect(target(entry.fileName).readAsBytesSync(), kPayload);
    });

    test('requireHash=true 且有正确 sha256 → 正常装上（开关不能误伤有哈希的条目）', () async {
      final h = await startServer();
      addTearDown(h.close);
      final entry = entryWith([
        ModelSource(label: 'ok', url: h.url('/ok').toString()),
      ], sha: kPayloadSha);

      final r = await dl.download(entry, requireHash: true);

      expect(r.hashVerified, isTrue);
      expect(target(entry.fileName).existsSync(), isTrue);
    });
  });
}
