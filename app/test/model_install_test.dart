/// 「下载 → 校验 → 解包 → 复核」整条链路的测试（对着**本地 HTTP 服务器**跑真流程）。
///
/// 为什么值得这么做：这条链路上每一步都有"看起来成功、其实坏掉"的失败方式 ——
/// 半截的压缩包、hash 不对、解包只解出一半、那个 172 MB 的文件被一起解出来……
/// 光测纯函数抓不到它们。这里起一个真服务器，把被测代码真的走一遍。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/local/local_tts.dart';
import 'package:dsh_mobile/local/android_toolbox.dart';
import 'package:dsh_mobile/local/model_downloader.dart' show ModelDownloader;
import 'package:dsh_mobile/local/model_install.dart';

import '_tar_fixture.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  late Uint8List pack; // 造好的"模型包"（tar.bz2 字节）
  late String packSha;
  var status = 200;
  var hits = 0;

  /// 夹具：一个包含必需文件 + 那个 172 MB 规则文件（这里用 100 KB 代表）的包。
  Future<Uint8List?> buildPack() async {
    final tarBytes = tarWithFiles(<String, List<int>>{
      'vits-icefall-zh-aishell3/model.onnx':
          List<int>.generate(8192, (i) => (i * 7) % 251),
      'vits-icefall-zh-aishell3/lexicon.txt': 'lexicon-content'.codeUnits,
      'vits-icefall-zh-aishell3/tokens.txt': 'tokens-content'.codeUnits,
      'vits-icefall-zh-aishell3/rule.far': List<int>.filled(100000, 7),
    });
    return bzip2Bytes(tarBytes);
  }

  /// node 的**绝对路径**。
  ///
  /// ⚠️ 这里踩过一次：写成 'node' 会 "No such file or directory" —— 因为
  /// `runtime.environment` 里的 PATH 是 **Android 的** `/system/bin:/system/xbin`，
  /// 在 Linux 上跑测试时找不到 node。真机上 `nodeBinary` 本来就是绝对路径，
  /// 所以测试也照做（这样测的才是真形状）。
  final String nodePath = () {
    final r = Process.runSync('sh', <String>['-c', 'command -v node']);
    return r.stdout.toString().trim();
  }();

  DshRuntime runtimeFor(String filesDir) => DshRuntime(<String, dynamic>{
        'filesDir': filesDir,
        'nodeHome': '$filesDir/dshhome',
        // 用**仓库里那个真脚本**（不是测试里另写一份）——
        // 这样"资产没进包/脚本不在"这类问题才会在这里露出来。
        'toolboxDir': 'assets/toolbox',
        'nodeBinary': nodePath,
      });

  /// 把随包的工具箱脚本**照 App 的做法**落到 `<filesDir>/toolbox`。
  ///
  /// 为什么要这一步：`DshRuntime.toolboxDir` 是**派生**的（`$filesDir/toolbox`），
  /// 设备上这些脚本是 App 启动时从 assets 拷过去的（见 android_toolbox.dart）。
  /// 测试里也得铺一遍 —— 而且直接**用那张复制表**来铺，等于顺带核对了
  /// "脚本与其 vendor 依赖的相对结构"是对的。
  void layDownToolbox(String filesDir) {
    const map = AndroidToolbox.assets;
    map.forEach((from, to) {
      final src = File(from);
      if (!src.existsSync()) return;
      final dst = File('$filesDir/$to');
      dst.parent.createSync(recursive: true);
      src.copySync(dst.path);
    });
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('dsh-install-');
    layDownToolbox(tmp.path);
    final built = await buildPack();
    expect(built, isNotNull, reason: '本机要有 bzip2 才能造夹具');
    pack = built!;
    final packFile = File('${tmp.path}/pack.tar.bz2')..writeAsBytesSync(pack);
    packSha = await ModelDownloader.sha256OfFile(packFile.path);
    packFile.deleteSync();

    status = 200;
    hits = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      hits++;
      req.response.statusCode = status;
      if (status == 200) {
        req.response.headers.contentLength = pack.length;
        req.response.add(pack);
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  TtsModelInstaller installer({int? bytes, String? sha, List<String>? skip}) =>
      TtsModelInstaller(
        runtime: runtimeFor(tmp.path),
        downloadUrl: 'http://127.0.0.1:${server.port}/pack.tar.bz2',
        expectedBytes: bytes ?? pack.length,
        expectedSha256: sha ?? packSha,
        skipFiles: skip ?? const <String>['rule.far'],
      );

  test('正常路径：下载 → 校验 → 解包 → 复核，且**那个大文件不会被解出来**', () async {
    final progress = <double>[];
    final r = await installer().install(
      onProgress: (f, _) => progress.add(f),
    );
    expect(r.ok, isTrue, reason: r.error);
    expect(r.installed, isTrue);
    expect(hits, 1);

    final tts = LocalTts(tmp.path);
    expect(tts.installed, isTrue);
    expect(tts.hasRuleFsts, isFalse, reason: '夹具里没有规则 fst，就该如实说没有');
    final model = File(tts.filePath('model.onnx'));
    expect(model.existsSync(), isTrue);
    expect(model.lengthSync(), 8192);
    expect(
        model.readAsBytesSync().sublist(0, 8),
        List<int>.generate(8, (i) => (i * 7) % 251),
        reason: '解出来的内容必须逐字节一致');
    expect(File(tts.filePath('rule.far')).existsSync(), isFalse,
        reason: '172 MB 的规则文件必须被 --skip 挡住（不省这一步磁盘会翻 6 倍）');
    // 压缩包用完要删掉（别白占 30 MB）
    expect(File(installer().tarPath).existsSync(), isFalse);
    expect(progress, isNotEmpty);
    expect(progress.last, 1);
  });

  test('sha256 对不上：必须拒绝、删掉压缩包、绝不能当成装好了', () async {
    final r = await installer(sha: 'f' * 64).install();
    expect(r.ok, isFalse);
    expect(r.error, contains('校验不通过'));
    expect(LocalTts(tmp.path).installed, isFalse);
    expect(File(installer().tarPath).existsSync(), isFalse, reason: '坏包要删掉');
  });

  test('大小对不上：直接判为下载不完整', () async {
    final r = await installer(bytes: pack.length + 10).install();
    expect(r.ok, isFalse);
    expect(r.error, contains('大小不对'));
    expect(LocalTts(tmp.path).installed, isFalse);
  });

  test('HTTP 404：给人话（带状态码），不是抛底层异常', () async {
    status = 404;
    final r = await installer().install();
    expect(r.ok, isFalse);
    expect(r.error, contains('404'));
  });

  test('下载被截断（声明全长、只发一半、然后断开）→ 判为中断，且 .part 留着续传', () async {
    // ⚠️ 这个夹具只能自己写裸 socket：Dart 的 `HttpResponse` **不允许**
    //    "声明 940 字节、只写 470 字节就 close"（它自己会抛
    //    Content size below specified contentLength）—— 那测的是服务器，不是我们。
    //    真机上"下到一半断网"就长这样：说好 31 MB，来了 15 MB，连接没了。
    final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final conn = raw.first;
    unawaited(conn.then((socket) {
      socket.write('HTTP/1.1 200 OK\r\n'
          'Content-Type: application/octet-stream\r\n'
          'Content-Length: ${pack.length}\r\n'
          'Connection: close\r\n\r\n');
      socket.add(pack.sublist(0, pack.length ~/ 2));
      return socket.flush().then((_) => socket.destroy());
    }));
    final inst = TtsModelInstaller(
      runtime: runtimeFor(tmp.path),
      downloadUrl: 'http://127.0.0.1:${raw.port}/pack.tar.bz2',
      expectedBytes: pack.length,
      expectedSha256: packSha,
    );
    final r = await inst.install();
    expect(r.ok, isFalse);
    expect(r.error, contains('中断'), reason: '被掐断要说"中断"，别只说"失败"');
    expect(r.error, contains('续传'), reason: '要告诉用户"进度留着、可以重试"');
    expect(LocalTts(tmp.path).installed, isFalse);
    expect(File(inst.partPath).existsSync(), isTrue,
        reason: '半截的 .part 必须留着，否则重试要重下 31 MB');
    expect(inst.downloadedBytes(), greaterThan(0), reason: '这次是真收到了一半');
    await raw.close();
  });

  test('取消：返回"已取消"，且 .part 留着（下次接着下）', () async {
    final cancel = TtsInstallCancel()..cancel();
    final r = await installer().install(cancel: cancel);
    expect(r.ok, isFalse);
    expect(r.error, contains('已取消'));
    final inst = installer();
    expect(File(inst.partPath).existsSync(), isTrue,
        reason: '.part 要留着（哪怕这次读到 0 字节，下次也是从这里续）');
    expect(inst.state(), TtsInstallState.partialDownload);
  });

  test('状态机：什么都没有 → absent；有 .part → partialDownload', () {
    final inst = installer();
    expect(inst.state(), TtsInstallState.absent);
    File(inst.partPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('half');
    expect(inst.state(), TtsInstallState.partialDownload);
    expect(inst.downloadedBytes(), 4);
    inst.clearCache();
    expect(inst.state(), TtsInstallState.absent);
  });
}
