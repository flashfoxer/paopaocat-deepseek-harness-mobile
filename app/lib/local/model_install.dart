import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'dsh_runtime.dart';
import '../i18n/dsh_i18n.dart' show tr;
import 'local_tts.dart';
import 'model_downloader.dart' show ModelDownloader;

/// 「本机离线配音」模型的**下载 + 校验 + 解包**流程。
///
/// ## 每一步为什么这么做（都是踩过或想过才写上的）
///
/// 1. **先下载成 `.part`，支持断点续传**：31.5 MB 在手机上一次下完并不常见 ——
///    我在本机验证时就撞见过一次"下到 29.6/31.6 MB 被截断"，
///    所以按 `Range` 续传是刚需，不是优化。
/// 2. **先核对 sha256，再解包**：一个半截的压缩包**看起来像正常的文件**，
///    而"模型坏没坏"用户根本归因不了（可能只是某几个音发错）。
///    哈希对不上就删掉重来。
/// 3. **解包时 `--skip=rule.far`**：包里那个 172 MB 的规则文件实测**对我们没用**
///    （带它反而把数字读得更短、加载慢 3 倍）。不跳过的话解包峰值占用 204 MB，
///    而真正需要的只有 32 MB。
/// 4. **解完再复核一次必需文件**，然后才删压缩包 —— 失败时留着压缩包，
///    用户重试不必重下。
class TtsModelInstaller {
  TtsModelInstaller({
    required this.runtime,
    String? downloadUrl,
    int? expectedBytes,
    String? expectedSha256,
    List<String>? skipFiles,
  })  : downloadUrl = downloadUrl ?? LocalTts.downloadUrl,
        expectedBytes = expectedBytes ?? LocalTts.downloadBytes,
        expectedSha256 = expectedSha256 ?? LocalTts.downloadSha256,
        skipFiles = skipFiles ?? LocalTts.skipFiles;

  final DshRuntime runtime;

  /// 发布包地址（**可注入**：测试里指向一个本地 HTTP 服务器，
  /// 这样"下载 → 校验 → 解包 → 复核"整条链路都能被真正跑到，
  /// 而不是只测几个纯函数）。
  final String downloadUrl;

  /// 期望字节数与 sha256（同样可注入，理由同上）。
  final int expectedBytes;
  final String expectedSha256;

  /// 解包时跳过的文件名（默认跳过那个 172 MB 的 rule.far）。
  final List<String> skipFiles;

  String get filesDir => runtime.filesDir;

  /// 下载暂存目录（与模型目录分开，方便整体删掉）。
  String get downloadDir => '$filesDir/tts/download';

  String get tarPath => '$downloadDir/${LocalTts.modelId}.tar.bz2';
  String get partPath => '$tarPath.part';

  /// 官方发布页（给人看的一句话里用得到）。
  static const String releasePage =
      'https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models';

  /// 现在该显示什么（界面按它渲染）。
  TtsInstallState state() {
    if (LocalTts(filesDir).installed) return TtsInstallState.installed;
    if (File(partPath).existsSync()) return TtsInstallState.partialDownload;
    if (File(tarPath).existsSync()) return TtsInstallState.downloaded;
    return TtsInstallState.absent;
  }

  /// 已下载的字节数（用于进度条的初始值 / 续传提示）。
  int downloadedBytes() {
    final part = File(partPath);
    if (part.existsSync()) return part.lengthSync();
    return 0;
  }

