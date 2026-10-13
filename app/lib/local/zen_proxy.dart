import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'android_toolbox.dart';
import 'dsh_runtime.dart';
import 'diagnostics_log.dart';

/// 「社区免费通道」的本地代理 —— 把 DSH 的请求转发到 OpenCode Zen 的匿名免费通道。
///
/// ## ⚠️ 这是什么（不要在界面/文档里含糊过去）
///
/// 上游的免费层**只给自家 CLI 用**（非官方会话形状会被 403 拒掉），这个代理做的是
/// **把请求伪装成官方 CLI 的形状**去通过那道门禁。所以它是：
///   * **默认关闭**、必须用户**在设置里显式打开**的灰色能力；
///   * **不需要任何 Key** —— 上游那条通道本来就是匿名的，凭据是公开的字面量
///     `public`，由本代理自己带上（调用方给的那个占位 Authorization 会被覆盖）；
///   * **不做** IP 轮换、不做重试轰炸（那是真正的滥用放大器，本项目不实现）；
///   * **随时可能失效** —— 上游历史上已经收紧过两次，界面必须如实标注。
///
/// 实现照 `RotationProxy` 那一套（同一个理由：脚本在 toolbox 里，端口由系统挑、
/// 从就绪行回填）：`assets/toolbox/zen-proxy.mjs`。
class ZenProxy {
  ZenProxy._();

  /// 全局单例：同一时刻只该有一个代理。
  static final ZenProxy instance = ZenProxy._();

  Process? _proc;
  int? _port;

  int? get port => _port;
  bool get running => _proc != null && _port != null;

  /// 确保代理在跑，返回它**真正监听的端口**（系统挑的，不能自己猜）。
  ///
  /// 返回 null 表示起不来 —— 调用方要如实处理：**不要**把 overlay 指向一个
  /// 不存在的本地服务（那会让"打开开关"变成"所有模型都连不上"）。
  Future<int?> ensureRunning({required DshRuntime runtime}) async {
    if (running) return _port;

    await AndroidToolbox.ensureInstalled(runtime.filesDir);
    final script = '${runtime.toolboxDir}/zen-proxy.mjs';
    if (!File(script).existsSync()) {
      debugPrint('[dsh-zen] 代理脚本不存在：$script');
      DiagnosticsLog.add('[dsh-zen]', '代理脚本不存在，无法启动');
      return null;
    }

    final stateDir = '${runtime.filesDir}/zen';
    try {
      Directory(stateDir).createSync(recursive: true);
    } catch (_) {}

    Process? proc;
    try {
      proc = await runtime.spawn(<String>[
        script,
        '--port', '0',
        '--state', stateDir,
        // 缓存几小时就够：模型上下架不频繁，而且失败时还有静态兜底名单。
        '--ttl-hours', '12',
      ]);
    } catch (e) {
      debugPrint('[dsh-zen] 起代理失败：$e');
      DiagnosticsLog.add('[dsh-zen]', '起代理失败：$e');
      return null;
    }

    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    final ready = Completer<int>();
    final outTee = DiagnosticsLineTee('dsh-zen:out');
    final errTee = DiagnosticsLineTee('dsh-zen:err');

    proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
      outBuf.write(chunk);
      outTee.feed(chunk);
      if (!ready.isCompleted) {
        // ⚠️ 格式由 zen-proxy.mjs 约定：`listening on http://127.0.0.1:<port>`
        final m = RegExp(r'listening on http://127\.0\.0\.1:(\d+)')
            .firstMatch(outBuf.toString());
        if (m != null) ready.complete(int.parse(m.group(1)!));
      }
    }, onError: (_) {});
    proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
      errBuf.write(chunk);
      errTee.feed(chunk);
    }, onError: (_) {});
    unawaited(proc.exitCode.then((code) {
      if (!ready.isCompleted) {
        ready.completeError(StateError(
            '代理提前退出（code=$code）。stdout=$outBuf stderr=$errBuf'));
      }
      _proc = null;
      _port = null;
    }));

    try {
      final port = await ready.future.timeout(const Duration(seconds: 15));
      _proc = proc;
      _port = port;
      DiagnosticsLog.add('[dsh-zen]', '代理已就绪：127.0.0.1:$port');
      return port;
    } catch (e) {
      debugPrint('[dsh-zen] 代理没起来：$e');
      DiagnosticsLog.add('[dsh-zen]', '代理没起来：$e');
      try {
        proc.kill();
      } catch (_) {}
      _proc = null;
      _port = null;
      return null;
    }
  }

  Future<void> stop() async {
    final p = _proc;
    _proc = null;
    _port = null;
    if (p == null) return;
    try {
      p.kill();
    } catch (_) {}
  }

  /// 取免费模型列表（代理会只列免费的）。
  ///
  /// 失败返回空列表并打日志 —— **绝不编造模型名**（编了等于给用户一个选了就报错的模型）。
  Future<List<String>> fetchFreeModels(int port) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/v1/models'))
          .timeout(const Duration(seconds: 10));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('[dsh-zen] 取模型列表 HTTP ${resp.statusCode}');
        return const <String>[];
      }
      final json = jsonDecode(body);
      final data = (json is Map) ? json['data'] : null;
      if (data is! List) return const <String>[];
      return <String>[
        for (final m in data)
          if (m is Map && m['id'] is String) m['id'] as String,
      ];
    } catch (e) {
      debugPrint('[dsh-zen] 取模型列表失败：$e');
      return const <String>[];
    } finally {
      client.close(force: true);
    }
  }

  /// 健康检查（界面用来显示"通道现在通不通、上次什么错"）。
  Future<({bool ok, int models, String? lastError})?> health(int port) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/healthz'))
          .timeout(const Duration(seconds: 8));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(body);
      if (json is! Map) return null;
      return (
        ok: json['ok'] == true,
        models: (json['models'] is int) ? json['models'] as int : 0,
        lastError: json['lastError'] is String ? json['lastError'] as String : null,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
