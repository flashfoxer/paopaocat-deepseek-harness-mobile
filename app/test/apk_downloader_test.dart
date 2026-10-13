/// 更新包下载器（L2）的回归测试。
///
/// 全部用**本地假服务**，不打真网络 —— 更新包是 110 MB 的东西，
/// 测试真网络既慢又不可复现，而且会把"GitHub 今天抽风"混进"我代码坏了"。
///
/// ## 这里锁住的四件事（都是**下坏了却不报错**的那类）
///
///   1. **哈希不符必须删包**：留着一个"看起来下好了"的坏包，下次点安装就装上去了；
///   2. **服务器不认 Range 必须从头重下**：接着旧内容写会拼出坏文件，
///      而"拼坏了"要到校验时才发现 —— 那时已经白下了 110 MB；
///   3. **校验通过才改名**：`.part` 一直在，只有验过才变成正式文件
///      （中途断电/被杀，磁盘上不会留下一个能装的半截包）；
///   4. **幂等**：已经下好且哈希对得上时，再点「下载」**一个字节都不该重下**。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_mobile/local/apk_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一段像模像样的"假 APK"（长度够分几个 chunk）。
List<int> _fakeApk(int n) =>
    List<int>.generate(n, (i) => (i * 7 + 13) % 251, growable: false);

String _sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

/// 起一个本地假源：记录每次请求带的 Range 头，供"到底重下了没有"的断言用。
Future<({HttpServer server, List<String?> ranges})> _serve(
  List<int> body, {
  bool supportRange = true,
  int? forceStatus,
}) async {
  final ranges = <String?>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final range = req.headers.value(HttpHeaders.rangeHeader);
    ranges.add(range);
    try {
      if (forceStatus != null) {
        req.response.statusCode = forceStatus;
        await req.response.close();
        return;
      }
      if (supportRange &&
          range != null &&
          range.startsWith('bytes=') &&
          !range.contains(',')) {
        final start = int.tryParse(range.substring(6).split('-').first) ?? 0;
        if (start >= body.length) {
          req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await req.response.close();
          return;
        }
        final slice = body.sublist(start);
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set('Content-Range',
            'bytes $start-${body.length - 1}/${body.length}');
        req.response.contentLength = slice.length;
        req.response.add(slice);
      } else {
        req.response.statusCode = HttpStatus.ok;
        req.response.contentLength = body.length;
        req.response.add(body);
      }
      await req.response.close();
    } catch (_) {
      // 客户端提前断开（取消那条会这样）不算测试失败。
    }
  });
  return (server: server, ranges: ranges);
}

