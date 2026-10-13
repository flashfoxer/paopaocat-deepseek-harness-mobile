/// 「准备运行时」：确保 `dsh-runtime.zip` 在本地，再交给宿主解压。
///
/// ## 为什么要有这个文件（L3 包瘦身）
///
/// `dsh-runtime.zip` 是 DSH 的依赖树（26,495 个条目），**进 APK 占 30.1 MB** ——
/// 全包最大的一块，而且是"装一次、之后每次更新都不该重下"的数据。
/// 0.75 起它**不再随包**（APK 因此从 111.6 MB 降到约 81 MB），改由这里负责在
/// 首次启动时下载 + 校验，落盘到 `files/runtime.zip`。
///
/// **那个路径不是随便选的**：原生侧 `unpack()` 从 0.15 起就是"把 zip 拷到
/// `files/runtime.zip`，再用 ZipFile 解压"—— 所以只要我们把文件放在那儿，
/// 原生的解包逻辑**一行都不用改**。
///
/// ## 谁需要下载、谁不需要（这条决定了改造的安全性）
///
/// * **老用户（0.15~0.74 装过）**：`files/runtime.zip` 早就在那儿了（历次都是随包拷过去的），
///   `isRuntimeReady()` 直接为 true —— **根本不进这一页，一个字节都不下**；
/// * **全新安装 / 清了数据**：走这里下载一次（约 32 MB），之后同样不再需要；
/// * **运行时内容变了**：本地 zip 的 sha256 与清单对不上 → 自动重下（见 [ensureZip]）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../i18n/dsh_i18n.dart';
import 'apk_downloader.dart';
import 'model_downloader.dart' show ModelDownloader;
import 'update_checker.dart'
    show UpdateManifestError, fetchJsonManifest, formatBytes;
import 'update_source.dart' show kUpdateRepo;

/// 运行时清单（仓库根目录的 `runtime.json`）解析出来的信息。
///
/// 与 `update.json` 分开一个文件，是因为**两者的节奏不同**：APK 每次改动都要重发，
/// 而运行时只在依赖树真的变了时才需要重下。分开之后，重发 APK 不必惊动它。
class RuntimeManifest {
  const RuntimeManifest({
    required this.version,
    required this.url,
    this.size,
    this.sha256,
  });

  /// 运行时自身的版本号（内容变了才 +1）。
  final String version;

  /// zip 直链（Release 附件）。
  final String url;
  final int? size;

  /// zip 的 sha256（小写 hex）。**强烈建议给** —— 没有它就没法判断"本地这份是不是当前这份"。
  final String? sha256;

