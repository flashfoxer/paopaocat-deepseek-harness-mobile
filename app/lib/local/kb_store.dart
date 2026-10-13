/// 知识库的落盘与下载。
///
/// ## 目录约定
///
/// ```
/// <DSH_HOME>/kb/<packId>/meta.json      ← 这一包的登记信息（名字/体积/来源/许可）
/// <DSH_HOME>/kb/<packId>/<fileName>     ← 资料本体
/// ```
///
/// 与模型那边（`<DSH_HOME>/models/`）分开放：资料和模型是两类东西，
/// 混在一起以后统计体积、清理、迁移都会互相牵连。
///
/// ## 下载纪律（照抄模型下载器那套，已验证过）
///
/// `.part` 先写 → 下完确认体积 → 原子改名 → 写 meta.json。
/// 断网/关 App 后 `.part` 留着，下次用 HTTP Range **接着下**，不用从零重来。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'kb_manifest.dart';
import '../data/atomic_file.dart';
import '../data/file_hash.dart';
import '../data/api_error_text.dart';

/// 已装好的一包资料。
class KbInstalled {
  const KbInstalled({
    required this.id,
    required this.name,
    required this.fileName,
    required this.path,
    required this.bytes,
    required this.entries,
    required this.license,
    required this.source,
    this.at,
    this.sha256 = '',
    this.enabled = true,
  });

  final String id;
  final String name;
  final String fileName;
  final String path;
  final int bytes;

  /// 条目数。0 = 未知（导入的文件还没统计，等建索引时一起算）。
  final int entries;
  final String license;

  /// `bundled`（随包样例）/ `download`（下载）/ `import`（从手机导入）。
  final String source;
  final DateTime? at;

  /// 文件 sha256（导入时原生会免费给我们；下载/随包一般没有）。
  ///
  /// 用途只有一个但很重要：**同一个文件导两次不要变成两包** —— 两包会让检索多占
  /// 名额、也让用户以为"导入了两份不同的东西"。
  final String sha256;

  /// 是否**参与「本地对话」的检索**（用户可关）。
  ///
  /// 为什么要有：装了两包以上时，用户可能只想让其中某一本参与问答
  /// （比如"这本手册我想用、那本旧资料别掺和"）。
  final bool enabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'fileName': fileName,
        'bytes': bytes,
        'entries': entries,
        'license': license,
        'source': source,
        'at': at?.toIso8601String(),
        if (sha256.trim().isNotEmpty) 'sha256': sha256,
        'enabled': enabled,
      };

  static KbInstalled? fromJson(Object? raw, String dirOfPack) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final fileName = raw['fileName'];
    if (id is! String || fileName is! String) return null;
    return KbInstalled(
      id: id,
      name: (raw['name'] as String?) ?? id,
      fileName: fileName,
      path: '$dirOfPack/$fileName',
      bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
      entries: (raw['entries'] as num?)?.toInt() ?? 0,
      license: (raw['license'] as String?) ?? '',
      source: (raw['source'] as String?) ?? 'import',
      at: DateTime.tryParse((raw['at'] as String?) ?? ''),
      sha256: (raw['sha256'] as String?) ?? '',
      // 老 meta 没这个字段 → 默认参与（不能因为升级就把人家已有的包停掉）。
      enabled: raw['enabled'] != false,
    );
  }
}

/// 下载进度（给界面用）。
class KbDownloadProgress {
  const KbDownloadProgress({
    required this.received,
    required this.total,
    required this.bytesPerSecond,
    required this.sourceLabel,
  });

  final int received;
  final int total;
  final double bytesPerSecond;
  final String sourceLabel;

  double get ratio => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);
}

/// 取消令牌。
class KbCancelToken {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class KbDownloadException implements Exception {
  KbDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// **校验失败**（体积对不上 / sha256 不匹配）—— 与"传输失败"必须分开。
///
/// ## 为什么要单独一个类型（2026-10-11 修的真 bug）
///
/// 换源时 `.part` 默认**保留**，下一个源用 `Range: bytes=<已有>-` 续传。
/// * 传输中断留下的 `.part` 是**正确的前缀** → 续传没问题，不该白下几百 MB；
/// * **校验失败**说明这份前缀本身就是错的（上游换了文件、或落盘写坏了）→
///   坏前缀 + 新源的好后缀**永远校验不过**，表现是"这个包怎么都装不上"，
///   而且界面上只会重复显示同一条校验错误（最坏的那种坏：永远失败、看不出原因）。
///
/// 所以校验失败必须让调用方**删掉 `.part`**，下一个源从头下。
class KbVerifyException extends KbDownloadException {
  KbVerifyException(super.message);
}

/// 知识库的存储层。
class KbStore {
  KbStore({required this.dshHome});

  /// DSH_HOME（`.../files/dshhome`）。
  final String dshHome;

  /// 知识库根目录。
  String get dir => dshHome.isEmpty ? 'kb' : '$dshHome/kb';

  String dirOf(String id) => '$dir/$id';

