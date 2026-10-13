/// 知识库下载器的测试（审计 P0-4：这个文件过去**零测试**）。
///
/// ## 为什么这里必须有测试
///
/// `KbDownloader` 是本仓库**最大的一次网络 IO**（清单里那包 524,489,333 字节 /
/// 254,547 条），而它负责的东西全是"错了就很难查"的：多源切换、`.part` 续传、
/// 体积核对、sha256 核对、取消、rename 落位。
/// 以前 `grep KbDownloader test/` **零命中** —— 一条都没测过。
///
/// 为什么用真实 HTTP 服务器而不是 mock：这一层要验的正是**协议语义**
/// （206 与 200 的区别、Content-Length 说谎、连接中途断开、Range 不被支持）。
/// 把 socket mock 掉就测不到它们了。样板取自 `model_download_test.dart`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_mobile/local/kb_manifest.dart';
import 'package:dsh_mobile/local/kb_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 确定性内容（可复现哈希，不要随机）。
final Uint8List kPayload = Uint8List.fromList(
    List<int>.generate(200 * 1024, (i) => (i * 17 + 3) & 0xFF));
final String kSha = sha256.convert(kPayload).toString();

/// 一份"另外的内容"——长度故意与 [kPayload] 完全一样，用来证明
/// **体积校验挡不住它、只有 sha256 能**。
final Uint8List kSameSizeDifferentPayload =
    Uint8List.fromList(List<int>.generate(200 * 1024, (i) => (i * 17 + 4) & 0xFF));

class Harness {
  Harness(this.server);

  final HttpServer server;
  int rangeHits = 0;
  int fullHits = 0;
  int? lastRangeStart;
  bool ignoreRange = false;
  bool truncate = false;
  bool serveWrongBytes = false;

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
  final body = h.serveWrongBytes ? kSameSizeDifferentPayload : kPayload;

  Future<void> full() async {
    h.fullHits++;
    res.headers.contentLength = body.length;
    res.add(body);
    if (h.truncate) {
      // 声明长度但只发一半就关 → 客户端应看到长度不符
      await res.flush();
      await res.close();
      return;
    }
    await res.close();
  }

  switch (path) {
    case '/ok':
      await full();
      return;
    case '/boom':
      res.statusCode = HttpStatus.internalServerError;
      await res.close();
      return;
    case '/range':
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range == null || h.ignoreRange) {
        await full();
        return;
      }
      h.rangeHits++;
      final start = int.parse(RegExp(r'bytes=(\d+)').firstMatch(range)!.group(1)!);
      h.lastRangeStart = start;
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${body.length - 1}/${body.length}');
      res.headers.contentLength = body.length - start;
      res.add(body.sublist(start));
      await res.close();
      return;
    case '/wrong':
      // 永远是"同长度的另一份内容"（体积校验放行、只有 sha256 挡得住）。
      // 用来测"校验失败之后 `.part` 该怎么处理"。
      final wRange = req.headers.value(HttpHeaders.rangeHeader);
      final wBody = kSameSizeDifferentPayload;
      if (wRange != null) {
        h.rangeHits++;
        final start = int.parse(RegExp(r'bytes=(\d+)').firstMatch(wRange)!.group(1)!);
        h.lastRangeStart = start;
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(HttpHeaders.contentRangeHeader,
            'bytes $start-${wBody.length - 1}/${wBody.length}');
        res.headers.contentLength = wBody.length - start;
        res.add(wBody.sublist(start));
      } else {
        h.fullHits++;
        res.headers.contentLength = wBody.length;
        res.add(wBody);
      }
      await res.close();
      return;
    default:
      res.statusCode = HttpStatus.notFound;
      await res.close();
  }
}

KbPack packFor(Harness h, List<String> paths,
    {int? bytes, String sha = '', String fileName = 'data.json'}) {
  return KbPack(
    id: 'testkb',
    name: '测试知识库',
    kind: 'encyclopedia',
    format: 'json-array',
    textField: 'completion',
    bundled: false,
    fileName: fileName,
    bytes: bytes ?? kPayload.length,
    entries: 3,
    license: 'CC BY-SA 4.0',
    note: '测试用',
    sha256: sha,
    sources: <KbSource>[
      for (var i = 0; i < paths.length; i++)
        KbSource(label: 'src$i', url: h.url(paths[i]).toString(), priority: i),
    ],
  );
}

