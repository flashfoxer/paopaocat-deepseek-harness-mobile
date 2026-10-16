/// 「设计画布」静态服务的**安全边界**测试。
///
/// ## 为什么专测这两个函数
///
/// `resolveIn` 是这台 loopback 服务**唯一**的路径入口。它坏掉的两种表现都不是
/// "报错"，而是：
///   * **能读到根目录外的文件**（`../../` 一类请求穿透）；
///   * 或者正常文件打不开（页面白屏、资源 404）。
///
/// 两种都靠肉眼 review 保证不了，所以把它提成公开静态函数在这里钉住。
/// `contentTypeFor` 同理：MIME 给错（尤其 `.js` 给成 `text/plain`）会让
/// Next 的产物**整页不执行**——页面全白，而日志里什么错都没有。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/local/studio_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dsh-studio-');
    // 造一棵小网站：根 index.html + 子目录资源 + 一个"根外的机密文件"
    File('${root.path}/index.html').writeAsStringSync('<html>ok</html>');
    Directory('${root.path}/_next/static').createSync(recursive: true);
    File('${root.path}/_next/static/app.js').writeAsStringSync('console.log(1)');
    File('${root.path}/_next/static/app.css').writeAsStringSync('body{}');
    File('${root.path}/material-symbols.json').writeAsStringSync('{}');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('resolveIn：正常的路径都能解析', () {
    test('/ → index.html', () {
      final f = StudioServer.resolveIn(root, '/');
      expect(f, isNotNull);
      expect(f!.path, endsWith('/index.html'));
    });

    test('空路径 → index.html', () {
      expect(StudioServer.resolveIn(root, '')!.path, endsWith('/index.html'));
    });

    test('子目录里的资源', () {
      final f = StudioServer.resolveIn(root, '/_next/static/app.js');
      expect(f, isNotNull);
      expect(f!.readAsStringSync(), 'console.log(1)');
    });

    test('目录路径以 / 结尾时补 index.html', () {
      Directory('${root.path}/sub').createSync();
      File('${root.path}/sub/index.html').writeAsStringSync('sub');
      final f = StudioServer.resolveIn(root, '/sub/');
      expect(f, isNotNull);
      expect(f!.path, endsWith('/sub/index.html'));
    });

    test('不存在的文件 → null（服务会回 404）', () {
      expect(StudioServer.resolveIn(root, '/nope.js'), isNull);
    });
  });

  group('resolveIn：路径穿越必须一律拒绝', () {
    test('.. 直接拒绝', () {
      expect(StudioServer.resolveIn(root, '/../secret.txt'), isNull);
      expect(StudioServer.resolveIn(root, '/_next/../../secret.txt'), isNull);
    });

    test('URL 编码的 %2e%2e%2f 解码后也被拒绝', () {
      expect(StudioServer.resolveIn(root, '/%2e%2e%2fsecret.txt'), isNull);
      expect(StudioServer.resolveIn(root, '/%2e%2e/secret.txt'), isNull);
    });

    test('单个 . 段也拒绝（不给规范化留缝）', () {
      expect(StudioServer.resolveIn(root, '/./index.html'), isNull);
    });

    test('含 NUL 的路径拒绝', () {
      expect(StudioServer.resolveIn(root, '/index.html\u0000.png'), isNull);
    });

    test('真实的根外文件读不到（端到端确认，而不只是看返回值）', () {
      final outside = File('${root.parent.path}/dsh-outside-secret.txt');
      outside.writeAsStringSync('secret');
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync();
      });
      // 任何形式的穿越都不该拿到它
      for (final p in <String>[
        '/../${outside.uri.pathSegments.last}',
        '/%2e%2e/${outside.uri.pathSegments.last}',
        '/_next/../../${outside.uri.pathSegments.last}',
      ]) {
        expect(StudioServer.resolveIn(root, p), isNull, reason: '$p 竟然解析成功了');
      }
    });
  });

  group('contentTypeFor：给错 MIME 会让整个页面不执行', () {
    test('关键类型', () {
      expect(StudioServer.contentTypeFor('a.html'), startsWith('text/html'));
      expect(StudioServer.contentTypeFor('a.js'), startsWith('text/javascript'));
      expect(StudioServer.contentTypeFor('a.mjs'), startsWith('text/javascript'));
      expect(StudioServer.contentTypeFor('a.css'), startsWith('text/css'));
      expect(StudioServer.contentTypeFor('a.json'), startsWith('application/json'));
      expect(StudioServer.contentTypeFor('a.webmanifest'),
          startsWith('application/manifest+json'));
      expect(StudioServer.contentTypeFor('a.svg'), 'image/svg+xml');
      expect(StudioServer.contentTypeFor('a.png'), 'image/png');
      expect(StudioServer.contentTypeFor('a.woff2'), 'font/woff2');
    });

    test('大小写不敏感（产物里有 .PNG 这种）', () {
      expect(StudioServer.contentTypeFor('A.PNG'), 'image/png');
      expect(StudioServer.contentTypeFor('Index.HTML'), startsWith('text/html'));
    });

    test('认不出来给二进制默认（不要让浏览器猜成 HTML）', () {
      expect(StudioServer.contentTypeFor('a.bin'), 'application/octet-stream');
    });
  });
}
