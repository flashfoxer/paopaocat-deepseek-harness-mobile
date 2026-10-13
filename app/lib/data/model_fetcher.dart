/// 拉取某个服务商的模型列表（OpenAI 兼容的 `GET /models`）。
///
/// 实测（2026-10-03）：
///   * `https://api.commandcode.ai/provider/v1/models` → 200，返回
///     `{"object":"list","data":[{"id":...,"name":...,"context_length":...,
///      "supported_endpoints":[...]}]}`
///   * `https://api.longcat.chat/openai/v1/models`   → 401（要 Key）
///   * `https://api.xiaomimimo.com/v1/models`        → 401（要 Key）
/// 所以「获取模型」**必须有 Key**，这一点要在界面上说清楚。
///
/// 用 `dart:io` 的 HttpClient 而不是引第三方包：只为一次 GET 给 APK 加依赖不值。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'api_error_text.dart';
import 'model_providers.dart';

import '../i18n/dsh_i18n.dart';

/// 从服务商拉回来的一个模型。
class FetchedModel {
  const FetchedModel({
    required this.id,
    this.displayName,
    this.contextLength,
    this.supportedEndpoints = const <String>[],
  });

  final String id;
  final String? displayName;
  final int? contextLength;
  final List<String> supportedEndpoints;

  String get label => (displayName != null && displayName!.trim().isNotEmpty)
      ? displayName!.trim()
      : id;

  /// 本 App 的 overlay 用 `api: openai-completions`。像 Claude 那样只声明了
  /// `/messages` 的模型选上去必然调不通，所以要能在界面上标出来。
  /// 服务商没给 `supported_endpoints` 时按"未知"处理（视为可能可用）。
  bool get openAiCompatible {
    if (supportedEndpoints.isEmpty) return true;
    return supportedEndpoints.any((e) => e.contains('chat/completions'));
  }
}

/// 拉取结果：成功给列表，失败给**中文**错误。
class ModelListResult {
  const ModelListResult({
    required this.ok,
    this.models = const <FetchedModel>[],
    this.error,
    this.rawCount = 0,
  });

  final bool ok;
  final List<FetchedModel> models;

  /// 失败原因（已翻译成中文）
  final ApiErrorText? error;

  /// 服务端实际返回的条目数（用于"解析出 0 个"这种异常）
  final int rawCount;
}

/// 拉取模型列表。
///
/// [apiKey] 为空时**不发请求**，直接返回中文提示 —— 免得用户看到一个
/// 莫名其妙的 401 还不知道是因为自己没填 Key。
Future<ModelListResult> fetchModelList({
  required ModelProvider provider,
  required String apiKey,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final key = apiKey.trim();
  if (key.isEmpty) {
    return ModelListResult(
      ok: false,
      error: ApiErrorText(
        zh: tr(
            '获取模型列表需要 API Key：请先填写 {0} 的 Key 再点获取。（实测这四家的 /models 都要求鉴权，不带 Key 一律返回 401。）',
            [provider.name]),
        detail: 'no api key supplied; endpoint=${provider.modelsUri}',
      ),
    );
  }

  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(provider.modelsUri).timeout(timeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.userAgentHeader, 'paopaocat-dsh-mobile');

    final response = await request.close().timeout(timeout);
    final bytes = await response.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    final body = utf8.decode(bytes, allowMalformed: true);

    if (response.statusCode != 200) {
      final error =
          translateHttpError(statusCode: response.statusCode, body: body);
      debugPrint(
          '[dsh-models] list failed: ${error.headline} url=${provider.modelsUri}');
      return ModelListResult(ok: false, error: error);
    }

    final parsed = _parseModelList(body);
    debugPrint(
      '[dsh-models] list ok: ${parsed.length} models from ${provider.modelsUri}',
    );
    if (parsed.isEmpty) {
      return ModelListResult(
        ok: false,
        rawCount: 0,
        error: ApiErrorText(
          zh: tr(
              '接口通了但没解析出任何模型：服务商返回的结构不是预期的 OpenAI 格式。可以改用「自定义模型」手填 model id。'),
          detail: body.length > 400 ? '${body.substring(0, 400)}…' : body,
        ),
      );
    }
    final sorted = List<FetchedModel>.from(parsed)
      ..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    return ModelListResult(ok: true, models: sorted, rawCount: sorted.length);
  } catch (e) {
    final error = translateException(e);
    debugPrint('[dsh-models] list threw: ${error.zh}');
    return ModelListResult(ok: false, error: error);
  } finally {
    client.close(force: true);
  }
}