  static RuntimeManifest parse(String body) {
    if (body.trim().isEmpty) {
      throw UpdateManifestError(tr('运行时清单是空的。'), detail: 'empty body');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw UpdateManifestError(tr('运行时清单不是合法 JSON。'),
          detail: 'jsonDecode: ${e.message}');
    }
    if (decoded is! Map) {
      throw UpdateManifestError(tr('运行时清单的格式不对：它应该是一个 JSON 对象。'),
          detail: 'top-level = ${decoded.runtimeType}');
    }
    // ⚠️ 必须落成一个**新变量**再给下面的闭包用：Dart 的类型提升（`decoded` 从
    //    `Object?` 提升成 `Map`）**在闭包里会失效**（闭包可能在之后才执行，
    //    编译器不敢保证到时还是那个类型）→ 直接用 `decoded[k]` 会报
    //    `unchecked_use_of_nullable_value`。这不是风格问题，是编译错误。
    final map = decoded;

    String need(String k) {
      final v = map[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      throw UpdateManifestError(tr('运行时清单缺少 {0} 字段。', [k]),
          detail: '$k = ${v == null ? 'missing' : v.runtimeType}');
    }

    int? optInt(String k) {
      final v = map[k];
      if (v is int) return v;
      if (v is double) return v.toInt();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    final sha = map['sha256'];
    return RuntimeManifest(
      version: need('version'),
      url: need('url'),
      size: optInt('size'),
      sha256: (sha is String && sha.trim().isNotEmpty)
          ? sha.trim().toLowerCase()
          : null,
    );
  }
}

/// 「准备运行时」的结果。
///
/// 与下载器一致：**失败也走对象、不抛异常** —— 这一层跑在启动路径上，
/// 抛出去会让用户看到白屏。
class RuntimeBootstrapResult {
  const RuntimeBootstrapResult({
    required this.ok,
    this.errorZh,
    this.downloaded = false,
    this.verified = false,
    this.bytes,
  });

  final bool ok;

  /// 失败原因（中文人话）。
  final String? errorZh;

  /// 这一次是不是真的下载了（false = 本地那份已经是对的，直接用了）。
  final bool downloaded;

  /// 本地这份的哈希是否与清单一致（清单没给 sha256 时为 false）。
  final bool verified;

  /// 本地 zip 的字节数。
  final int? bytes;
}

/// 运行时包的本地文件名与路径。
///
/// ⚠️ 名字必须与原生 `MainActivity.unpack()` 里读的那个**逐字一致**（`runtime.zip`，
/// 位于 `filesDir` 下），否则原生那边会报"运行时包不在……"。
const String kRuntimeZipName = 'runtime.zip';

/// 运行时清单的地址（与 `update.json` 同一套：raw 主源 + jsDelivr 兜底）。
List<String> runtimeManifestSources() => <String>[
      'https://raw.githubusercontent.com/$kUpdateRepo/main/runtime.json',
      'https://cdn.jsdelivr.net/gh/$kUpdateRepo@main/runtime.json',
    ];

String runtimeZipPath(String filesDir) => '$filesDir/$kRuntimeZipName';

/// 确保运行时包就绪（必要时下载）。
///
/// 流程：**先看本地那份对不对，再决定要不要下** ——
///   * 本地有、且 sha256 与清单一致 → 直接算就绪（老用户走的就是这条，
///     连清单都不必拉，见 [isLocalZipUsable]）；
///   * 本地没有/不对 → 下载（断点续传 + 校验），落盘到 [runtimeZipPath]。
///
/// [onProgress] 报下载进度（只在真下载时回调）。
/// [cancel] 取消令牌。
Future<RuntimeBootstrapResult> ensureRuntimeZip({
  required String filesDir,
  String? customManifestSource,
  void Function(ApkDownloadProgress)? onProgress,
  ApkDownloadCancelToken? cancel,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final path = runtimeZipPath(filesDir);
  final local = File(path);

  // ① 先拉清单。**注意顺序**：即使本地已有 zip，也要拉清单才知道"它是不是当前这份" ——
  //    除非调用方明确只关心"有没有"（那是 [isLocalZipUsable] 的用法）。
  RuntimeManifest? manifest;
  final tried = <String>[];
  final sources = (customManifestSource ?? '').trim().isNotEmpty
      ? <String>[(customManifestSource!).trim()]
      : runtimeManifestSources();
  for (final base in sources) {
    try {
      final body = await fetchJsonManifest(base, timeout: timeout);
      manifest = RuntimeManifest.parse(body);
      debugPrint('[dsh-runtime-boot] 清单 OK：$base v${manifest.version}');
      break;
    } catch (e) {
      tried.add('$base → $e');
      debugPrint('[dsh-runtime-boot] 清单失败：$base → $e');
    }
  }

  if (manifest == null) {
    // 清单都拉不到时**还有一个可能的活路**：本地那份存在且非空。
    // 这种时候我们**不知道它是不是最新的**，但"能启动"优先于"一定是最新"
    // （否则网络差的用户会被永久挡在门外）。所以放行，但如实告诉调用方
    // `verified = false` —— 界面可以据此说一句"没校验到最新版"。
    if (local.existsSync() && local.lengthSync() > 0) {
      debugPrint('[dsh-runtime-boot] 清单拉不到，但本地已有 zip（'
          '${local.lengthSync()} 字节）→ 先用它');
      return RuntimeBootstrapResult(
        ok: true,
        downloaded: false,
        verified: false,
        bytes: local.lengthSync(),
      );
    }
    return RuntimeBootstrapResult(
      ok: false,
      errorZh: tr('拿不到「运行环境」的下载信息（网络不通或更新源连不上），'
          '所以这次装不了运行环境。你可以稍后重试；也可以把 runtime.zip '
          '放到这台手机的 {0} 目录下，再点一次「开始准备」。', [filesDir]),
    );
  }

  // ② 本地那份是对的？（哈希一致就直接用，**不重下**）
  final want = manifest.sha256;
  if (local.existsSync() && local.lengthSync() > 0) {
    if (want == null) {
      debugPrint('[dsh-runtime-boot] 清单没给 sha256，本地已有 zip → 直接用');
      return RuntimeBootstrapResult(
        ok: true,
        downloaded: false,
        verified: false,
        bytes: local.lengthSync(),
      );
    }
    final have = await ModelDownloader.sha256OfFile(path);
    if (have == want) {
      debugPrint('[dsh-runtime-boot] 本地 zip 与清单一致，无需下载');
      return RuntimeBootstrapResult(
        ok: true,
        downloaded: false,
        verified: true,
        bytes: local.lengthSync(),
      );
    }
    debugPrint('[dsh-runtime-boot] 本地 zip 与清单不符（$have ≠ $want）→ 重下');
  }

  // ③ 下载（复用通用大文件下载器：断点续传 + 边下边校验 + 校验通过才改名）。
  //
  //    为什么用 `ApkDownloader` 而不是新写一个：它要干的事**一模一样** ——
  //    "给一个 URL，落一个文件，sha256 对不上就删掉重来"。
  //    名字里那个 apk 是它的第一个使用场景，不是它的能力边界。
  final downloader = ApkDownloader(dir: filesDir, connectTimeout: timeout);
  try {
    final r = await downloader.download(
      url: manifest.url,
      fileName: kRuntimeZipName,
      expectSha256: want,
      expectBytes: manifest.size,
      onProgress: onProgress,
      cancel: cancel,
    );
    return RuntimeBootstrapResult(
      ok: true,
      downloaded: true,
      verified: want != null,
      bytes: r.bytes,
    );
  } on ApkDownloadCancelled {
    return const RuntimeBootstrapResult(ok: false, errorZh: '已取消');
  } on ApkDownloadException catch (e) {
    return RuntimeBootstrapResult(ok: false, errorZh: e.zh);
  } catch (e) {
    return RuntimeBootstrapResult(
      ok: false,
      errorZh: tr('下载运行环境时出错：{0}', ['$e']),
    );
  } finally {
    downloader.close();
  }
}

/// **不联网**地问一句：本地那份 zip "看起来能不能用"（存在且非空）。
///
/// 用在"已经解压好过一次"的场景上：那时没必要为了确认去联网拉清单。
/// 判断严格程度**故意低** —— 真正的校验在解压前那次 [ensureRuntimeZip] 里做。
bool isLocalZipUsable(String filesDir) {
  final f = File(runtimeZipPath(filesDir));
  return f.existsSync() && f.lengthSync() > 0;
}

/// 本地 zip 的大小标签（给界面显示/排查用）。
String localZipLabel(String filesDir) {
  final f = File(runtimeZipPath(filesDir));
  if (!f.existsSync()) return tr('还没有');
  return formatBytes(f.lengthSync());
}