  /// 下载 → 校验 → 解包 → 复核。成功返回 [TtsInstallResult.ok]。
  ///
  /// [onProgress] 收到的是**总进度**（0–1），包含"下载"与"解包"两段：
  /// 下载占 0–0.85（解包那 5 秒不该让进度条看起来卡住），解包占 0.85–1。
  Future<TtsInstallResult> install({
    void Function(double fraction, String label)? onProgress,
    TtsInstallCancel? cancel,
  }) async {
    final tts = LocalTts(filesDir);
    if (tts.installed) {
      onProgress?.call(1, tr('模型已就绪'));
      return const TtsInstallResult(ok: true, installed: true);
    }
    await Directory(downloadDir).create(recursive: true);

    // ── ① 下载（能续就续）
    if (!File(tarPath).existsSync()) {
      try {
        await _fetch(onProgress: onProgress, cancel: cancel);
      } on _Cancelled {
        return TtsInstallResult(
            ok: false, error: tr('已取消（已下载的部分留着，下次接着下）'));
      } on TtsInstallException catch (e) {
        return TtsInstallResult(ok: false, error: e.message);
      }
    }

    // ── ② 校验
    onProgress?.call(0.86, tr('正在校验完整性'));
    final tar = File(tarPath);
    if (!tar.existsSync()) {
      return TtsInstallResult(ok: false, error: tr('下载的压缩包不见了，请重试。'));
    }
    final bytes = tar.lengthSync();
    if (bytes != expectedBytes) {
      // 大小不对：**留着 .part 的语义已经不适用**（文件已改名），直接删掉重来
      try {
        tar.deleteSync();
      } catch (_) {}
      return TtsInstallResult(
        ok: false,
        error: tr('压缩包大小不对（{0} 字节，应为 {1}）——下载不完整，已删掉，请重试。',
                <Object?>['$bytes', '$expectedBytes']),
      );
    }
    final digest = await ModelDownloader.sha256OfFile(tarPath);
    if (digest.toLowerCase() != expectedSha256) {
      try {
        tar.deleteSync();
      } catch (_) {}
      return TtsInstallResult(
        ok: false,
        error: tr('压缩包校验不通过（sha256 对不上）——已删掉，请重试。'
                '如果总是这样，可能是网络中间有东西改了内容。'),
      );
    }

    // ── ③ 解包（node 里解 tar+bz2；跳过那个 172 MB 的 rule.far）
    onProgress?.call(0.88, tr('正在解包（这一步要几秒到几十秒）'));
    final extract = await _extract();
    if (!extract.ok) {
      return TtsInstallResult(ok: false, error: extract.error);
    }

    // ── ④ 复核 + 清理
    onProgress?.call(0.99, tr('正在复核'));
    final after = LocalTts(filesDir);
    if (!after.installed) {
      final missing = after.missingFiles;
      // 压缩包留着：用户重试时不用重下（但已解出的半个模型不能当成功）
      return TtsInstallResult(
        ok: false,
        error: tr('解出来的模型文件不齐，缺：{0}（压缩包已保留在 {1}，可以重试）',
                <Object?>[missing.join('、'), tarPath]),
      );
    }
    try {
      tar.deleteSync();
    } catch (_) {}
    onProgress?.call(1, tr('装好了'));
    return const TtsInstallResult(ok: true, installed: true);
  }