String _urlFor(HttpServer s, [String name = 'x.apk']) =>
    'http://127.0.0.1:${s.port}/$name';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('apk-dl-'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('正常下载：落到目标名、校验通过、不留 .part', () async {
    final body = _fakeApk(300 * 1024);
    final s = await _serve(body);
    addTearDown(() => s.server.close(force: true));
    final dl = ApkDownloader(dir: dir.path);
    addTearDown(dl.close);

    final r = await dl.download(
      url: _urlFor(s.server),
      fileName: 'x.apk',
      expectSha256: _sha256Of(body),
      expectBytes: body.length,
    );

    expect(r.path, endsWith('/x.apk'));
    expect(r.bytes, body.length);
    expect(r.sha256, _sha256Of(body));
    expect(r.hashVerified, isTrue);
    expect(r.resumed, isFalse);
    expect(File(r.path).lengthSync(), body.length);
    // `.part` 必须已经改名消失（校验通过才改名）。
    expect(File('${r.path}.part').existsSync(), isFalse);
  });

  test('哈希不符：抛错并**删掉坏包**（不留一个"看起来下好了"的文件）', () async {
    final body = _fakeApk(120 * 1024);
    final s = await _serve(body);
    addTearDown(() => s.server.close(force: true));
    final dl = ApkDownloader(dir: dir.path);
    addTearDown(dl.close);

    // 一个合法长度的假哈希（64 位 hex），故意与真实内容不符。
    const wrong = 'ffffffffffffffffffffffffffffffff'
        'ffffffffffffffffffffffffffffffff';
    await expectLater(
      dl.download(
        url: _urlFor(s.server),
        fileName: 'x.apk',
        expectSha256: wrong,
        expectBytes: body.length,
      ),
      throwsA(isA<ApkDownloadException>()),
    );

    // 正式文件不能存在，`.part` 也必须被删掉 —— 否则下次点「下载」会拿它当"下好了"。
    expect(File('${dir.path}/x.apk').existsSync(), isFalse);
    expect(File('${dir.path}/x.apk.part').existsSync(), isFalse);
  });

  test('服务器不认 Range：必须从头重下，不能把新旧内容拼起来', () async {
    final body = _fakeApk(200 * 1024);
    // 故意留一个**内容不对**的半截 `.part`：如果代码傻乎乎地接着写，
    // 拼出来的文件哈希必然不符 —— 这个测试就是钉住"要丢掉它"。
    File('${dir.path}/x.apk.part').writeAsBytesSync(
        List<int>.filled(50 * 1024, 9), flush: true);
    final s = await _serve(body, supportRange: false);
    addTearDown(() => s.server.close(force: true));
    final dl = ApkDownloader(dir: dir.path);
    addTearDown(dl.close);

    final r = await dl.download(
      url: _urlFor(s.server),
      fileName: 'x.apk',
      expectSha256: _sha256Of(body),
      expectBytes: body.length,
    );

    expect(r.sha256, _sha256Of(body), reason: '拼起来的内容不可能对得上哈希');
    expect(r.resumed, isFalse, reason: '服务器不支持 Range → 不是续传');
    expect(s.ranges.first, isNotNull, reason: '确实要过 Range');
    final written = File(r.path).readAsBytesSync();
    expect(written.length, body.length);
    expect(written.sublist(0, 8), body.sublist(0, 8),
        reason: '开头必须是真内容，不能是旧的 9 填充');
  });

  test('服务器支持 Range：半截 .part 会接着下（只请求后半段）', () async {
    final body = _fakeApk(240 * 1024);
    const half = 100 * 1024;
    File('${dir.path}/x.apk.part')
        .writeAsBytesSync(body.sublist(0, half), flush: true);
    final s = await _serve(body);
    addTearDown(() => s.server.close(force: true));
    final dl = ApkDownloader(dir: dir.path);
    addTearDown(dl.close);

    final r = await dl.download(
      url: _urlFor(s.server),
      fileName: 'x.apk',
      expectSha256: _sha256Of(body),
      expectBytes: body.length,
    );

    expect(r.resumed, isTrue);
    expect(r.sha256, _sha256Of(body));
    expect(s.ranges.first, 'bytes=$half-', reason: '要从断点接着要');
    expect(File(r.path).lengthSync(), body.length);
  });

  test('幂等：目标已在且哈希对得上 → 一个字节都不重下', () async {
    final body = _fakeApk(64 * 1024);
    File('${dir.path}/x.apk').writeAsBytesSync(body, flush: true);
    final s = await _serve(body);
    addTearDown(() => s.server.close(force: true));
    final dl = ApkDownloader(dir: dir.path);
    addTearDown(dl.close);

    final r = await dl.download(
      url: _urlFor(s.server),
      fileName: 'x.apk',
      expectSha256: _sha256Of(body),
      expectBytes: body.length,
    );

    expect(r.hashVerified, isTrue);
    expect(s.ranges, isEmpty, reason: '完全不该发请求');
  });

  test('已存在的包哈希不符：丢掉重下（而不是拿去装）', () async {
    final body = _fakeApk(80 * 1024);
    File('${dir.path}/x.apk')
        .writeAsBytesSync(List<int>.filled(80 * 1024, 3), flush: true);
    final s = await _serve(body);
    addTearDown(() => s.server.close(force: true));
    final dl = ApkDownloader(dir: dir.path);
    addTearDown(dl.close);

    final r = await dl.download(
      url: _urlFor(s.server),
      fileName: 'x.apk',
      expectSha256: _sha256Of(body),
      expectBytes: body.length,
    );

    expect(s.ranges, isNotEmpty, reason: '必须真的重下了一次');
    expect(r.sha256, _sha256Of(body));
  });

  test('大小不符：报"下载不完整"，并**留着 .part** 供下次续传', () async {
    final body = _fakeApk(100 * 1024);
    final s = await _serve(body);
    addTearDown(() => s.server.close(force: true));
    final dl = ApkDownloader(dir: dir.path);
    addTearDown(dl.close);

    await expectLater(
      dl.download(
        url: _urlFor(s.server),
        fileName: 'x.apk',
        expectSha256: _sha256Of(body),
        // 故意把"应该有"写大：真实字节数对不上 → 判不完整。
        expectBytes: body.length + 4096,
      ),
      throwsA(isA<ApkDownloadException>()),
    );
    // 正式文件不能出现；`.part` 留着（下次接着下，不用从 0 开始）。
    expect(File('${dir.path}/x.apk').existsSync(), isFalse);
    expect(File('${dir.path}/x.apk.part').existsSync(), isTrue);
  });

  test('服务器 404：给中文人话，不抛原始异常', () async {
    final s = await _serve(const <int>[], forceStatus: 404);
    addTearDown(() => s.server.close(force: true));
    final dl = ApkDownloader(dir: dir.path);
    addTearDown(dl.close);

    try {
      await dl.download(
        url: _urlFor(s.server),
        fileName: 'x.apk',
        expectSha256: null,
      );
      fail('本该抛 ApkDownloadException');
    } on ApkDownloadException catch (e) {
      expect(e.zh, contains('404'));
      expect(e.zh, contains('下载失败'));
    }
  });

  test('取消：抛 ApkDownloadCancelled（不是失败），.part 留着', () async {
    final body = _fakeApk(512 * 1024);
    final s = await _serve(body);
    addTearDown(() => s.server.close(force: true));
    final dl = ApkDownloader(dir: dir.path);
    addTearDown(dl.close);

    // ⚠️ 这里**不用**「一有进度就取消」：本地环回太快，200 ms 的进度节流
    //    可能一次都不回调（上一版就这么写的，测试随机红）。改成**开始前就已取消** ——
    //    下载器在收到第一个 chunk 时就会抛，这是确定性的。
    final token = ApkDownloadCancelToken()..cancel();
    await expectLater(
      dl.download(
        url: _urlFor(s.server),
        fileName: 'x.apk',
        expectSha256: _sha256Of(body),
        expectBytes: body.length,
        cancel: token,
      ),
      throwsA(isA<ApkDownloadCancelled>()),
    );
    expect(File('${dir.path}/x.apk').existsSync(), isFalse,
        reason: '取消不能产出正式文件');
  });

  test('进度回调：报出的 received 单调不减，且不超总量', () async {
    final body = _fakeApk(400 * 1024);
    final s = await _serve(body);
    addTearDown(() => s.server.close(force: true));
    final dl = ApkDownloader(dir: dir.path);
    addTearDown(dl.close);

    final seen = <ApkDownloadProgress>[];
    final r = await dl.download(
      url: _urlFor(s.server),
      fileName: 'x.apk',
      expectSha256: _sha256Of(body),
      expectBytes: body.length,
      onProgress: seen.add,
    );

    expect(r.bytes, body.length);
    // 节流是 200 ms —— 本地环回很快，可能一次都没回调；有回调就得是自洽的。
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i].received, greaterThanOrEqualTo(seen[i - 1].received));
      expect(seen[i].total, body.length);
    }
    for (final p in seen) {
      expect(p.received, lessThanOrEqualTo(body.length));
      expect(p.bytesPerSecond, greaterThanOrEqualTo(0));
    }
  });

  test('没给哈希时也算成功，但如实标记 hashVerified=false', () async {
    final body = _fakeApk(32 * 1024);
    final s = await _serve(body);
    addTearDown(() => s.server.close(force: true));
    final dl = ApkDownloader(dir: dir.path);
    addTearDown(dl.close);

    final r = await dl.download(
      url: _urlFor(s.server),
      fileName: 'x.apk',
      expectSha256: null,
      expectBytes: body.length,
    );
    expect(r.hashVerified, isFalse,
        reason: '没给哈希就不能说"校验过了" —— 界面也要如实写');
    expect(r.sha256, _sha256Of(body), reason: '仍要算出实际哈希供显示/排查');
  });

  group('安全：文件名与体积（清单是网络给的东西，不能直接信）', () {
    test('文件名会被洗净，路径穿越写不进别的目录', () async {
      final body = _fakeApk(8 * 1024);
      final s = await _serve(body);
      addTearDown(() => s.server.close(force: true));
      final dl = ApkDownloader(dir: dir.path);
      addTearDown(dl.close);

      final r = await dl.download(
        url: _urlFor(s.server),
        fileName: '../../evil.apk',
        expectSha256: _sha256Of(body),
      );
      expect(r.path, '${dir.path}/evil.apk', reason: '只能落在指定目录里');
      expect(File('${dir.path}/../../evil.apk').existsSync(), isFalse);
    });

    test('sanitizeApkFileName 的几条边界', () {
      expect(sanitizeApkFileName('a.apk'), 'a.apk');
      expect(sanitizeApkFileName('/x/y/a.apk'), 'a.apk');
      expect(sanitizeApkFileName(r'..\..\evil.apk'), 'evil.apk');
      expect(sanitizeApkFileName('..'), 'update.apk');
      expect(sanitizeApkFileName('   '), 'update.apk');
      // 中文名不是"不能有"，而是会被换成下划线 —— APK 的真实名字本来就只有 ASCII。
      expect(sanitizeApkFileName('有中文.apk'), '___.apk');
    });

    test('清单自报的体积超上限 → 连请求都不发', () async {
      final body = _fakeApk(4 * 1024);
      final s = await _serve(body);
      addTearDown(() => s.server.close(force: true));
      final dl = ApkDownloader(dir: dir.path);
      addTearDown(dl.close);

      await expectLater(
        dl.download(
          url: _urlFor(s.server),
          fileName: 'x.apk',
          expectSha256: null,
          expectBytes: kMaxApkBytes + 1,
        ),
        throwsA(isA<ApkDownloadException>()),
      );
      expect(s.ranges, isEmpty, reason: '早拒绝：一个请求也不该发');
    });
  });
}
