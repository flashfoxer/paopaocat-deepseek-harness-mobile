import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// 把**本机的一个视频/音频文件**通过 `http://127.0.0.1:<临时端口>/` 交给 App 内的
/// WebView 播放。
///
/// ## 为什么不直接 `file://`（这是本文件存在的唯一理由）
///
/// 资料库的 HTML 预览走的是 `WebViewController.loadFile`（`file://` 同源），
/// 那条路对**文本/图片**没问题；但 `<video>` / `<audio>` 从 `file://` 里取媒体
/// 在 Android WebView 上是**版本相关**的行为（历史上被 `setAllowFileAccessFromFileURLs`
/// 之类的开关反复改过），而本机**没有真机可验**。
///
/// 换成"本机 HTTP 服务"之后，媒体就是一个**普通 http 资源**：
///   * 来源稳定（不需要任何 file 访问开关）；
///   * 能支持 **Range** —— 这是拖进度条、边下边播的前提，也是"能不能看"的分水岭；
///   * 而且**可以被单测完整覆盖**（真起一个 server 发请求，见
///     `test/media_preview_server_test.dart`），不必等真机。
///
/// 明文 HTTP 是允许的：`android/app/src/main/res/xml/network_security_config.xml`
/// 的 `base-config` 开着 `cleartextTrafficPermitted`，并且显式列了 `127.0.0.1`。
///
/// ## 边界（写在代码里，免得下一个人以为它能干更多）
///
///   * **只服务一个文件**：路径完全由构造时决定，`/media` 之外的任何路径都 404 ——
///     所以不存在"目录穿越"这回事（我们根本不解析用户传来的路径）。
///   * **只绑 127.0.0.1**：局域网里别的机器访问不到。
///   * **不解码、不转码**：它只是把字节按 Range 发出去。能不能放，取决于
///     WebView/系统解码器认不认这个容器 —— 认不出时要**如实告诉用户**
///     （走 `/` 页面里的 JS 回调，见 [previewHtml]）。
class MediaPreviewServer {
  MediaPreviewServer._(this._server, this._file, this._audio)
      : _port = _server.port;

  final HttpServer _server;
  final File _file;
  final bool _audio;

  /// ⚠️ **端口在构造时就缓存下来**（不要事后读 `_server.port`）：
  /// 服务一旦关闭，`_server.port` 会**抛** `HttpException: HttpServer is not bound
  /// to a socket` —— 连把它写进一句日志都会再抛一次（我第一版就是这么踩的：
  /// `stop()` 里那句 "已关闭（端口 $port）" 自己抛了异常，被外层 catch 吞成
  /// 一条听着像"关闭失败"的假日志）。
  final int _port;

  /// 给 WebView 用的入口地址（加载这个 URL 就会看到播放器）。
  ///
  /// ⚠️ 它以 `/` 结尾（是"入口"而不是"基址"）：拼子路径请用 [port] 自己拼，
  /// 直接接 `/media` 会得到 `//media`（服务端按未知路径回 404）。
  String get url => 'http://127.0.0.1:$_port/';

  int get port => _port;