  /// 下载到 `.part`，然后改名成正式名。
  ///
  /// 续传：`.part` 已存在就先发 `Range: bytes=<len>-`；
  /// 服务端不支持（返回 200 而不是 206）就从头写。
  Future<void> _fetch({
    void Function(double fraction, String label)? onProgress,
    TtsInstallCancel? cancel,
  }) async {
    final part = File(partPath);
    var have = part.existsSync() ? part.lengthSync() : 0;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    // 31 MB 在慢网下要几分钟，别用短超时把它掐了（但也不能没有上限）。
    client.idleTimeout = const Duration(seconds: 90);
    IOSink? opened;
    var sinkClosed = false;
    Future<void> closeSink() async {
      final s = opened;
      opened = null;
      if (s != null && !sinkClosed) {
        sinkClosed = true;
        await s.flush();
        await s.close();
      }
    }

    try {
      final req = await client.getUrl(Uri.parse(downloadUrl));
      req.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      req.headers.set(HttpHeaders.userAgentHeader, 'dsh-mobile');
      if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final resp = await req.close();
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw TtsInstallException(tr('下载失败：HTTP {0}（{1}）', <Object?>['${resp.statusCode}', downloadUrl]));
      }
      if (have > 0 && resp.statusCode == 200) {
        // 服务端不认 Range：从头来，别把两段拼在一起
        have = 0;
        try {
          part.deleteSync();
        } catch (_) {}
      }
      final total = have + resp.contentLength;
      final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      opened = sink;
      var got = have;
      var lastReport = DateTime.now();
      await for (final chunk in resp) {
        if (cancel?.cancelled ?? false) {
          await closeSink();
          client.close(force: true);
          throw const _Cancelled();
        }
        sink.add(chunk);
        got += chunk.length;
        final now = DateTime.now();
        // 进度回调别太密（每 120ms 一次足够顺滑，也不会把界面刷爆）
        if (now.difference(lastReport).inMilliseconds > 120) {
          lastReport = now;
          final frac = total > 0 ? got / total : 0.0;
          onProgress?.call((frac * 0.85).clamp(0, 0.85),
              tr('正在下载模型 {0} / {1} MB',
                  <Object?>[_mb(got), total > 0 ? _mb(total) : '?']));
        }
      }
      await closeSink();
      client.close();
      // ⚠️ 关掉了流才改名（顺序反了在 Windows 上会失败，在手机上也可能拿到半个文件）
      if (part.existsSync()) part.renameSync(tarPath);
      if (total > 0 && got != total) {
        throw TtsInstallException(tr('下载中断（拿到 {0} / {1} 字节）—— 已保留进度，可以重试续传。',
              <Object?>['$got', '$total']));
      }
      onProgress?.call(0.85, '下载完成');
    } on _Cancelled {
      rethrow;
    } on TtsInstallException {
      rethrow;
    } on HttpException catch (e) {
      // 半途连接被关掉最常见（走到这里说明响应没读全）——措辞要让人知道"进度还在"。
      throw TtsInstallException(
          tr('下载中断：连接被提前关掉了（{0}）。已保留进度，可以重试续传。',
              <Object?>[e.message]));
    } catch (e) {
      throw TtsInstallException(tr('下载失败：{0}（已保留进度，可以重试续传）', <Object?>['$e']));
    } finally {
      try {
        await closeSink();
      } catch (_) {}
      client.close(force: true);
    }
  }

  static String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

  /// 调随包的 `untar-bz2.mjs` 解包。
  Future<({bool ok, String error})> _extract() async {
    final script = '${runtime.toolboxDir}/untar-bz2.mjs';
    if (!File(script).existsSync()) {
      return (
        ok: false,
        error: tr('工具箱脚本不在（{0}）—— App 首次启动没能把脚本落盘，请重启 App 再试。',
            <Object?>[script]),
      );
    }
    final outDir = '$filesDir/tts';
    Process proc;
    try {
      proc = await Process.start(
        runtime.nodeBinary,
        <String>[
          // ⚠️ 标志要放在脚本**前面**（node 的参数顺序）。`--no-deprecation` 是
          // 为了压掉 vendor 那份 seek-bzip 里的 `Buffer()` 弃用警告 ——
          // 它会往诊断日志里灌一行噪音，而那不是我们能修的上游代码。
          '--no-deprecation',
          script,
          tarPath,
          outDir,
          '--skip=${skipFiles.join(',')}',
        ],
        environment: runtime.environment,
        workingDirectory: runtime.filesDir,
      );
    } catch (e) {
      return (ok: false, error: tr('启动 node 解包失败：{0}', <Object?>['$e']));
    }
    final buffer = StringBuffer();
    void sink(String line) {
      buffer.writeln(line);
      debugPrint('[dsh-tts] untar: $line');
    }

    final outs = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(sink);
    final errs = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(sink);
    final code = await proc.exitCode;
    await outs.cancel();
    await errs.cancel();
    if (code != 0) {
      final tail = buffer
          .toString()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      final last = tail.isEmpty ? tr('（没有输出）') : tail.last;
      return (ok: false, error: tr('解包失败（退出码 {0}）：{1}', <Object?>['$code', last]));
    }
    return (ok: true, error: '');
  }

  /// 删掉模型的**下载缓存**（省空间用；已解出来的文件不动）。
  void clearCache() {
    for (final p in <String>[partPath, tarPath]) {
      final f = File(p);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
  }
}

/// 安装状态（界面按它决定显示"下载"还是"已就绪"）。
enum TtsInstallState {
  /// 什么都没下。
  absent,

  /// 下了一半（可以续传）。
  partialDownload,

  /// 下完了（还没解包）。
  downloaded,

  /// 可以直接用了。
  installed,
}

class TtsInstallResult {
  const TtsInstallResult({required this.ok, this.installed = false, this.error});
  final bool ok;
  final bool installed;
  final String? error;
}

class TtsInstallException implements Exception {
  const TtsInstallException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 取消令牌（与 `model_downloader.dart` 的 `DownloadCancelToken` 同形，
/// 但不共用 —— 那边是给本地大模型用的，语义上不该缠在一起）。
class TtsInstallCancel {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class _Cancelled implements Exception {
  const _Cancelled();
}
