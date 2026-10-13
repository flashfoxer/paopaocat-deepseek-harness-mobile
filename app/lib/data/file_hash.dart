/// 文件哈希（流式 sha256）+ **等时字符串比较**（认证要素用）。
///
/// 为什么单独一个文件：这个实现原来只长在 `model_downloader.dart` 里，
/// 于是知识库那边要么复制一份、要么就只能"只看体积"。而"只看体积"正是
/// 审计 P0-4 说的问题 —— 同长度的损坏发现不了。
/// 现在两份下载路径共用这一处实现（审计也点名过"同一件事多处实现"的危害）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 算 sha256 失败（读不出来 / 摘要算不出来）。
class FileHashException implements Exception {
  const FileHashException(this.message);

  final String message;

  @override
  String toString() => 'FileHashException: $message';
}

/// 流式计算文件的 sha256，返回 64 位小写十六进制。
///
/// 逐块读（默认 64 KiB），所以 500 MB 的知识库包和 3 GB 的模型文件都不会
/// 把内存吃爆。500 MB 在这台机器上约 1.6 秒；手机上是几秒量级，可以接受。
Future<String> sha256OfFile(String path) async {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  try {
    await for (final chunk in File(path).openRead()) {
      input.add(chunk);
    }
    input.close();
  } on FileSystemException catch (e) {
    throw FileHashException('读文件失败：${e.message}');
  } catch (e) {
    throw FileHashException('$e');
  }
  final digest = sink.value;
  if (digest == null) {
    throw const FileHashException('算不出摘要');
  }
  return digest.toString();
}

/// `crypto` 的分块转换需要一个 `Sink<Digest>`；这里给它一个只保留最后一个值的实现。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 等时比较两个字符串 —— 认证要素（令牌/配对码）**不能**用 `==`。
///
/// 为什么：`==` 一旦发现某个字节不同就立刻返回，比较耗时随"猜对了几个字节"
/// 变化 —— 理论上可以逐字节爆破。Dart 标准库没有 `timingSafeEqual`，
/// 所以这里**先各自数成 sha256 摘要再逐字节异或**：两边都走同一条定长路径，
/// 长度不同也不会提前返回。
///
/// 诚实的边界：摘要长度仍是输入长度的函数，所以"输入长度"本身会泄露一点点
/// 时间（对我们的令牌/6 位配对码无所谓）。它拦住的是**按内容**的时序侧信道。
bool constantTimeEquals(String a, String b) {
  final da = sha256.convert(utf8.encode(a)).bytes;
  final db = sha256.convert(utf8.encode(b)).bytes;
  var diff = 0;
  for (var i = 0; i < da.length; i++) {
    diff |= da[i] ^ db[i];
  }
  return diff == 0;
}
