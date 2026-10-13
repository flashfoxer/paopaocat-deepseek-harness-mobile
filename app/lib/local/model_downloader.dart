import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/api_error_text.dart';
import '../data/file_hash.dart' as file_hash;
import '../i18n/dsh_i18n.dart' show tr;
import 'model_manifest.dart';

/// 一次下载的进度。
class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.received,
    required this.total,
    required this.sourceLabel,
    this.bytesPerSecond = 0,
  });

  final int received;
  final int total;
  final String sourceLabel;

  /// **最近约 3 秒**的实时速率（字节/秒）。
  ///
  /// 为什么不是全程平均：几 GB 的文件要下很久，全程平均会把"刚起来很快"和
  /// "某一秒掉到 0"糊成一个看起来很稳的数字 —— 界面要显示的是"现在多快"。
  final double bytesPerSecond;

  /// 0–1；总长未知时返回 0（不撒谎显示 "100%"）。
  double get fraction =>
      total <= 0 ? 0 : (received / total).clamp(0.0, 1.0).toDouble();
}

/// 下载成功后的结果。
class ModelDownloadResult {
  const ModelDownloadResult({
    required this.path,
    required this.bytes,
    required this.sourceLabel,
    required this.hashVerified,
    required this.resumed,
    required this.elapsed,
  });

  final String path;
  final int bytes;
  final String sourceLabel;

  /// 是否真的比对过 sha256。**false 时不要对外宣称"已校验"**。
  final bool hashVerified;

  /// 本次是否用了断点续传（对排查"下了一半重来"很重要）。
  final bool resumed;

  final Duration elapsed;

  @override
  String toString() => 'ModelDownloadResult($path, $bytes B, src=$sourceLabel, '
      'hash=${hashVerified ? 'ok' : 'skipped'}, resumed=$resumed, ${elapsed.inSeconds}s)';
}

/// 面向用户的下载失败。`message` 已经是本地化后的中文。
class ModelDownloadException implements Exception {
  const ModelDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 取消令牌。
class DownloadCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

typedef DownloadProgressCallback = void Function(
    ModelDownloadProgress progress);

/// 传输层错误：**可以换源重试**（网络断、5xx、超时）。与"校验失败"这种致命错分开。
class _TransportError implements Exception {
  const _TransportError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 端侧模型的**多源下载器**：测速选源 → 断点续传 → 校验 → 原子落盘。
///
/// ## 设计要点（都是踩过的坑）
///
/// * **多源测速**：清单里给 2–3 个源，先并发各取一小段测速，按实测速度排序。
///   实测源之间差 10 倍以上，写死顺序等于把一半用户丢给最慢的站。
/// * **断点续传**：1–3 GB 的文件在手机网络上必然中断。先写 `.part`，
///   下次用 `Range: bytes=<offset>-` 续；**服务器不认 Range（返回 200）时必须
///   从头写**，否则文件会被拼成"半截 + 完整"的垃圾（而且体积校验还过得去、
///   哈希校验才炸）。
/// * **校验后才改名**：`.part` → 正式文件名 用 rename（同目录内是原子的），
///   保证"清单里登记的文件"永远是完整且校验过的。
/// * **不静默放行**：没有 sha256 时结果里 `hashVerified=false`，由调用方决定
///   是否拒绝（发布版清单里 `requireHash: true` 就一律拒绝）。
class ModelDownloader {
  ModelDownloader({
    required this.dir,
    HttpClient? client,
    this.connectTimeout = const Duration(seconds: 20),
    this.probeBytes = 512 * 1024,
  })  : _client = client ?? (HttpClient()..autoUncompress = false),
        _ownsClient = client == null;

  /// 落盘目录（通常是 `<DSH_HOME>/models`）。
  final String dir;

  final HttpClient _client;
  final bool _ownsClient;

  /// 连接/首字节超时。手机上切网/弱网很常见，给足 20 秒。
  final Duration connectTimeout;

  /// 测速时每个源取多少字节。
  final int probeBytes;

  void close() {
    if (_ownsClient) _client.close(force: true);
  }

  /// 给所有源并发测速，返回**按速度降序**的列表；连不上的排在最后（仍会尝试）。
  Future<List<ModelSource>> rankSources(
    List<ModelSource> sources, {
    DownloadCancelToken? cancel,
  }) async {
    if (sources.isEmpty) return const <ModelSource>[];
    final results = await Future.wait(sources.map((s) async {
      try {
        final bps = await _probe(s, cancel: cancel);
        return MapEntry(s, bps);
      } catch (e) {
        debugPrint('[dsh-model] 测速失败 ${s.label}: $e');
        return MapEntry(s, -1.0);
      }
    }));
    final ranked = List<MapEntry<ModelSource, double>>.from(results)
      ..sort((a, b) => b.value.compareTo(a.value));
    return ranked.map((e) => e.key).toList(growable: false);
  }

