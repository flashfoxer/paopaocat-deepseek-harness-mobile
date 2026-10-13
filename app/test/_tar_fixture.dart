/// 造 tar / tar.bz2 测试夹具的公用工具（**独立于被测代码**手工拼字节）。
///
/// 为什么单独一个文件：`local_tts_test.dart`（解包器）与
/// `model_install_test.dart`（下载+安装）都要用，复制两份早晚会不一致。
library;

import 'dart:io';
import 'dart:typed_data';

/// 手工拼一个 tar 头（tar 头是定长 512 字节，八进制字段 + 校验和）。
Uint8List tarHeader(String name, int size) {
  final h = Uint8List(512);
  void put(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      h[off + i] = s.codeUnitAt(i);
    }
  }

  put(0, name);
  put(100, '0000755\u0000');
  put(108, '0000000\u0000');
  put(116, '0000000\u0000');
  put(124, '${size.toRadixString(8).padLeft(11, '0')}\u0000');
  put(136, '00000000000\u0000');
  put(148, '        '); // 校验和先当 8 个空格
  h[156] = '0'.codeUnitAt(0);
  put(257, 'ustar\u0000');
  var sum = 0;
  for (final b in h) {
    sum += b;
  }
  put(148, '${sum.toRadixString(8).padLeft(7, '0')}\u0000');
  return h;
}

/// 造一个含若干文件的 tar（路径 → 内容）。
Uint8List tarWithFiles(Map<String, List<int>> files) {
  final out = <int>[];
  files.forEach((name, body) {
    final pad = (512 - body.length % 512) % 512;
    out
      ..addAll(tarHeader(name, body.length))
      ..addAll(body)
      ..addAll(List<int>.filled(pad, 0));
  });
  out.addAll(List<int>.filled(1024, 0)); // 结束块
  return Uint8List.fromList(out);
}

/// 用系统 `bzip2` 把 [tarBytes] 压成 bz2 字节（没有 bzip2 就返回 null）。
Future<Uint8List?> bzip2Bytes(Uint8List tarBytes) async {
  final has = await Process.run('sh', <String>['-c', 'command -v bzip2']);
  if (has.exitCode != 0) return null;
  final tmp = Directory.systemTemp.createTempSync('dsh-bz2-');
  try {
    final src = File('${tmp.path}/in.tar')..writeAsBytesSync(tarBytes);
    final r = await Process.run('bzip2', <String>['-z', '-f', '-k', src.path]);
    if (r.exitCode != 0) return null;
    final out = File('${src.path}.bz2');
    return out.existsSync() ? out.readAsBytesSync() : null;
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}