/// 解析模型列表。容忍几种真实存在的返回形态：
///   * `{"object":"list","data":[{id,name,context_length,...}]}`  （OpenAI / Command）
///   * `{"data":["model-a","model-b"]}`
///   * `[{...}]` / `["model-a"]`
///   * `{"models":[{...}]}`
List<FetchedModel> _parseModelList(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw FormatException(tr('响应不是 JSON'));
  }

  List<Object?> raw;
  if (decoded is List) {
    raw = decoded;
  } else if (decoded is Map) {
    final candidate = decoded['data'] ?? decoded['models'] ?? decoded['result'];
    if (candidate is List) {
      raw = candidate;
    } else {
      raw = const <Object?>[];
    }
  } else {
    raw = const <Object?>[];
  }

  final out = <FetchedModel>[];
  final seen = <String>{};
  for (final item in raw) {
    String? id;
    String? name;
    int? ctx;
    var endpoints = const <String>[];

    if (item is String) {
      id = item;
    } else if (item is Map) {
      for (final key in <String>['id', 'model', 'name', 'slug']) {
        final v = item[key];
        if (v is String && v.trim().isNotEmpty) {
          id = v.trim();
          break;
        }
      }
      for (final key in <String>['display_name', 'label', 'title']) {
        final v = item[key];
        if (v is String && v.trim().isNotEmpty) {
          name = v.trim();
          break;
        }
      }
      for (final key in <String>[
        'context_length',
        'context_window',
        'max_context_tokens'
      ]) {
        final v = item[key];
        if (v is int) {
          ctx = v;
          break;
        }
        if (v is String) {
          ctx = int.tryParse(v);
          if (ctx != null) break;
        }
      }
      final ep = item['supported_endpoints'];
      if (ep is List) {
        endpoints = ep.whereType<String>().toList();
      }
    }

    if (id == null || id.isEmpty || !seen.add(id)) continue;
    out.add(FetchedModel(
      id: id,
      displayName: name,
      contextLength: ctx,
      supportedEndpoints: endpoints,
    ));
  }
  return out;
}

/// 一次真实连通性测试的结果。
class ModelTestResult {
  const ModelTestResult({
    required this.ok,
    this.error,
    this.replyPreview,
    this.latencyMs,
  });

  final bool ok;

  /// 失败原因（已翻译成中文）
  final ApiErrorText? error;

  /// 成功时模型返回的内容片段（证明它真的回话了）
  final String? replyPreview;

  /// 往返耗时（毫秒）
  final int? latencyMs;
}

/// **真打一次**最小对话请求，验证「端点 + Key + 这个模型名」三者是否真能用。
///
/// 为什么不是只测 `/models`：`/models` 只能证明 Key 与端点通，
/// **证明不了你填的这个模型名能不能跑**（模型名写错是最常见的失败原因），
/// 而且各服务商 `/models` 的覆盖面并不一致。
///
/// 为什么用 `POST /chat/completions`：App 的 overlay 就是用
/// `api: openai-completions` 跑对话的，测试必须和**实际使用的**是同一条路，
/// 否则"测试通过、对话失败"就成了新的坑。`max_tokens` 压到 16，成本可忽略。
Future<ModelTestResult> testModelConnection({
  required String baseUrl,
  required String apiKey,
  required String modelId,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final base = baseUrl.trim();
  final key = apiKey.trim();
  final model = modelId.trim();
  if (base.isEmpty || key.isEmpty || model.isEmpty) {
    return ModelTestResult(
      ok: false,
      error: ApiErrorText(zh: tr('Base URL / API Key / model id 三项都要填才能测试。')),
    );
  }

  final uri =
      Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
  final client = HttpClient()..connectionTimeout = timeout;
  final sw = Stopwatch()..start();
  try {
    final request = await client.postUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.add(utf8.encode(jsonEncode(<String, dynamic>{
      'model': model,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'ping'},
      ],
      'max_tokens': 16,
      'stream': false,
    })));

    final response = await request.close().timeout(timeout);
    final bytes = await response
        .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
    final body = utf8.decode(bytes, allowMalformed: true);
    sw.stop();

    if (response.statusCode != 200) {
      debugPrint('[dsh-models] 连通性测试失败 HTTP ${response.statusCode} url=$uri');
      return ModelTestResult(
        ok: false,
        latencyMs: sw.elapsedMilliseconds,
        error: translateHttpError(statusCode: response.statusCode, body: body),
      );
    }
    debugPrint('[dsh-models] 连通性测试通过 ${sw.elapsedMilliseconds}ms model=$model');
    return ModelTestResult(
      ok: true,
      latencyMs: sw.elapsedMilliseconds,
      replyPreview: _previewReply(body),
    );
  } catch (e) {
    sw.stop();
    return ModelTestResult(
      ok: false,
      latencyMs: sw.elapsedMilliseconds,
      error: translateException(e),
    );
  } finally {
    client.close(force: true);
  }
}

/// 从 OpenAI 风格的响应里取出模型说的话（取不到就退化成正文片段）。
String? _previewReply(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final choices = decoded['choices'];
      if (choices is List && choices.isNotEmpty) {
        final first = choices.first;
        if (first is Map) {
          final message = first['message'];
          if (message is Map && message['content'] is String) {
            return (message['content'] as String).trim();
          }
          if (first['text'] is String) return (first['text'] as String).trim();
        }
      }
    }
  } catch (_) {}
  final t = body.trim();
  if (t.isEmpty) return null;
  return t.length > 200 ? '${t.substring(0, 200)}…' : t;
}

/// 把上下文长度写成 `1M` / `128K` 这种好读的形式。
String formatContextLength(int? tokens) {
  if (tokens == null || tokens <= 0) return '';
  if (tokens >= 1000000) {
    final m = tokens / 1000000;
    return tr('{0}M 上下文', [m.toStringAsFixed(m == m.roundToDouble() ? 0 : 1)]);
  }
  if (tokens >= 1000) return tr('{0}K 上下文', [(tokens / 1000).round()]);
  return tr('{0} 上下文', [tokens]);
}
