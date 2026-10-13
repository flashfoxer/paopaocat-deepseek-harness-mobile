/// 本地播放服务（`lib/local/media_preview_server.dart`）的测试。
///
/// ## 为什么这几条值得钉住
///
/// 视频预览的坏法**全是"只在真机放视频时才看得见"的那一类**：
///   * **Range 解析/回包写错** → 表现是"能起播、一拖进度条就黑屏"；
///   * **越界 Range 没回 416** → 播放器拿不到纠正信息，行为不可预期；
///   * **Content-Type 猜错**（比如把 .mkv 说成 video/mp4）→ WebView 直接解码失败，
///     而报出来的错**跟真实原因对不上**（用户看到的是"文件坏了"）；
///   * **目录穿越**（如果哪天有人把路径接到 URL 上）→ 本机文件被读出去。
///
/// 这些都不需要真机 —— 真起一个 server 发真请求就能全部覆盖（同
/// `model_download_test.dart` 的做法）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/data/library_store.dart';
import 'package:dsh_mobile/local/media_preview_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('dsh-preview-'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 造一个内容可预测的文件：第 i 个字节 = i % 256。
  File makeFile(String name, int size) {
    final f = File('${tmp.path}/$name');
    f.writeAsBytesSync(List<int>.generate(size, (i) => i % 256));
    return f;
  }

  /// ⚠️ 用 `port` 拼、**不要**用 `s.url` 拼：`url` 以 `/` 结尾（它是"入口地址"），
  /// 直接接 `/media` 会变成 `//media`，服务端按"未知路径"回 404（我第一版就踩了）。
  Uri uriOf(MediaPreviewServer s, String path) =>
      Uri.parse('http://127.0.0.1:${s.port}$path');

  Future<HttpClientResponse> get(MediaPreviewServer s, String path,
      {String? range, String method = 'GET'}) async {
    final c = HttpClient();
    try {
      final req = method == 'HEAD'
          ? await c.headUrl(uriOf(s, path))
          : await c.getUrl(uriOf(s, path));
      if (range != null) req.headers.set('range', range);
      return await req.close();
    } finally {
      // 连接不关：响应体还要读。调用方读完自己丢 client（进程级清理）。
    }
  }

  Future<List<int>> body(HttpClientResponse r) async =>
      await r.fold<List<int>>(<int>[], (a, b) => a..addAll(b));

  group('播放页 HTML', () {
    test('视频页给 <video>、音频页给 <audio>，都指向 /media', () async {
      final f = makeFile('a.mp4', 10);
      final s = await MediaPreviewServer.start(f);
      addTearDown(s.stop);
      final r = await get(s, '/');
      expect(r.statusCode, 200);
      expect(r.headers.contentType?.mimeType, 'text/html');
      final html = utf8.decode(await body(r));
      expect(html, contains('<video'));
      expect(html, contains('src="/media"'));
      expect(html, contains('DshPreview'), reason: '必须带 JS 回执通道（放不出来要能上报）');
      expect(html, contains('error'), reason: '必须监听 error，否则界面只能留个黑框');
    });

    test('音频：换成 <audio>，不出现 <video>', () async {
      final f = makeFile('a.mp3', 10);
      final s = await MediaPreviewServer.start(f, audio: true);
      addTearDown(s.stop);
      final html = utf8.decode(await body(await get(s, '/')));
      expect(html, contains('<audio'));
      expect(html, isNot(contains('<video')));
    });
  });

  group('整份下发（没有 Range 时）', () {
    test('200 + 全量字节 + 按扩展名给的 Content-Type', () async {
      final f = makeFile('v.mp4', 1000);
      final s = await MediaPreviewServer.start(f);
      addTearDown(s.stop);
      final r = await get(s, '/media');
      expect(r.statusCode, 200);
      expect(r.headers.contentType?.mimeType, 'video/mp4');
      expect(r.headers.value('accept-ranges'), 'bytes');
      final bytes = await body(r);
      expect(bytes.length, 1000);
      expect(bytes[5], 5);
    });

    test('HEAD 只回头、不发正文', () async {
      final f = makeFile('v.mp4', 1000);
      final s = await MediaPreviewServer.start(f);
      addTearDown(s.stop);
      final r = await get(s, '/media', method: 'HEAD');
      expect(r.statusCode, 200);
      expect(r.headers.contentLength, 1000);
      expect((await body(r)).isEmpty, isTrue);
    });
  });

  group('Range：能拖进度条的前提', () {
    test('bytes=0-9 → 206 + Content-Range + 正好 10 字节', () async {
      final f = makeFile('v.mp4', 1000);
      final s = await MediaPreviewServer.start(f);
      addTearDown(s.stop);
      final r = await get(s, '/media', range: 'bytes=0-9');
      expect(r.statusCode, 206);
      expect(r.headers.value('content-range'), 'bytes 0-9/1000');
      final bytes = await body(r);
      expect(bytes.length, 10);
      expect(bytes.first, 0);
      expect(bytes.last, 9);
    });

    test('bytes=100- → 从 100 到结尾', () async {
      final f = makeFile('v.mp4', 1000);
      final s = await MediaPreviewServer.start(f);
      addTearDown(s.stop);
      final r = await get(s, '/media', range: 'bytes=100-');
      expect(r.statusCode, 206);
      expect(r.headers.value('content-range'), 'bytes 100-999/1000');
      expect((await body(r)).length, 900);
    });

    test('bytes=-50 → 最后 50 字节（后缀写法）', () async {
      final f = makeFile('v.mp4', 1000);
      final s = await MediaPreviewServer.start(f);
      addTearDown(s.stop);
      final r = await get(s, '/media', range: 'bytes=-50');
      expect(r.statusCode, 206);
      expect(r.headers.value('content-range'), 'bytes 950-999/1000');
      expect((await body(r)).length, 50);
    });

    test('尾部超界（bytes=900-99999）→ 夹到文件末尾', () async {
      final f = makeFile('v.mp4', 1000);
      final s = await MediaPreviewServer.start(f);
      addTearDown(s.stop);
      final r = await get(s, '/media', range: 'bytes=900-99999');
      expect(r.statusCode, 206);
      expect(r.headers.value('content-range'), 'bytes 900-999/1000');
      expect((await body(r)).length, 100);
    });

    test('起点越界（bytes=2000-）→ 416 + bytes */1000（不能假装能服务）', () async {
      final f = makeFile('v.mp4', 1000);
      final s = await MediaPreviewServer.start(f);
      addTearDown(s.stop);
      final r = await get(s, '/media', range: 'bytes=2000-');
      expect(r.statusCode, 416);
      expect(r.headers.value('content-range'), 'bytes */1000');
    });

    test('多段 Range / 乱写的 Range → 按整份发（规范允许的兜底）', () async {
      final f = makeFile('v.mp4', 1000);
      final s = await MediaPreviewServer.start(f);
      addTearDown(s.stop);
      for (final bad in <String>['bytes=0-9,20-29', 'bytes=abc-def', 'items=0-9']) {
        final r = await get(s, '/media', range: bad);
        expect(r.statusCode, 200, reason: '「$bad」应该是兜底整份，而不是报错');
        expect((await body(r)).length, 1000);
      }
    });
  });

  group('只服务这一个文件（不给目录穿越留缝）', () {
    test('其它路径一律 404', () async {
      final f = makeFile('v.mp4', 100);
      final s = await MediaPreviewServer.start(f);
      addTearDown(s.stop);
      for (final p in <String>[
        '/../etc/passwd',
        '/%2e%2e/etc/passwd',
        '/media/../other',
        '/v.mp4',
      ]) {
        final r = await get(s, p);
        expect(r.statusCode, 404, reason: '「$p」不该被服务');
      }
    });

    test('非 GET/HEAD 的方法 → 405', () async {
      final f = makeFile('v.mp4', 100);
      final s = await MediaPreviewServer.start(f);
      addTearDown(s.stop);
      final c = HttpClient();
      final req = await c.postUrl(uriOf(s, '/media'));
      final r = await req.close();
      expect(r.statusCode, 405);
      c.close(force: true);
    });
  });

  group('Content-Type 按扩展名（猜错会让报错对不上真实原因）', () {
    test('常见容器与音频格式', () {
      expect(contentTypeFor('a.mp4').mimeType, 'video/mp4');
      expect(contentTypeFor('a.M4V').mimeType, 'video/mp4');
      expect(contentTypeFor('a.mov').mimeType, 'video/quicktime');
      expect(contentTypeFor('a.webm').mimeType, 'video/webm');
      expect(contentTypeFor('a.mkv').mimeType, 'video/x-matroska');
      expect(contentTypeFor('a.mp3').mimeType, 'audio/mpeg');
      expect(contentTypeFor('a.wav').mimeType, 'audio/wav');
      expect(contentTypeFor('a.m4a').mimeType, 'audio/mp4');
      expect(contentTypeFor('a.flac').mimeType, 'audio/flac');
    });

    test('认不出的类型回 octet-stream（**不猜**成 video/mp4）', () {
      expect(contentTypeFor('a.xyz').mimeType, 'application/octet-stream');
      expect(contentTypeFor('noext').mimeType, 'application/octet-stream');
    });
  });

  group('parseRangeHeader 的边界（直接钉逻辑）', () {
    test('没有头 / 不认识的写法 → null（调用方按整份发）', () {
      expect(parseRangeHeader(null, 100), isNull);
      expect(parseRangeHeader('', 100), isNull);
      expect(parseRangeHeader('bytes=', 100), isNull);
      expect(parseRangeHeader('bytes=abc', 100), isNull);
      expect(parseRangeHeader('items=0-9', 100), isNull);
      expect(parseRangeHeader('bytes=0-9,20-29', 100), isNull);
    });

    test('正常区间 / 开区间 / 后缀区间', () {
      final a = parseRangeHeader('bytes=10-19', 100)!;
      expect((a.start, a.end), (10, 19));
      final b = parseRangeHeader('bytes=10-', 100)!;
      expect((b.start, b.end), (10, 99));
      final c = parseRangeHeader('bytes=-5', 100)!;
      expect((c.start, c.end), (95, 99));
    });

    test('越界与空文件 → unsatisfiable', () {
      expect(parseRangeHeader('bytes=100-', 100), MediaRange.unsatisfiable);
      expect(parseRangeHeader('bytes=0-', 0), MediaRange.unsatisfiable);
      expect(parseRangeHeader('bytes=-5', 0), MediaRange.unsatisfiable);
    });

    test('后缀比文件还长 → 退化成整份', () {
      final r = parseRangeHeader('bytes=-500', 100)!;
      expect((r.start, r.end), (0, 99));
    });
  });

  group('文件类型：视频/音频不再落进「暂不支持预览」', () {
    test('常见容器分到 video / audio（大小写不敏感）', () {
      for (final e in <String>['mp4', 'M4V', 'mov', 'webm', 'mkv', 'ogv', '3gp']) {
        expect(kindForExtension(e), LibraryFileKind.video, reason: '.$e');
      }
      for (final e in <String>['mp3', 'wav', 'M4A', 'aac', 'ogg', 'opus', 'flac', 'amr']) {
        expect(kindForExtension(e), LibraryFileKind.audio, reason: '.$e');
      }
    });

    test('文本/图片/其它不受影响（HTML 必须仍算 text —— 源码预览靠它）', () {
      expect(kindForExtension('html'), LibraryFileKind.text);
      expect(kindForExtension('md'), LibraryFileKind.text);
      expect(kindForExtension('png'), LibraryFileKind.image);
      expect(kindForExtension('zip'), LibraryFileKind.other);
      expect(kindForExtension(''), LibraryFileKind.other);
    });

    test('两套扩展名清单不重叠（同一个扩展名不能既是视频又是音频）', () {
      final overlap = kLibraryVideoExtensions
          .intersection(kLibraryAudioExtensions)
          .toList();
      expect(overlap, isEmpty, reason: '重叠的扩展名：$overlap');
    });
  });

  test('stop() 之后连不上了（不留后台端口）', () async {
    final f = makeFile('v.mp4', 100);
    final s = await MediaPreviewServer.start(f);
    final before = await get(s, '/media');
    expect(before.statusCode, 200);
    await body(before);

    await s.stop();

    // ⚠️ 这里只断言"**连不上**"这个事实，不挑异常类型：
    //    端口关掉之后，不同平台抛的是 SocketException / HttpException /
    //    Connection refused 之类，钉死类型会让测试在别的机器上假红。
    var reachable = false;
    final c = HttpClient();
    try {
      final r = await (await c.getUrl(uriOf(s, '/media'))).close();
      await r.drain<void>();
      reachable = true;
    } catch (_) {
      // 期望路径：连接被拒
    } finally {
      c.close(force: true);
    }
    expect(reachable, isFalse, reason: 'stop() 之后不该还连得上（端口没关干净）');
  });
}