void main() {
  late Directory tmp;
  late KbStore store;
  late KbDownloader dl;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kb-dl-');
    store = KbStore(dshHome: tmp.path);
    dl = KbDownloader(store: store, connectTimeout: const Duration(seconds: 5));
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<KbInstalled> run(KbPack pack, {KbCancelToken? cancel}) =>
      dl.download(pack, onProgress: (_) {}, cancel: cancel);

  test('成功下载：落位、登记、大小对得上', () async {
    final h = await startServer();
    try {
      final got = await run(packFor(h, ['/ok']));
      await h.close();

      final f = File('${store.dirOf('testkb')}/data.json');
      expect(f.existsSync(), isTrue, reason: 'rename 之后正名文件必须在');
      expect(f.lengthSync(), kPayload.length);
      expect(f.readAsBytesSync(), kPayload, reason: '内容必须逐字节一致');
      // `.part` 不能留在盘上
      expect(File('${f.path}.part').existsSync(), isFalse);
      // 登记信息也要落盘（否则重启后"看不见这包"）
      expect(got.bytes, kPayload.length);
      expect(File(store.metaPathOf('testkb')).existsSync(), isTrue);
      expect((await store.list()).map((k) => k.id), contains('testkb'));
    } finally {
      await h.close();
    }
  });

  test('sha256 给对了 → 通过；给错了 → 换源、全错则失败且不落位', () async {
    final h = await startServer();
    try {
      // ① 对：清单值与内容一致
      final ok = await run(packFor(h, ['/ok'], sha: kSha));
      expect(ok.bytes, kPayload.length);

      await store.delete('testkb');

      // ② 错：清单写的哈希不是这份内容的 → 必须失败
      var err = '';
      try {
        await run(packFor(h, ['/ok'], sha: 'f' * 64));
      } catch (e) {
        err = '$e';
      }
      expect(err, contains('sha256'), reason: '哈希不符必须报错，不能当成下好了');
      // 关键：**不能留下正名文件**（否则"登记过 = 已校验"就是假的）
      expect(File('${store.dirOf('testkb')}/data.json').existsSync(), isFalse);
      expect((await store.list()).map((k) => k.id), isNot(contains('testkb')));
    } finally {
      await h.close();
    }
  });

  test('同长度的不同内容：体积校验放行，**只有 sha256 能挡**', () async {
    final h = await startServer()..serveWrongBytes = true;
    try {
      // 先证明体积确实一样（不然这条测试就没意义了）
      expect(kSameSizeDifferentPayload.length, kPayload.length);

      // 不给 sha256 → 体积对得上 → 会被当成成功（这就是改造前的漏洞）
      final lenient = await run(packFor(h, ['/ok']));
      expect(lenient.bytes, kPayload.length);
      await store.delete('testkb');

      // 给了 sha256 → 立刻挡住
      var err = '';
      try {
        await run(packFor(h, ['/ok'], sha: kSha));
      } catch (e) {
        err = '$e';
      }
      expect(err, contains('sha256'),
          reason: '同长度篡改/损坏只能靠 sha256 发现（审计 P0-4）');
    } finally {
      await h.close();
    }
  });

  test('⚠️ 校验失败必须删掉 .part —— 否则"坏前缀 + 好后缀"永远装不上', () async {
    // 2026-10-11 修的真 bug（由"知识库在本地大模型里的应用情况"这轮排查发现）：
    // 源 1 给的是**同长度的另一份内容**（体积校验会放行，只有 sha256 能挡）；
    // 源 2 是对的。旧行为：源 1 的 `.part` 留着 → 源 2 拿它续传
    // （`Range: bytes=200K-` → 服务器回 206 + 空尾巴）→ 前缀还是坏的 →
    // 校验再失败 → **这个包怎么都装不上**，界面只会重复同一条校验错误。
    final h = await startServer();
    try {
      final got = await run(packFor(h, ['/wrong', '/ok'], sha: kSha));
      await h.close();

      expect(got.bytes, kPayload.length);
      final f = File('${store.dirOf('testkb')}/data.json');
      expect(f.readAsBytesSync(), kPayload,
          reason: '最终落位的必须是源 2 的完整内容（不是"坏前缀 + 空尾巴"）');
      expect(h.lastRangeStart, isNull,
          reason: '校验失败后必须从头下 —— 拿坏 .part 续传就是永远装不上的那个 bug');
      expect(File('${f.path}.part').existsSync(), isFalse);
    } finally {
      await h.close();
    }
  });

  test('⚠️ .part 比目标还长 → 丢掉重下，不卡死', () async {
    // 旧行为：`already >= pack.bytes` 直接 return → 体积核对必然抛错、
    // `.part` 又被保留 → 换源时 already 还是那么大 → 再 return → **永远卡住**。
    final h = await startServer();
    try {
      final d = Directory(store.dirOf('testkb'));
      await d.create(recursive: true);
      File('${d.path}/data.json.part')
          .writeAsBytesSync(Uint8List(kPayload.length + 4096));

      final got = await run(packFor(h, ['/ok']));
      await h.close();
      expect(got.bytes, kPayload.length);
      expect(File('${d.path}/data.json').readAsBytesSync(), kPayload);
      expect(File('${d.path}/data.json.part').existsSync(), isFalse);
    } finally {
      await h.close();
    }
  });

  test('第一个源坏（500）→ 自动换第二个源', () async {
    final h = await startServer();
    try {
      final got = await run(packFor(h, ['/boom', '/ok']));
      await h.close();
      expect(got.bytes, kPayload.length);
      expect(File('${store.dirOf('testkb')}/data.json').existsSync(), isTrue);
    } finally {
      await h.close();
    }
  });

  test('服务器不支持 Range（回 200）时不会把文件写坏', () async {
    final h = await startServer()..ignoreRange = true;
    try {
      final got = await run(packFor(h, ['/range']));
      await h.close();
      expect(got.bytes, kPayload.length);
      expect(File('${store.dirOf('testkb')}/data.json').readAsBytesSync(), kPayload,
          reason: '不支持续传时"已收字节作废、整份重来"——拼错就会是坏文件');
    } finally {
      await h.close();
    }
  });

  test('体积不符 → 判失败（清单 bytes 与实际不一致）', () async {
    final h = await startServer();
    try {
      var err = '';
      try {
        await run(packFor(h, ['/ok'], bytes: kPayload.length + 1));
      } catch (e) {
        err = '$e';
      }
      await h.close();
      expect(err, contains('体积不符'));
      expect(File('${store.dirOf('testkb')}/data.json').existsSync(), isFalse);
    } finally {
      await h.close();
    }
  });

  test('所有源都失败 → 抛错，且不留正名文件、不登记', () async {
    final h = await startServer();
    try {
      var err = '';
      try {
        await run(packFor(h, ['/boom', '/nope']));
      } catch (e) {
        err = '$e';
      }
      await h.close();
      expect(err, contains('所有源都没成功'));
      expect(File('${store.dirOf('testkb')}/data.json').existsSync(), isFalse);
      expect((await store.list()).map((k) => k.id), isNot(contains('testkb')));
    } finally {
      await h.close();
    }
  });

  test('取消 → 抛"已取消"（且不登记）', () async {
    final h = await startServer();
    try {
      final cancel = KbCancelToken()..cancel();
      var err = '';
      try {
        await run(packFor(h, ['/ok']), cancel: cancel);
      } catch (e) {
        err = '$e';
      }
      await h.close();
      expect(err, contains('已取消'));
      expect((await store.list()).map((k) => k.id), isNot(contains('testkb')));
    } finally {
      await h.close();
    }
  });

  test('没有下载源 → 直接报错（不假装开始下）', () async {
    final h = await startServer();
    try {
      const pack = KbPack(
        id: 'nosrc',
        name: '空源',
        kind: 'encyclopedia',
        format: 'json-array',
        textField: 'completion',
        bundled: false,
        fileName: 'x.json',
        bytes: 1,
        entries: 0,
        license: '',
        note: '',
        sources: <KbSource>[],
      );
      var err = '';
      try {
        await run(pack);
      } catch (e) {
        err = '$e';
      }
      expect(err, contains('没有任何下载源'));
    } finally {
      await h.close();
    }
  });

  group('清单解析（P0-4 的另一半：sha256 字段）', () {
    test('给了 sha256 就解析出来，并统一成小写', () {
      final p = KbPack.fromJson(<String, dynamic>{
        'id': 'x',
        'fileName': 'x.json',
        'bytes': 10,
        'sha256': 'ABCDEF0123',
        'sources': <Object?>[],
      });
      expect(p, isNotNull);
      expect(p!.sha256, 'abcdef0123');
    });

    test('没给 sha256 时是空串（界面据此说"仅体积校验"，不谎称已校验）', () {
      final p = KbPack.fromJson(<String, dynamic>{
        'id': 'x',
        'fileName': 'x.json',
        'bytes': 10,
        'sources': <Object?>[],
      });
      expect(p!.sha256, '');
    });

    test('随包清单里那包 must 有 sha256（否则等于没做校验）', () {
      // 直接读仓库里那份清单：这是"我们真的填了值"的守卫。
      final f = File('assets/kb/kb_manifest.json');
      expect(f.existsSync(), isTrue, reason: '测试工作目录应该是 app/');
      final decoded = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final packs = (decoded['packs'] as List).cast<Map<String, dynamic>>();
      expect(packs, isNotEmpty);
      for (final p in packs) {
        final sha = (p['sha256'] as String?)?.trim() ?? '';
        expect(sha, isNotEmpty,
            reason: '随包清单里的 ${p['id']} 没有 sha256 —— 同长度损坏发现不了');
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(sha), isTrue,
            reason: '${p['id']} 的 sha256 形状不对：$sha');
      }
    });
  });
}
