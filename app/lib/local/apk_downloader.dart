/// 下载「更新包」（APK），供**应用内安装**使用。
///
/// ## 为什么不直接复用模型下载器
///
/// `model_downloader.dart` 是给"端侧模型"写的，三处对不上：
///   * 它要**多源测速**（几十个镜像里挑最快的），而更新包只有一个官方直链；
///   * 它的入参是 `OnDeviceModel` 条目 + `ModelSource` 列表，为此造一个假条目
///     只会把两边都搞脏；
///   * 模型下完就结束了，更新包还要接**签名校验 → 交给系统安装**这条链路。
///
/// 但**三条底线是同一条**，而且 [sha256OfFile] 直接复用模型下载器那份实现
/// （同一件事两处实现，是本项目明确反对的）：
///   ① **校验通过才改名** —— 先写 `.part`，哈希对得上才 `rename` 成正式名。
///      中途断电/被杀，磁盘上留下的是一个 `.part`，而不是一个"看起来下好了"的坏包；
///   ② **服务器不认 Range 就从头重下** —— 明明要了续传、服务器却整段返回时，
///      接着旧内容写会拼出一个**坏文件**（校验才发现，白下 110 MB）；
///   ③ **哈希不符就是失败** —— 删掉坏包、如实报错，绝不"先装上再说"。
///
/// ⚠️ **不做**的事（写在代码里免得后来人加错）：不自动安装、不校验签名。
/// 签名校验必须走原生（`PackageManager.getPackageArchiveInfo` + 与已装应用比对），
/// 见 `local/apk_installer.dart`。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../i18n/dsh_i18n.dart';
import 'model_downloader.dart' show ModelDownloader;
// `formatBytes` 复用「检查更新」那份（纯函数、不反向依赖本文件，**没有循环**）——
// 同一个大小在两处显示成不同写法，用户会以为下错了包。
import 'update_checker.dart' show formatBytes;

/// 下载进度（界面用）。[total] 为 0 表示服务器没给长度（此时不画百分比）。
class ApkDownloadProgress {
  const ApkDownloadProgress({
    required this.received,
    required this.total,
    required this.bytesPerSecond,
  });

  final int received;
  final int total;
  final double bytesPerSecond;

  /// 0~1；长度未知时 null（界面据此画"不确定进度条"而不是骗人的百分比）。
  double? get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;
}

/// 下载结果。[hashVerified] 为 false 只会出现在"调用方没给哈希"的情况。
class ApkDownloadResult {
  const ApkDownloadResult({
    required this.path,
    required this.bytes,
    required this.sha256,
    required this.hashVerified,
    required this.resumed,
    required this.elapsed,
  });

  final String path;
  final int bytes;
  final String? sha256;
  final bool hashVerified;

  /// 这一次是不是接着上次的 `.part` 继续下的。
  final bool resumed;
  final Duration elapsed;
}

/// 下载失败（已翻成中文人话，界面直接显示）。
class ApkDownloadException implements Exception {
  const ApkDownloadException(this.zh, {this.detail});

  final String zh;
  final String? detail;

  @override
  String toString() => detail == null ? zh : '$zh（$detail）';
}

/// 安装包的体积上限（2 GB）。
///
/// 现实里 APK 是 100 MB 量级，2 GB 是**留足余量后仍然荒谬**的数字。
/// 为什么要有它：清单来自网络，万一被人改成指向一个巨大的文件，
/// 用户一点「下载」就是几个 G 的流量 —— 而且他看不出来在下什么。
const int kMaxApkBytes = 2 * 1024 * 1024 * 1024;

/// 只保留**纯文件名**（防路径穿越）。
///
/// `fileName` 是从清单里的 `url` 推出来的，也就是**网络给的东西**。
/// 不处理就落盘的话，一个 `url` 末尾写着 `..%2F..%2Fconfig.json`
/// 就可能写到私有目录外面去 —— 所以这里把目录分隔符与一切可疑字符都换掉。
String sanitizeApkFileName(String raw) {
  final base = raw.split(RegExp(r'[\\/]')).last.trim();
  // 只留字母数字、点、下划线、连字符（APK 的名字本来就只有这些）。
  final cleaned = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'update.apk';
  return cleaned;
}

