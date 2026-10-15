/// 「准备运行环境」（`local/runtime_bootstrap.dart`）的回归测试。
///
/// 这一层跑在**启动路径**上，所以它出错的表现不是"少个功能"，而是
/// **用户装完打不开**（或卡在一个没有出路的错误页上）。四类情况必须钉死：
///
///   1. **老用户不该被惊动** —— 本地那份是对的（哈希一致）时，
///      连下载请求都不该发（他们本来就有，重下 32 MB 是纯浪费）；
///   2. **拉不到清单也要能启动** —— 本地有 zip 就放行（但如实标 `verified=false`），
///      否则网络差的用户会被永久挡在门外；
///   3. **失败必须给出路** —— 不能只说"失败了"，要告诉用户"可以把 runtime.zip
///      放到某个目录再点一次"（这是没有文件选择器时唯一可行的手动兜底）；
///   4. **坏包绝不能留在那个路径上** —— 它下一步就会被拿去解压。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_mobile/local/apk_downloader.dart' show ApkDownloadCancelToken;
import 'package:dsh_mobile/local/runtime_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一段"假 zip"（内容不重要，重要的是哈希对得上）。
List<int> _fakeZip(int n) =>
    List<int>.generate(n, (i) => (i * 13 + 7) % 251, growable: false);

String _shaOf(List<int> b) => sha256.convert(b).toString();

/// 起一个本地假源：`/runtime.json` 给清单、`/runtime.zip` 给包。
///
/// [manifest] 拿**本服务器的 base url** 去拼清单 —— 这样不用"先起服务拿端口、
/// 关掉、再起一个"，一次到位。请求过的路径记下来，供"到底有没有下载"的断言用。
Future<({HttpServer server, List<String> paths})> _serve({
  String Function(String base)? manifest,
  List<int>? zip,
}) async {
  final paths = <String>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://127.0.0.1:${server.port}';
  server.listen((req) async {
    paths.add(req.uri.path);
    try {
      if (req.uri.path == '/runtime.json') {
        final body = utf8.encode(manifest?.call(base) ?? '{}');
        req.response.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        req.response.contentLength = body.length;
        req.response.add(body);
      } else if (req.uri.path == '/runtime.zip' && zip != null) {
        final range = req.headers.value(HttpHeaders.rangeHeader);
        if (range == null) {
          req.response.contentLength = zip.length;
          req.response.add(zip);
        } else {
          final start = int.tryParse(range.substring(6).split('-').first) ?? 0;
          final slice = zip.sublist(start);
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
              'Content-Range', 'bytes $start-${zip.length - 1}/${zip.length}');
          req.response.contentLength = slice.length;
          req.response.add(slice);
        }
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    } catch (_) {
      // 客户端提前断开不算测试失败。
    }
  });
  return (server: server, paths: paths);
}