  /// 起一个只服务 [file] 的本地服务。失败时抛异常（调用方如实显示原因）。
  static Future<MediaPreviewServer> start(
    File file, {
    bool audio = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = MediaPreviewServer._(server, file, audio);
    // 不 await：`listen` 会一直挂着直到 server 关闭。
    unawaited(s._serve());
    debugPrint('[dsh-preview] 已起播放服务：${s.url} → ${file.path}');
    return s;
  }

  Future<void> _serve() async {
    await for (final req in _server) {
      try {
        await _handle(req);
      } catch (e) {
        // 单个请求出错不能把整个服务带走（否则用户看到的是"突然放不了了"）。
        debugPrint('[dsh-preview] 处理请求失败：$e');
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          await req.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final res = req.response;

    if (path == '/' || path == '/index.html') {
      final html = previewHtml(audio: _audio);
      res
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..headers.set('cache-control', 'no-store');
      res.write(html);
      await res.close();
      return;
    }

    if (path != '/media') {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }

    if (req.method != 'GET' && req.method != 'HEAD') {
      res.statusCode = HttpStatus.methodNotAllowed;
      await res.close();
      return;
    }

    final total = await _file.length();
    res.headers.set('accept-ranges', 'bytes');
    res.headers.contentType = contentTypeFor(_file.path);

    // HEAD：只回头，不发正文（有些播放器/探测会先发 HEAD）。
    if (req.method == 'HEAD') {
      res
        ..statusCode = HttpStatus.ok
        ..headers.contentLength = total;
      await res.close();
      return;
    }

    final range = parseRangeHeader(req.headers.value('range'), total);

    if (range == null) {
      // 没有 Range（或不认识的 Range 写法）→ 整份发。
      res
        ..statusCode = HttpStatus.ok
        ..headers.contentLength = total;
      await _pipe(res, 0, total - 1);
      return;
    }

    if (range == MediaRange.unsatisfiable) {
      // 要求越界：**必须**回 416 并带 Content-Range，播放器据此纠正。
      res
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set('content-range', 'bytes */$total');
      await res.close();
      return;
    }

    final len = range.end - range.start + 1;
    res
      ..statusCode = HttpStatus.partialContent
      ..headers.set('content-range', 'bytes ${range.start}-${range.end}/$total')
      ..headers.contentLength = len;
    await _pipe(res, range.start, range.end);
  }

  /// 把 [start]..[end]（闭区间）写进响应。用流式读，避免把大视频读进内存。
  Future<void> _pipe(HttpResponse res, int start, int end) async {
    if (end < start) {
      await res.close();
      return;
    }
    final raf = await _file.open();
    try {
      await raf.setPosition(start);
      var remain = end - start + 1;
      const chunk = 64 * 1024;
      while (remain > 0) {
        final want = remain < chunk ? remain : chunk;
        final bytes = await raf.read(want);
        if (bytes.isEmpty) break; // 文件被截短了：发到这儿为止
        res.add(bytes);
        remain -= bytes.length;
      }
    } finally {
      await raf.close();
    }
    await res.close();
  }

  /// 关掉服务。页面销毁时必须调用 —— 否则端口和连接会一直留着。
  ///
  /// **幂等**：重复调用既不抛、也不再打一条"关闭失败"（那种日志会让人以为真出错了，
  /// 其实只是"已经关过了"）。
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      await _server.close(force: true);
      debugPrint('[dsh-preview] 播放服务已关闭（端口 $port）');
    } catch (e) {
      // ⚠️「HttpServer is not bound to a socket」= 它**已经**不在监听上了 ——
      //    那正是我们要的结果（实测：在测试环境里 close 会回这个），
      //    所以不能把它报成"失败"，否则日志里会留下一条查不出问题的假错误。
      // 现在端口是缓存值，这里读它不会再抛；`force: true` 之后出现
      // "not bound" 只说明**它本来就不在监听** —— 那正是我们要的结果。
      final msg = '$e';
      debugPrint(msg.contains('not bound')
          ? '[dsh-preview] 播放服务已关闭（端口 $port，本来就不在监听）'
          : '[dsh-preview] 关闭播放服务失败：$e');
    }
  }

  bool _stopped = false;
}

/// 一个已解析的 Range（闭区间，`end` 已按文件长度夹好）。
///
/// 公开（不是下划线）是因为 [parseRangeHeader] 是公开的、且它要能被单测直接调用 ——
/// Range 解析错了的表现是"一拖进度条就黑屏"，那种 bug 只有真机放视频时才看得见。
class MediaRange {
  const MediaRange(this.start, this.end);

  final int start;
  final int end;

