import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// 会话里的**联网搜索** —— **AnySearch**（用户 2026-10-15 选定「B 方案」）。
///
/// ## 为什么走 MCP，而不是自己写一个工具／塞一个脚本
///
/// 手机上的会话跑的是**真的 DSH**（`node <runtime> --profile acp`），而 ACP 协议的
/// `session/new` / `session/resume` 本来就带 `mcpServers` 字段（我们之前一直传空数组）。
/// AnySearch 官方提供 **Streamable HTTP 的 MCP 端点**（`https://api.anysearch.com/mcp`），
/// 而 DSH 的 ACP 层原生支持这种 transport（`dsh-acp` 的 `resolveMcpConfigs`：
/// `type: 'http'` → `streamable-http`）。所以在手机上接通它**只需要一个字段**：
///
///   * 不用往运行时里塞脚本、不用起子进程 —— 也就绕开了 Android
///     「App 私有目录不能执行文件」那一串坑（bash/node 那套 exec shim 的由来）；
///   * 不用自己写工具、不用改 `dsh-runtime.zip`（那是发布流水线的事）。
///
/// ## 免 Key 也能搜（和「免费模型」同一条口径）
///
/// AnySearch 的匿名层可用，只是**限流低**；给一个真实邮箱注册
/// （`POST https://api.anysearch.com/v1/auth/email/register`）能拿到 `as_sk_…`，
/// 配额按账号给。所以这里：
///
///   * 没 Key → 只带 `X-Anysearch-Client`（匿名，**用户什么都不用填**）；
///   * 有 Key → 再加 `Authorization: Bearer as_sk_…`（限流更高）。
///
/// ⚠️ 别把 Key 写进日志：这里只打"有没有 Key"，从不打值。
class AnySearch {
  AnySearch._();

  /// 在 ACP 里注册的服务器名（工具会挂在它下面）。
  static const String serverName = 'anysearch';

  /// 官方 MCP 端点（Streamable HTTP）。
  static const String mcpUrl = 'https://api.anysearch.com/mcp';

  /// 普通 REST 搜索端点 —— 只用在设置页那个「测一下」上。
  static const String searchUrl = 'https://api.anysearch.com/v1/search';

  /// 官方要求的客户端标识头（匿名时**只带它**也能用）。
  static const String clientHeaderName = 'X-Anysearch-Client';
  static const String clientHeaderValue = 'dsh-mobile/0.76';

  /// Key 存在系统安全区时用的 id。
  ///
  /// ⚠️ 与 `local/web_search.dart` 里的 `searchKeyId()` **同一个命名空间**
  /// （`search-<厂家>`）—— 将来若再把 AnySearch 接进端侧对话的 🔍，
  /// 两边读的是同一把 Key，不会出现"设置页填了、另一处说没填"的老毛病。
  static const String keyStorageId = 'search-anysearch';

  /// 给 ACP `session/new` / `session/resume` 用的 `mcpServers` 条目。
  ///
  /// 形状按 ACP 约束来（`dsh-acp` 会逐条校验，写错会直接拒掉整个会话请求）：
  ///
  ///   * `type: 'http'` —— 另一种是 stdio（`command` **必须是绝对路径**，
  ///     手机上还得能执行那个文件，所以这里不用它）；
  ///   * `url` 必须是 http(s)；
  ///   * `headers` 是**有序的 name/value 条目**，不是普通 map
  ///     （`entriesToRecord()` 会拒重复键）。
  static List<Map<String, dynamic>> mcpServers({String? apiKey}) {
    final key = (apiKey ?? '').trim();
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'name': serverName,
        'type': 'http',
        'url': mcpUrl,
        'headers': <Map<String, String>>[
          <String, String>{
            'name': clientHeaderName,
            'value': clientHeaderValue,
          },
          // 匿名也能用 —— **没 Key 时这一条直接不加**（不是发一个空 Bearer）。
          if (key.isNotEmpty)
            <String, String>{
              'name': 'Authorization',
              'value': 'Bearer $key',
            },
        ],
      },
    ];
  }

  /// 设置页那个「测一下」：直接打一次真搜索，把"通不通"如实回给用户。
  ///
  /// **不抛异常**：失败也返回中文原因（界面照原样显示），避免在 UI 里到处 catch。
  /// [baseOverride] / [httpClient] 只在测试里注入（本地假服务）。
  static Future<({bool ok, int results, String? error})> testConnection({
    String? apiKey,
    String query = 'deepseek harness',
    Duration timeout = const Duration(seconds: 20),
    String? baseOverride,
    HttpClient? httpClient,
  }) async {
    final key = (apiKey ?? '').trim();
    final client = httpClient ?? HttpClient();
    client.connectionTimeout = timeout;
    try {
      final req = await client
          .postUrl(Uri.parse(baseOverride ?? searchUrl))
          .timeout(timeout);
      req.headers.contentType = ContentType.json;
      req.headers.set('accept', 'application/json');
      req.headers.set(clientHeaderName, clientHeaderValue);
      if (key.isNotEmpty) req.headers.set('authorization', 'Bearer $key');
      req.add(utf8.encode(jsonEncode(<String, Object?>{
        'query': query,
        'max_results': 3,
      })));
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        debugPrint('[dsh-anysearch] 测试 HTTP ${res.statusCode}');
        return (
          ok: false,
          results: 0,
          error: '搜索服务返回 HTTP ${res.statusCode}（'
              '${text.length > 160 ? '${text.substring(0, 160)}…' : text}）',
        );
      }
      final n = countResults(text);
      if (n < 0) {
        return (ok: false, results: 0, error: '返回的不是能认出来的搜索结果');
      }
      debugPrint('[dsh-anysearch] 测试通过：$n 条结果（${key.isEmpty ? "匿名" : "带 Key"}）');
      return (ok: true, results: n, error: null);
    } catch (e) {
      debugPrint('[dsh-anysearch] 测试失败：$e');
      return (ok: false, results: 0, error: '连不上搜索服务：$e');
    } finally {
      if (httpClient == null) client.close(force: true);
    }
  }

  /// 从 `/v1/search` 的响应体里数出结果条数；认不出来返回 -1。
  ///
  /// 抽成纯函数是为了能被单测钉住（形状：`{"code":0,"data":{"results":[…]}}`）。
  static int countResults(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return -1;
      final data = decoded['data'];
      if (data is! Map) return -1;
      final results = data['results'];
      if (results is! List) return -1;
      return results.length;
    } catch (_) {
      return -1;
    }
  }

  /// 把一次搜索结果压成给模型看的紧凑文本（会话里由 MCP 返回；这里留给"引用卡片"等用途）。
  static String renderResults(String body, {int max = 5}) {
    try {
      final decoded = jsonDecode(body);
      final data = (decoded as Map)['data'];
      final list = (data as Map)['results'] as List;
      final out = <String>[];
      for (final item in list.take(max)) {
        if (item is! Map) continue;
        final title = (item['title'] ?? '').toString().trim();
        final url = (item['url'] ?? '').toString().trim();
        final snippet = (item['snippet'] ?? item['content'] ?? '').toString().trim();
        out.add('- [$title]($url)${snippet.isEmpty ? '' : '\n  $snippet'}');
      }
      return out.join('\n');
    } catch (_) {
      return '';
    }
  }
}