  Future<double> _probe(ModelSource source,
      {DownloadCancelToken? cancel}) async {
    if (cancel?.isCancelled ?? false) throw const _TransportError('cancelled');
    // ⚠️ 计时必须从**发起请求**开始：首字节延迟（TTFB）是真实体验的大头。
    // 曾经把 Stopwatch 放在响应头之后，结果"故意慢 80ms 的源"与"立刻回的源"
    // 测得一样快，选源顺序变成随机的（测试里就是这么抓出来的）。
    final sw = Stopwatch()..start();
    final req =
        await _client.getUrl(Uri.parse(source.url)).timeout(connectTimeout);
    if (probeBytes > 0) {
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${probeBytes - 1}');
    }
    final res = await req.close().timeout(connectTimeout);
    if (res.statusCode != HttpStatus.ok &&
        res.statusCode != HttpStatus.partialContent) {
      await res.drain<void>();
      // 人话在前、状态码在后（审计 P1-2）：这条最终会出现在"所有下载源都没成功，
      // 最后一个是：…"里给用户看，裸 `HTTP 404` 说了等于没说。
      throw _TransportError(
          '${translateHttpError(statusCode: res.statusCode).zh}'
          '（HTTP ${res.statusCode}）');
    }
    var got = 0;
    await for (final chunk in res) {
      got += chunk.length;
      if (got >= probeBytes) break;
      if (cancel?.isCancelled ?? false) break;
    }
    sw.stop();
    if (got <= 0) throw const _TransportError('探测未收到数据');
    final ms = math.max(sw.elapsedMilliseconds, 1);
    return got * 1000 / ms;
  }

  /// 下载**一条模型**（含它的伴生文件 mmproj）：测速选源 → 续传 → 校验 → 落盘。
  ///
  /// 网络类失败会**自动换源**继续（`.part` 保留，能续就续）；
  /// 取消、体积不符、哈希不符属于致命错，直接抛出且不留半个文件。
  ///
  /// [totalOverride] 只影响**进度条的分母**：带伴生文件时，本体阶段的进度也要
  /// 按"两个文件的总量"算，否则进度条会先从 0 冲到 100%（本体下完）再跳回 0%
  /// 重新爬（伴生文件），看起来像卡住或重来。
  Future<ModelDownloadResult> _downloadOne(
    OnDeviceModel entry, {
    DownloadProgressCallback? onProgress,
    DownloadCancelToken? cancel,
    bool requireHash = false,
  }) async {
    final t0 = Stopwatch()..start();
    await Directory(dir).create(recursive: true);
    final target = File('$dir/${entry.fileName}');
    final part = File('${target.path}.part');

    if (entry.sources.isEmpty) {
      throw ModelDownloadException(tr('这个模型在清单里没有任何下载源'));
    }
    if (entry.bytes <= 0) {
      throw ModelDownloadException(tr('清单里缺少 {0} 的文件大小，无法校验', [entry.name]));
    }

    // 取消要在这里就拦下：别在用户已经点了取消之后还去并发探测一堆源。
    if (cancel?.isCancelled ?? false) {
      throw ModelDownloadException(tr('下载已取消'));
    }

    final ranked = await rankSources(entry.sortedSources, cancel: cancel);
    if (ranked.isEmpty) {
      throw ModelDownloadException(tr('没有可用的下载源'));
    }

    Object? lastError;
    for (final source in ranked) {
      if (cancel?.isCancelled ?? false) {
        throw ModelDownloadException(tr('下载已取消'));
      }
      try {
        final usedRange = await _fetchTo(part, entry, source,
            onProgress: onProgress, cancel: cancel);
        final result = await _verifyAndPublish(
          entry: entry,
          part: part,
          target: target,
          source: source,
          resumed: usedRange,
          elapsed: t0.elapsed,
          requireHash: requireHash,
        );
        return result;
      } on _TransportError catch (e) {
        // 取消不是"这个源不行"，直接终止，别傻乎乎换下一个源重下 2 GB。
        if (cancel?.isCancelled ?? false) {
          throw ModelDownloadException(tr('下载已取消'));
        }
        lastError = e;
        debugPrint('[dsh-model] 源「${source.label}」失败，换下一个：$e');
      } on TimeoutException catch (e) {
        lastError = e;
        debugPrint('[dsh-model] 源「${source.label}」超时，换下一个：$e');
      } on IOException catch (e) {
        // IOException 覆盖 SocketException 与 HttpException —— 后者常在
        // `req.close()` 阶段抛出（服务器中途断开），漏接就会跳过换源直接崩。
        lastError = e;
        debugPrint('[dsh-model] 源「${source.label}」网络错误，换下一个：$e');
      }
    }
    throw ModelDownloadException(tr('所有下载源都没成功，最后一个是：{0}', ['$lastError']));
  }