  /// 越界（要求 `bytes=999999-` 而文件只有 100 字节）：
  /// 按 HTTP 规范回 416，而不是假装能服务。
  static const MediaRange unsatisfiable = MediaRange(-1, -1);
}

/// 解析 `Range: bytes=...` 头。
///
/// 支持三种真实存在的写法（**都是播放器会发的**）：
///   * `bytes=0-`      从 0 到结尾；
///   * `bytes=100-199` 闭区间；
///   * `bytes=-500`    最后 500 字节（后缀范围）。
///
/// 返回 null = 没有这个头 / 写法不认识（**按整份发**，这是规范允许的兜底）；
/// 返回 [MediaRange.unsatisfiable] = 明确越界（回 416）。
///
/// 公开是为了能被单测直接钉住 —— Range 解析错了，表现是"拖进度条就黑屏"，
/// 那种 bug 只在真机上放视频时才看得见。
MediaRange? parseRangeHeader(String? header, int total) {
  if (header == null || header.trim().isEmpty) return null;
  final h = header.trim();
  if (!h.startsWith('bytes=')) return null;
  final spec = h.substring('bytes='.length).trim();
  // 多段 Range（`bytes=0-9,20-29`）我们不做多段响应：按整份发即可（规范允许）。
  if (spec.contains(',')) return null;
  final dash = spec.indexOf('-');
  if (dash < 0) return null;

  final startStr = spec.substring(0, dash).trim();
  final endStr = spec.substring(dash + 1).trim();

  if (startStr.isEmpty) {
    // 后缀写法：bytes=-N（最后 N 字节）
    final n = int.tryParse(endStr);
    if (n == null || n <= 0) return null;
    if (total == 0) return MediaRange.unsatisfiable;
    final start = n >= total ? 0 : total - n;
    return MediaRange(start, total - 1);
  }

  final start = int.tryParse(startStr);
  if (start == null || start < 0) return null;
  if (total == 0 || start >= total) return MediaRange.unsatisfiable;

  if (endStr.isEmpty) return MediaRange(start, total - 1);
  final end = int.tryParse(endStr);
  if (end == null) return null;
  // 尾部超界要**夹到文件末尾**（播放器常发比文件大的 end）。
  return MediaRange(start, end >= total ? total - 1 : (end < start ? start : end));
}

/// 按扩展名给 Content-Type。
///
/// 认不出的类型回 `application/octet-stream` —— **不猜**：
/// 猜错（比如把 .mkv 说成 video/mp4）会让 WebView 拿到解码失败的媒体，
/// 报出来的错跟真实原因对不上。
ContentType contentTypeFor(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'mp4' || 'm4v' => ContentType('video', 'mp4'),
    'mov' => ContentType('video', 'quicktime'),
    'webm' => ContentType('video', 'webm'),
    'mkv' => ContentType('video', 'x-matroska'),
    'ogv' => ContentType('video', 'ogg'),
    '3gp' => ContentType('video', '3gpp'),
    'mp3' => ContentType('audio', 'mpeg'),
    'wav' => ContentType('audio', 'wav'),
    'm4a' || 'aac' => ContentType('audio', 'mp4'),
    'ogg' || 'opus' => ContentType('audio', 'ogg'),
    'flac' => ContentType('audio', 'flac'),
    'amr' => ContentType('audio', 'amr'),
    _ => ContentType('application', 'octet-stream'),
  };
}

/// 播放页的 HTML。
///
/// ⚠️ **它只有一个职责**：把 `/media` 放出来，并把「能不能放得动」如实回报给 App。
/// 回报走 JS 通道 `DshPreview`：
///   * `ok:<时长秒>` —— 元数据读到了，说明这个容器 WebView 认；
///   * `error:<MediaError.code>` —— 放不出来（容器/编码不被支持）。
/// App 侧据此决定是"正常播放"还是"如实说放不了 + 给外部打开入口"。
///
/// 颜色/边距都是**黑色满屏**：视频预览里除了画面本身，别的东西都是干扰。
String previewHtml({required bool audio}) {
  final tag = audio ? 'audio' : 'video';
  return '''
<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>预览</title>
<style>
  html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden}
  body{display:flex;align-items:center;justify-content:center}
  video{width:100%;height:100%;object-fit:contain;background:#000}
  audio{width:92%}
</style>
</head>
<body>
<$tag id="m" controls autoplay playsinline preload="metadata" src="/media"></$tag>
<script>
  var el = document.getElementById('m');
  function tell(msg){ try { DshPreview.postMessage(msg); } catch (e) {} }
  el.addEventListener('loadedmetadata', function(){
    var d = isFinite(el.duration) ? Math.round(el.duration) : -1;
    tell('ok:' + d);
  });
  el.addEventListener('error', function(){
    var code = (el.error && el.error.code) ? el.error.code : 0;
    tell('error:' + code);
  });
  el.addEventListener('stalled', function(){ tell('stalled'); });
</script>
</body>
</html>
''';
}