/// 用户主动取消（**不是错误**，界面不该报红）。
class ApkDownloadCancelled implements Exception {
  const ApkDownloadCancelled();
}

/// 取消令牌（与模型下载器同一套用法：界面点「取消」时 `cancel()`）。
class ApkDownloadCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// 更新包下载器。
class ApkDownloader {
  ApkDownloader({
    required this.dir,
    this.connectTimeout = const Duration(seconds: 20),
    HttpClient Function()? clientFactory,
  }) : _client = (clientFactory ?? HttpClient.new)();

  /// 落盘目录（真机上是 `<filesDir>/updates`，已在 FileProvider 白名单里）。
  final String dir;
  final Duration connectTimeout;
  final HttpClient _client;

  void close() {
    _client.close(force: true);
  }

  /// 下载 [url] 到 `dir/fileName`，返回落盘路径。
  ///
  /// [expectSha256] 非空时**必须**匹配，否则抛 [ApkDownloadException] 并删掉坏包；
  /// 为空时只保证字节完整（`hashVerified` 会是 false，界面要如实说"没有哈希可校验"）。
  ///
  /// **幂等**：目标文件已存在且哈希对得上 → 直接返回，不重新下载。
  /// 这很重要：用户点两次「下载」，第二次不该重下 110 MB。
  Future<ApkDownloadResult> download({
    required String url,
    required String fileName,
    String? expectSha256,
    int? expectBytes,
    void Function(ApkDownloadProgress)? onProgress,
    ApkDownloadCancelToken? cancel,
  }) async {
    final want = (expectSha256 ?? '').trim().toLowerCase();
    // ⚠️ **文件名必须先洗一遍**（见 [sanitizeApkFileName]）：它是从清单里的 url
    //    推出来的，也就是网络给的东西 —— 不洗就可能写到私有目录外面去。
    final safeName = sanitizeApkFileName(fileName);
    final directory = Directory(dir);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    final target = File('$dir/$safeName');
    final part = File('$dir/$safeName.part');

    // 清单自报的体积就已经超限 → 早拒绝（连请求都不发）。
    if (expectBytes != null && expectBytes > kMaxApkBytes) {
      throw ApkDownloadException(
        tr('清单里写的包大小大得不像话（{0}），不下。', [formatBytes(expectBytes)]),
        detail: 'expectBytes=$expectBytes limit=$kMaxApkBytes',
      );
    }

    // 已经下好过了（且哈希对得上）→ 直接用，不重下。
    if (target.existsSync() && target.lengthSync() > 0) {
      final have = await ModelDownloader.sha256OfFile(target.path);
      if (want.isEmpty || have == want) {
        debugPrint('[dsh-update] 目标已存在且校验通过，跳过下载：${target.path}');
        return ApkDownloadResult(
          path: target.path,
          bytes: target.lengthSync(),
          sha256: have,
          hashVerified: want.isNotEmpty,
          resumed: false,
          elapsed: Duration.zero,
        );
      }
      // 哈希对不上 = 上次留下的东西是坏的（或被换过）→ 丢掉重下。
      debugPrint('[dsh-update] 已存在的包哈希不符，删除重下：${target.path}');
      target.deleteSync();
    }

    var offset = part.existsSync() ? part.lengthSync() : 0;
    // `.part` 比官方大小还大 = 上次写坏了，别在垃圾后面接着写。
    if (expectBytes != null && expectBytes > 0 && offset > expectBytes) {
      debugPrint('[dsh-update] .part 比预期还大（$offset > $expectBytes），丢弃重下');
      part.deleteSync();
      offset = 0;
    }

    final sw = Stopwatch()..start();
    final req = await _client.getUrl(Uri.parse(url)).timeout(connectTimeout);
    if (offset > 0) {
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    }
    // 有些 CDN 对没有 UA 的请求会 403/400；带上自己认得的 UA 也便于对方排查。
    req.headers.set(HttpHeaders.userAgentHeader, 'paopaocat-dsh-mobile-updater');
    final res = await req.close().timeout(connectTimeout);

    final okFresh = res.statusCode == HttpStatus.ok;
    final okResume = res.statusCode == HttpStatus.partialContent;
    if (!okFresh && !okResume) {
      await res.drain<void>();
      throw ApkDownloadException(
        tr('下载失败：服务器返回 {0}。', ['HTTP ${res.statusCode}']),
        detail: 'status=${res.statusCode} url=$url',
      );
    }
    // 要了续传、服务器却整段返回 → 必须丢掉旧内容，否则拼出来的是坏文件。
    // （实测踩过：不看这一条会"下完 110 MB 才发现哈希不符"。）
    if (offset > 0 && !okResume) {
      debugPrint('[dsh-update] 服务器不支持 Range（HTTP ${res.statusCode}），从头重下');
      offset = 0;
      if (part.existsSync()) part.deleteSync();
    }

    // ⚠️ `resumed` **必须在这之后**才算：要"真的从断点接着写"才算续传。
    //    放在请求之前判的话，服务器不认 Range（整段返回、我们被迫从头重下）时
    //    会**谎报"续传"** —— 这是测试当场抓到的真 bug，别把它挪回去。
    final resumed = offset > 0;

    final total = (res.contentLength > 0 && res.contentLength != -1)
        ? offset + res.contentLength
        : (expectBytes ?? 0);
    final sink = part.openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
    var received = offset;
    var lastTick = 0;
    // 速率窗口：只留最近 ~3 秒的采样（全程平均会迟钝，用户看到的是"现在多快"）。
    const windowMs = 3000;
    var winStartMs = 0;
    var winStartBytes = offset;

    try {
      await for (final chunk in res) {
        if (cancel?.isCancelled ?? false) {
          throw const ApkDownloadCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        // 边收边判上限（不是收完再判）：真被指向一个大文件时，
        // 要在流量烧掉之前就停，而不是下完 3 GB 才发现。
        if (received > kMaxApkBytes) {
          throw ApkDownloadException(
            tr('这个包大得不像话（超过 {0}），已经停下不下了。',
                [formatBytes(kMaxApkBytes)]),
            detail: 'received=$received limit=$kMaxApkBytes',
          );
        }
        final ms = sw.elapsedMilliseconds;
        if (ms - lastTick >= 200) {
          lastTick = ms;
          if (ms - winStartMs > windowMs) {
            winStartMs = ms;
            winStartBytes = received;
          }
          final span = ms - winStartMs;
          onProgress?.call(ApkDownloadProgress(
            received: received,
            total: total,
            bytesPerSecond:
                span <= 0 ? 0 : (received - winStartBytes) * 1000 / span,
          ));
        }
      }
    } on SocketException catch (e) {
      throw ApkDownloadException(tr('下载中断：连接断了。'), detail: e.message);
    } on HttpException catch (e) {
      throw ApkDownloadException(tr('下载中断：传输出错。'), detail: e.message);
    } finally {
      await sink.flush();
      await sink.close();
    }

    // 到了这一步才校验 —— 校验通过才让它变成"正式文件"。
    final size = part.lengthSync();
    if (expectBytes != null && expectBytes > 0 && size != expectBytes) {
      // 大小都不对就不必算哈希了（省一次 110 MB 的读），但要留着 .part 供续传。
      throw ApkDownloadException(
        tr('下载不完整：只拿到 {0}，应为 {1}。',
            [formatBytes(size), formatBytes(expectBytes)]),
        detail: 'size=$size expect=$expectBytes',
      );
    }
    final actual = await ModelDownloader.sha256OfFile(part.path);
    if (want.isNotEmpty && actual != want) {
      // 哈希不符 = 这个包不可信（下载坏了，或中途被人换过）。
      // **必须删掉**：留着一个"看起来下好了"的坏包，下次点击会拿去装。
      part.deleteSync();
      throw ApkDownloadException(
        tr('下载到的包校验没通过（哈希不符），已删除。这通常是下载中途坏了，请重试一次。'),
        detail: 'sha256=$actual want=$want url=$url',
      );
    }

    if (target.existsSync()) target.deleteSync();
    part.renameSync(target.path);
    debugPrint('[dsh-update] 下载完成并校验通过：${target.path}（$size 字节，'
        '${resumed ? "续传" : "全新"}，${sw.elapsedMilliseconds} ms）');

    return ApkDownloadResult(
      path: target.path,
      bytes: size,
      sha256: actual,
      hashVerified: want.isNotEmpty,
      resumed: resumed,
      elapsed: sw.elapsed,
    );
  }
}