  /// 下载一条模型条目：**本体 + 所有伴生文件（mmproj 视觉编码器）**。
  ///
  /// 为什么伴生文件必须一起下：多模态模型**光有本体不懂图** —— 视觉编码器是独立
  /// 文件，启动时用 `--mmproj` 指着它。只下本体的话，用户下完发现"看不了图"
  /// 还得再回来下第二个文件，那是我们没做好。
  ///
  /// 返回的是**本体**的结果（哈希校验结论以本体为准）；伴生文件同样逐个校验体积。
  /// [requireHash] 来自清单顶层的 `requireHash`（发布版应为 true）。
  ///
  /// ⚠️ 这个参数以前**根本不存在** —— 清单里有 `requireHash`、模型类也解析了它、
  /// 注释还写着「发布版清单里 `requireHash: true` 就一律拒绝」，但下载器
  /// **从来没读过它**（审计 P1-10）。也就是说：把 `requireHash` 打开**什么也不会发生**，
  /// 而"没哈希却放行"是**静默**的 —— 一个看起来在工作、实际没接线的安全开关。
  /// 现在它真的会拦：缺哈希且 requireHash 为真 → 删掉半截文件并拒绝安装。
  Future<ModelDownloadResult> download(
    OnDeviceModel entry, {
    DownloadProgressCallback? onProgress,
    DownloadCancelToken? cancel,
    bool requireHash = false,
  }) async {
    final totalAll = entry.totalBytes;
    var base = 0; // 已完成的前缀字节数（本体 + 前面几个伴生文件）
    ModelDownloadResult? main;
    for (final job in <OnDeviceModel>[
      entry,
      ...entry.companions.map((c) => _companionAsModel(entry, c)),
    ]) {
      final prefix = base;
      final r = await _downloadOne(
        job,
        cancel: cancel,
        requireHash: requireHash,
        onProgress: onProgress == null
            ? null
            : (p) => onProgress(ModelDownloadProgress(
                  received: prefix + p.received,
                  total: totalAll,
                  sourceLabel: p.sourceLabel,
                  bytesPerSecond: p.bytesPerSecond,
                )),
      );
      base += job.bytes;
      main ??= r;
    }
    return main!;
  }

  /// 把伴生文件包装成一条"模型"，好复用同一套探测/续传/校验逻辑。
  ///
  /// 它不会出现在界面上（界面只列清单里的条目），只是内部复用。
  OnDeviceModel _companionAsModel(OnDeviceModel entry, ModelCompanion c) =>
      OnDeviceModel(
        id: '${entry.id}::${c.fileName}',
        family: entry.family,
        name: '${entry.name} · 视觉编码器',
        kind: entry.kind,
        engine: entry.engine,
        format: 'gguf',
        fileName: c.fileName,
        bytes: c.bytes,
        quant: entry.quant,
        license: entry.license,
        minRamGb: entry.minRamGb,
        sources: c.sortedSources,
        sha256: c.sha256,
      );