  String metaPathOf(String id) => '${dirOf(id)}/meta.json';

  /// 已装的知识库（扫 `kb/` 下的子目录，逐个读 meta.json）。
  ///
  /// 读不出来就跳过 —— 一个坏 meta 不该让整页空掉。
  Future<List<KbInstalled>> list() async {
    final out = <KbInstalled>[];
    try {
      final root = Directory(dir);
      if (!root.existsSync()) return out;
      for (final e in root.listSync()) {
        if (e is! Directory) continue;
        final id = e.path.split(Platform.pathSeparator).last;
        final meta = File(metaPathOf(id));
        if (!meta.existsSync()) continue;
        try {
          final parsed = KbInstalled.fromJson(
              jsonDecode(await meta.readAsString()), dirOf(id));
          if (parsed == null) continue;
          // meta 写了、文件却不在（用户手动删了）→ 不列出来，免得点了报错。
          if (!File(parsed.path).existsSync()) continue;
          out.add(parsed);
        } catch (_) {
          continue;
        }
      }
    } catch (_) {
      return out;
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  bool isInstalled(List<KbInstalled> installed, String id) =>
      installed.any((k) => k.id == id);

  /// 找一份**内容完全相同**的已有资料（按 sha256）。空 sha 一律不算命中
  /// （下载/随包的 meta 没有 sha，不能拿"空"去互相匹配）。
  KbInstalled? findBySha(List<KbInstalled> installed, String sha) {
    final want = sha.trim().toLowerCase();
    if (want.isEmpty) return null;
    for (final k in installed) {
      if (k.sha256.trim().toLowerCase() == want) return k;
    }
    return null;
  }

  /// 改"是否参与检索"（只动 meta，不动资料文件）。
  Future<void> setEnabled(KbInstalled kb, bool enabled) async {
    final updated = KbInstalled(
      id: kb.id,
      name: kb.name,
      fileName: kb.fileName,
      path: kb.path,
      bytes: kb.bytes,
      entries: kb.entries,
      license: kb.license,
      source: kb.source,
      at: kb.at,
      sha256: kb.sha256,
      enabled: enabled,
    );
    await writeStringAtomic(File(metaPathOf(kb.id)), jsonEncode(updated.toJson()));
  }

  /// 登记一包（写 meta.json）。文件本体必须已经在 [dirOf] 里。
  Future<KbInstalled> register({
    required String id,
    required String name,
    required String fileName,
    required int bytes,
    required int entries,
    required String license,
    required String source,
    String sha256 = '',
    bool enabled = true,
  }) async {
    final d = Directory(dirOf(id));
    if (!d.existsSync()) await d.create(recursive: true);
    final out = KbInstalled(
      id: id,
      name: name,
      fileName: fileName,
      path: '${d.path}/$fileName',
      bytes: bytes,
      entries: entries,
      license: license,
      source: source,
      at: DateTime.now(),
      sha256: sha256,
      enabled: enabled,
    );
    await writeStringAtomic(File(metaPathOf(id)), jsonEncode(out.toJson()));
    return out;
  }

  /// 删除一包（整目录删掉，含 `.part`）。
  Future<void> delete(String id) async {
    final d = Directory(dirOf(id));
    if (d.existsSync()) await d.delete(recursive: true);
  }

  /// 把随包样例（assets）写进知识库。
  ///
  /// [read] 由界面传进来（`rootBundle.load` 的字节），这里不依赖 Flutter 上下文，
  /// 便于单测。
  Future<KbInstalled> installBundled(KbPack pack,
      {required Future<List<int>> Function() read}) async {
    final d = Directory(dirOf(pack.id));
    if (!d.existsSync()) await d.create(recursive: true);
    final bytes = await read();
    final f = File('${d.path}/${pack.fileName}');
    await f.writeAsBytes(bytes, flush: true);
    return register(
      id: pack.id,
      name: pack.name,
      fileName: pack.fileName,
      bytes: bytes.length,
      entries: pack.entries,
      license: pack.license,
      source: 'bundled',
    );
  }
}

/// 知识库下载器：多源 + 断点续传 + 进度。
class KbDownloader {
  KbDownloader({required KbStore store, this.connectTimeout = const Duration(seconds: 20)})
      : _store = store;

  final KbStore _store;
  final Duration connectTimeout;

  /// 下载一包。
  ///
  /// 逐个源试；带 `.part` 时用 Range 续传。**任何一条源失败都不会删 `.part`** ——
  /// 换下一个源接着下，这正是不用从头再来的原因。
  Future<KbInstalled> download(
    KbPack pack, {
    required void Function(KbDownloadProgress) onProgress,
    KbCancelToken? cancel,
  }) async {
    if (pack.sortedSources.isEmpty) {
      throw KbDownloadException('这个知识库没有任何下载源');
    }
    final d = Directory(_store.dirOf(pack.id));
    if (!d.existsSync()) await d.create(recursive: true);
    final target = File('${d.path}/${pack.fileName}');
    final part = File('${target.path}.part');

    Object? lastError;
    for (final source in pack.sortedSources) {
      if (cancel?.cancelled == true) throw KbDownloadException('已取消');
      try {
        await _fetch(source, part, pack, onProgress, cancel);
        // 体积核对：清单写了字节数就必须一致（没写就只当作“下完了”）。
        final got = await part.length();
        if (pack.bytes > 0 && got != pack.bytes) {
          throw KbVerifyException(
              '体积不符：清单 ${pack.bytes} 字节，实际 $got 字节');
        }
        // sha256 核对（审计 P0-4）：**同长度的损坏/篡改只有它能发现**。
        // 体积对得上不代表内容对得上 —— 上游换了文件、或落盘写坏了同样多的
        // 字节，体积校验一律放行。
        //
        // 放在 rename **之前**：不合格就不该让这个文件名出现在目录里，
        // 否则"登记过 = 已校验"这个前提就是假的。失败同样只抛错 →
        // 外层换下一个源（别的源可能就是对的那份）。
        if (pack.sha256.isNotEmpty) {
          final actual = (await sha256OfFile(part.path)).toLowerCase();
          if (actual != pack.sha256) {
            throw KbVerifyException(
                '校验失败（sha256 不匹配）：清单 ${pack.sha256}，实际 $actual');
          }
        }
        if (target.existsSync()) await target.delete();
        await part.rename(target.path);
        return await _store.register(
          id: pack.id,
          name: pack.name,
          fileName: pack.fileName,
          bytes: got,
          entries: pack.entries,
          license: pack.license,
          source: 'download',
        );
      } catch (e) {
        lastError = e;
        // 换下一个源。`.part` 默认**保留**（传输中断时它是正确的前缀，下次 Range
        // 接着下，不用白下几百 MB）—— 但**校验失败**例外：那份前缀本身是错的，
        // 留给下一个源续传只会"坏前缀 + 好后缀"，永远校验不过。见 [KbVerifyException]。
        if (e is KbVerifyException) {
          try {
            if (part.existsSync()) await part.delete();
          } catch (_) {
            // 删不掉也不能掩盖原始错误 —— 下面照样换源重试。
          }
        }
      }
    }
    throw KbDownloadException('所有源都没成功：$lastError');
  }

  Future<void> _fetch(
    KbSource source,
    File part,
    KbPack pack,
    void Function(KbDownloadProgress) onProgress,
    KbCancelToken? cancel,
  ) async {
    var already = 0;
    try {
      if (part.existsSync()) already = await part.length();
    } catch (_) {
      already = 0;
    }
    // 已经下满就直接返回（上次只是没来得及改名）。
    if (pack.bytes > 0 && already >= pack.bytes) {
      // ⚠️ `already > pack.bytes` 说明这份 `.part` **比目标还长**（上一次下坏、
      // 或清单改小了）。旧写法直接 return，然后体积核对必然抛错、`.part` 又被保留
      // → 换源时 `already` 还是那么大 → 再 return → **永远卡在这一步**。
      // 比目标长只可能是坏的，丢掉重下（返回后由调用方按正常流程再下）。
      if (already > pack.bytes) {
        try {
          await part.delete();
        } catch (_) {}
        already = 0;
      } else {
        return;
      }
    }

    final client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      final req = await client.getUrl(Uri.parse(source.url));
      if (already > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$already-');
      final res = await req.close().timeout(connectTimeout);
      final ok = res.statusCode == 200 || res.statusCode == 206;
      if (!ok) {
        await res.drain<void>();
        // 人话在前（审计 P1-2）：用户看到"HTTP 404"不知道该干什么。
        throw KbDownloadException(
            '${translateHttpError(statusCode: res.statusCode).zh}'
            '（HTTP ${res.statusCode}，${source.label}）');
      }
      // 服务器不支持续传时会回 200（整份重来）→ 已收的字节要作废，否则文件会坏。
      final append = already > 0 && res.statusCode == 206;
      final total = append
          ? already + (res.contentLength > 0 ? res.contentLength : 0)
          : (res.contentLength > 0 ? res.contentLength : pack.bytes);
      final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
      var received = append ? already : 0;
      final sw = Stopwatch()..start();
      var lastTick = 0;
      try {
        await for (final chunk in res) {
          if (cancel?.cancelled == true) {
            throw KbDownloadException('已取消');
          }
          sink.add(chunk);
          received += chunk.length;
          final ms = sw.elapsedMilliseconds;
          if (ms - lastTick >= 300) {
            lastTick = ms;
            onProgress(KbDownloadProgress(
              received: received,
              total: total,
              bytesPerSecond: ms <= 0 ? 0 : received * 1000 / ms,
              sourceLabel: source.label,
            ));
          }
        }
        await sink.flush();
        onProgress(KbDownloadProgress(
          received: received,
          total: total,
          bytesPerSecond:
              sw.elapsedMilliseconds <= 0 ? 0 : received * 1000 / sw.elapsedMilliseconds,
          sourceLabel: source.label,
        ));
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }
}