/// 一份"指向这台服务器的"运行时清单。
String _manifest(String base, List<int> zip, {String? shaOverride}) =>
    jsonEncode(<String, Object>{
      'version': '1',
      'url': '$base/runtime.zip',
      'size': zip.length,
      'sha256': shaOverride ?? _shaOf(zip),
    });

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rt-boot-'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('RuntimeManifest 解析（严进）', () {
    test('正常清单', () {
      final m = RuntimeManifest.parse(jsonEncode(<String, Object>{
        'version': '1',
        'url': 'https://x/y.zip',
        'size': 123,
        'sha256': 'AB' * 32,
      }));
      expect(m.version, '1');
      expect(m.url, 'https://x/y.zip');
      expect(m.size, 123);
      // 统一小写 —— 后面拿它跟算出来的哈希比，大小写不一致会被误判成"不符"。
      expect(m.sha256, 'ab' * 32);
    });

    test('缺 version / url → 报错并点名字段', () {
      for (final k in <String>['version', 'url']) {
        final m = <String, Object>{'version': '1', 'url': 'https://x/y.zip'}
          ..remove(k);
        expect(() => RuntimeManifest.parse(jsonEncode(m)),
            throwsA(predicate((e) => '$e'.contains(k))));
      }
    });

    test('空内容 / 坏 JSON / 顶层不是对象 → 都挡住', () {
      expect(() => RuntimeManifest.parse('  '), throwsA(isA<Exception>()));
      expect(() => RuntimeManifest.parse('nope'), throwsA(isA<Exception>()));
      expect(() => RuntimeManifest.parse('[1,2]'), throwsA(isA<Exception>()));
    });

    test('没给 sha256 / size 也认（只是 verified 会是 false）', () {
      final m = RuntimeManifest.parse(
          jsonEncode(<String, Object>{'version': '1', 'url': 'https://x/y.zip'}));
      expect(m.sha256, isNull);
      expect(m.size, isNull);
    });
  });

  group('ensureRuntimeZip（启动路径，错了就打不开）', () {
    test('本地那份哈希一致 → 直接用，**一个字节都不下**', () async {
      final zip = _fakeZip(4096);
      File('${dir.path}/runtime.zip').writeAsBytesSync(zip, flush: true);
      final s = await _serve(manifest: (b) => _manifest(b, zip), zip: zip);
      addTearDown(() => s.server.close(force: true));

      final r = await ensureRuntimeZip(
        filesDir: dir.path,
        customManifestSource: 'http://127.0.0.1:${s.server.port}/runtime.json',
      );

      expect(r.ok, isTrue);
      expect(r.verified, isTrue, reason: '哈希对得上');
      expect(r.downloaded, isFalse, reason: '本地已有正确的那份，不该重下');
      expect(s.paths.where((p) => p == '/runtime.zip'), isEmpty,
          reason: '连下载请求都不该发');
    });

    test('本地没有 → 下载并校验通过（落在原生解包读的那个路径）', () async {
      final zip = _fakeZip(8192);
      final s = await _serve(manifest: (b) => _manifest(b, zip), zip: zip);
      addTearDown(() => s.server.close(force: true));

      final r = await ensureRuntimeZip(
        filesDir: dir.path,
        customManifestSource: 'http://127.0.0.1:${s.server.port}/runtime.json',
      );

      expect(r.ok, isTrue);
      expect(r.downloaded, isTrue);
      expect(r.verified, isTrue);
      expect(s.paths, contains('/runtime.zip'));
      expect(File('${dir.path}/runtime.zip').existsSync(), isTrue);
      expect(File('${dir.path}/runtime.zip').lengthSync(), zip.length);
      expect(File('${dir.path}/runtime.zip').readAsBytesSync(), zip);
    });

    test('本地哈希不符 → 重下（换运行时版本时靠这条自愈）', () async {
      final zip = _fakeZip(4096);
      // 本地放的是一份"旧内容"：长度一样、字节不同。
      File('${dir.path}/runtime.zip')
          .writeAsBytesSync(List<int>.filled(zip.length, 9), flush: true);
      final s = await _serve(manifest: (b) => _manifest(b, zip), zip: zip);
      addTearDown(() => s.server.close(force: true));

      final r = await ensureRuntimeZip(
        filesDir: dir.path,
        customManifestSource: 'http://127.0.0.1:${s.server.port}/runtime.json',
      );

      expect(r.downloaded, isTrue, reason: '内容不对必须重下');
      expect(r.verified, isTrue);
      expect(File('${dir.path}/runtime.zip').readAsBytesSync(), zip);
    });

    // ── 2026-10-15 真机反馈：完整包（随包自带运行环境）首次安装时**仍然**被要求
    //    下载 32 MB，而且更新源一超时就卡在「准备运行环境」那一页。下面两条把它钉住：
    //    ① 自带 → 先取出、**不联网**也照样就绪；② 不带 → 行为不变（走下载）。
    test('安装包自带运行环境 → 取出来就用，**清单都连不上也照样就绪**', () async {
      final zip = _fakeZip(4096);
      var copied = false;

      final r = await ensureRuntimeZip(
        filesDir: dir.path,
        // 127.0.0.1:1 连不上（模拟用户那次 TimeoutException）
        customManifestSource: 'http://127.0.0.1:1/runtime.json',
        timeout: const Duration(seconds: 2),
        hasAssetOverride: () async => true,
        copyAssetOverride: () async {
          copied = true;
          File('${dir.path}/runtime.zip').writeAsBytesSync(zip, flush: true);
          return zip.length;
        },
      );

      expect(copied, isTrue, reason: '自带的运行环境必须被取出来');
      expect(r.ok, isTrue, reason: '随包自带时**不需要联网**，连不上更新源也要能就绪');
      expect(r.fromAsset, isTrue);
      expect(r.downloaded, isFalse, reason: '这是"取出"，不是"下载"');
      expect(File('${dir.path}/runtime.zip').lengthSync(), zip.length);
    });

    test('安装包不带运行环境（精简包）→ 行为不变：走清单/下载那条路', () async {
      var copyTried = false;
      final r = await ensureRuntimeZip(
        filesDir: dir.path,
        customManifestSource: 'http://127.0.0.1:1/runtime.json',
        timeout: const Duration(seconds: 2),
        hasAssetOverride: () async => false,
        copyAssetOverride: () async {
          copyTried = true;
          return 0;
        },
      );
      expect(copyTried, isFalse, reason: '没有 asset 就不该去取');
      expect(r.ok, isFalse, reason: '没自带、又连不上源 → 如实失败（原来那套行为）');
      expect(r.fromAsset, isFalse);
    });

    test('清单拉不到、本地也空 → 失败，但**给出可操作的出路**', () async {
      final r = await ensureRuntimeZip(
        filesDir: dir.path,
        // 127.0.0.1:1 连不上（那里没有服务）
        customManifestSource: 'http://127.0.0.1:1/runtime.json',
        timeout: const Duration(seconds: 2),
      );
      expect(r.ok, isFalse);
      expect(r.errorZh, isNotNull);
      expect(r.errorZh!, contains('runtime.zip'),
          reason: '要告诉用户"可以把文件放到哪儿再试一次"，而不是只说失败');
    });

    test('清单拉不到、但本地已有 zip → 放行（verified=false，如实标注）', () async {
      final zip = _fakeZip(1024);
      File('${dir.path}/runtime.zip').writeAsBytesSync(zip, flush: true);

      final r = await ensureRuntimeZip(
        filesDir: dir.path,
        customManifestSource: 'http://127.0.0.1:1/runtime.json',
        timeout: const Duration(seconds: 2),
      );

      expect(r.ok, isTrue, reason: '能启动优先于"一定是最新"');
      expect(r.downloaded, isFalse);
      expect(r.verified, isFalse, reason: '没校验过就不能说校验过了');
      expect(r.bytes, zip.length);
    });

    test('清单没给 sha256 + 本地有 zip → 直接用（verified=false）', () async {
      final zip = _fakeZip(512);
      File('${dir.path}/runtime.zip').writeAsBytesSync(zip, flush: true);
      final s = await _serve(
        manifest: (b) =>
            jsonEncode(<String, Object>{'version': '1', 'url': '$b/runtime.zip'}),
      );
      addTearDown(() => s.server.close(force: true));

      final r = await ensureRuntimeZip(
        filesDir: dir.path,
        customManifestSource: 'http://127.0.0.1:${s.server.port}/runtime.json',
      );
      expect(r.ok, isTrue);
      expect(r.downloaded, isFalse);
      expect(r.verified, isFalse);
    });

    test('下载到的内容哈希不符 → 失败，且**坏包不留**（下一步就要拿去解压）', () async {
      final wanted = _fakeZip(4096);
      // ⚠️ 服务器给的内容必须与 wanted **真的不同**：`_fakeZip` 是确定性函数，
      //    两次同参数调用会生成一模一样的字节 —— 上一版就这么写的，
      //    结果这条测试测的是"校验通过"，红得毫无意义。
      final served = List<int>.generate(4096, (i) => (i * 7 + 99) % 251,
          growable: false);
      expect(_shaOf(served), isNot(_shaOf(wanted)), reason: '前提：两份内容确实不同');
      final s = await _serve(
        manifest: (b) => _manifest(b, served, shaOverride: _shaOf(wanted)),
        zip: served,
      );
      addTearDown(() => s.server.close(force: true));

      final r = await ensureRuntimeZip(
        filesDir: dir.path,
        customManifestSource: 'http://127.0.0.1:${s.server.port}/runtime.json',
      );
      expect(r.ok, isFalse);
      expect(r.errorZh, isNotNull);
      expect(File('${dir.path}/runtime.zip').existsSync(), isFalse);
    });

    test('取消 → 明确说"已取消"，且不留正式文件', () async {
      final zip = _fakeZip(256 * 1024);
      final s = await _serve(manifest: (b) => _manifest(b, zip), zip: zip);
      addTearDown(() => s.server.close(force: true));

      final token = ApkDownloadCancelToken();
      token.cancel(); // 开始前就取消（确定性，不赌进度回调的时机）
      final r = await ensureRuntimeZip(
        filesDir: dir.path,
        customManifestSource: 'http://127.0.0.1:${s.server.port}/runtime.json',
        cancel: token,
      );
      expect(r.ok, isFalse);
      expect(r.errorZh, isNotNull);
      expect(File('${dir.path}/runtime.zip').existsSync(), isFalse);
    });
  });

  group('不联网的小工具', () {
    test('isLocalZipUsable：只看"有没有"，不看内容', () {
      expect(isLocalZipUsable(dir.path), isFalse);
      File('${dir.path}/runtime.zip').writeAsBytesSync(<int>[1, 2, 3], flush: true);
      expect(isLocalZipUsable(dir.path), isTrue);
    });

    test('localZipLabel：没有时说"还没有"，有就给大小', () {
      expect(localZipLabel(dir.path), '还没有');
      File('${dir.path}/runtime.zip')
          .writeAsBytesSync(List<int>.filled(2048, 0), flush: true);
      expect(localZipLabel(dir.path), '2 KB');
    });

    test('本地文件名必须是原生解包读的那一个（写错 = 宿主报"运行时包不在"）', () {
      expect(kRuntimeZipName, 'runtime.zip');
      expect(runtimeZipPath('/tmp/x'), '/tmp/x/runtime.zip');
    });
  });
}