  /// 把 `source` 的内容写进 `.part`（能续就续）。
  ///
  /// 返回**本次是否真的用了 Range 续传** —— 调用方要用它如实汇报"这次是续传还是重下"，
  /// 不能拿"存在 .part"糊弄（服务器不认 Range 时我们是从头写的）。
  Future<bool> _fetchTo(
    File part,
    OnDeviceModel entry,
    ModelSource source, {
    DownloadProgressCallback? onProgress,
    DownloadCancelToken? cancel,
  }) async {
    var offset = part.existsSync() ? part.lengthSync() : 0;
    // .part 比目标还大 = 上一次被写坏了，直接从头来，别在垃圾后面接着写。
    if (offset > entry.bytes) {
      debugPrint('[dsh-model] .part 比目标大（$offset > ${entry.bytes}），丢弃重下');
      part.deleteSync();
      offset = 0;
    }

    final req =
        await _client.getUrl(Uri.parse(source.url)).timeout(connectTimeout);
    if (offset > 0) {
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    }
    final res = await req.close().timeout(connectTimeout);

    final okFresh = res.statusCode == HttpStatus.ok;
    final okResume = res.statusCode == HttpStatus.partialContent;
    if (!okFresh && !okResume) {
      await res.drain<void>();
      throw _TransportError(
          '${translateHttpError(statusCode: res.statusCode).zh}'
          '（HTTP ${res.statusCode}）');
    }
    // 明确要了续传、服务器却整段返回 → 必须丢掉旧内容，否则拼出来的是坏文件。
    if (offset > 0 && !okResume) {
      debugPrint('[dsh-model] 服务器不支持 Range（HTTP ${res.statusCode}），从头重下');
      offset = 0;
      if (part.existsSync()) part.deleteSync();
    }

    final sink =
        part.openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
    final usedRange = offset > 0 && okResume;
    var received = offset;
    final total =
        res.contentLength > 0 ? received + res.contentLength : entry.bytes;
    final sw = Stopwatch()..start();
    var lastTick = 0;
    // 速率窗口：只保留最近 ~3 秒的采样，算"现在多快"（全程平均会迟钝）。
    const windowMs = 3000;
    var winStartMs = 0;
    var winStartBytes = offset;
    try {
      await for (final chunk in res) {
        if (cancel?.isCancelled ?? false) {
          throw const _TransportError('cancelled');
        }
        sink.add(chunk);
        received += chunk.length;
        final ms = sw.elapsedMilliseconds;
        if (ms - lastTick >= 200) {
          lastTick = ms;
          // 窗口滑动：超过 windowMs 就把起点往前挪。
          if (ms - winStartMs > windowMs) {
            winStartMs = ms;
            winStartBytes = received;
          }
          final span = ms - winStartMs;
          onProgress?.call(ModelDownloadProgress(
            received: received,
            total: total,
            sourceLabel: source.label,
            bytesPerSecond:
                span <= 0 ? 0 : (received - winStartBytes) * 1000 / span,
          ));
        }
      }
    } on SocketException catch (e) {
      throw _TransportError('连接中断：${e.message}');
    } on HttpException catch (e) {
      throw _TransportError('传输错误：${e.message}');
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (cancel?.isCancelled ?? false) {
      throw const _TransportError('cancelled');
    }
    final written = part.existsSync() ? part.lengthSync() : 0;
    if (written != entry.bytes) {
      // 网络层"看起来读完了"但字节数不对：留给下一次续传，别当成成功。
      throw _TransportError('字节数不符（收到 $written，清单是 ${entry.bytes}）');
    }
    onProgress?.call(ModelDownloadProgress(
      received: written,
      total: entry.bytes,
      sourceLabel: source.label,
    ));
    return usedRange;
  }

  Future<ModelDownloadResult> _verifyAndPublish({
    required OnDeviceModel entry,
    required File part,
    required File target,
    required ModelSource source,
    required bool resumed,
    required Duration elapsed,
    required bool requireHash,
  }) async {
    if (!part.existsSync()) {
      throw ModelDownloadException(tr('下载文件不见了：{0}', [part.path]));
    }
    final size = part.lengthSync();
    if (size != entry.bytes) {
      // 致命：清单与实际不符（源站换版本 / 中途截断）。不保留这半截。
      if (part.existsSync()) part.deleteSync();
      throw ModelDownloadException(
          tr('文件大小与清单不符（实际 {0} 字节，清单 {1} 字节）', ['$size', '${entry.bytes}']));
    }

    var hashVerified = false;
    if (entry.hasHash) {
      final actual = await sha256OfFile(part.path);
      if (actual.toLowerCase() != entry.sha256!.toLowerCase()) {
        if (part.existsSync()) part.deleteSync();
        throw ModelDownloadException(tr('文件校验失败（sha256 不匹配），已删除，请重试'));
      }
      hashVerified = true;
    } else if (requireHash) {
      // 清单要求"必须有哈希"却没有 → **拒绝安装**（这正是 requireHash 的语义）。
      // 先把下好的半截删掉：留着它会在下次续传时被当成"已验证过"的来源，
      // 而它恰恰是没被校验过的那一份。
      if (part.existsSync()) part.deleteSync();
      throw ModelDownloadException(tr(
          '这条模型的清单里没有 sha256，而清单要求必须校验哈希，已拒绝安装：{0}',
          [entry.id]));
    } else {
      debugPrint('[dsh-model] ⚠️ ${entry.id} 清单里没有 sha256，只做了体积校验');
    }

    if (target.existsSync()) target.deleteSync();
    await part.rename(target.path);
    debugPrint('[dsh-model] ✅ ${entry.fileName} → ${target.path}'
        '（${hashVerified ? 'sha256 已校验' : '仅体积校验'}）');
    return ModelDownloadResult(
      path: target.path,
      bytes: size,
      sourceLabel: source.label,
      hashVerified: hashVerified,
      resumed: resumed,
      elapsed: elapsed,
    );
  }

  /// 流式计算文件的 sha256。
  ///
  /// 实现搬到了 `data/file_hash.dart`（知识库下载也要用同一处 —— 审计点名
  /// "同一件事多处实现"的危害，且 P0-4 要求知识库也校验 sha256）。
  /// 这里保留这个静态入口，是为了不改动既有调用点与测试。
  static Future<String> sha256OfFile(String path) async {
    try {
      return await file_hash.sha256OfFile(path);
    } on file_hash.FileHashException catch (e) {
      throw ModelDownloadException(e.message);
    }
  }
}
