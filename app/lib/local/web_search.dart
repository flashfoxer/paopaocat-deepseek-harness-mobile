/// 联网搜索 —— 给「本地对话」的 🔍 用。
///
/// ## 为什么由 App 发起，而不是让模型自己调工具
///
/// 0.6B/1B 的端侧模型**不会可靠地发起工具调用**：真机实测它把
/// `**[Tool Call: web_search]**` 当成**正文**吐出来（根本没真调）。
/// 所以搜索由 **App 侧**发起，把结果拼成"参考资料"折进用户那一轮的问题里。
///
/// 这条"参考资料注入"通道是**共用的**：联网搜索、以后的知识库检索都走它 ——
/// 对模型来说都只是"你手上多了两页资料"，不需要它学会任何新协议。
///
/// ## 四家适配器（形状各不相同，对外只吐同一个类型）
///
/// | 厂家 | 端点 | 鉴权 |
/// |---|---|---|
/// | Tavily | `api.tavily.com/search` | 请求体里的 `api_key` |
/// | Serper | `google.serper.dev/search` | 头 `X-API-KEY` |
/// | 博查 | `api.bochaai.com/v1/web-search` | 头 `Authorization: Bearer` |
/// | DeepSeek 官方 | `api.deepseek.com/anthropic/v1/messages` | 头 `x-api-key`（服务端 web_search 工具） |
///
/// 以后要加第五家，只需要在这里加一个适配器 —— 界面与对话逻辑都不用改。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../data/api_error_text.dart';

/// 一条搜索结果。
class WebSearchResult {
  const WebSearchResult({required this.title, required this.url, this.snippet = ''});

  final String title;
  final String url;
  final String snippet;

  static WebSearchResult? fromParts(Object? title, Object? url, Object? snippet) {
    final t = (title ?? '').toString().trim();
    final u = (url ?? '').toString().trim();
    if (u.isEmpty && t.isEmpty) return null;
    return WebSearchResult(
      title: t.isEmpty ? u : t,
      url: u,
      snippet: (snippet ?? '').toString().trim(),
    );
  }
}

/// 搜到几家就这几家（`off` = 用户没启用）。
enum WebSearchProvider { off, tavily, serper, bocha, deepseek, bing, duck }

extension WebSearchProviderInfo on WebSearchProvider {
  /// 落盘用的稳定 id（**别改**，改了老用户的设置就读不出来了）。
  String get id => switch (this) {
        WebSearchProvider.off => 'off',
        WebSearchProvider.tavily => 'tavily',
        WebSearchProvider.serper => 'serper',
        WebSearchProvider.bocha => 'bocha',
        WebSearchProvider.deepseek => 'deepseek',
        // 下面两个是**免费、不用 Key** 的：抓的是公开搜索结果页（HTML）。
        WebSearchProvider.bing => 'bing',
        WebSearchProvider.duck => 'duck',
      };

  /// 界面上的名字。Tavily / Serper / 博查 是专做搜索的 API；
  /// DeepSeek 官方那个走的是它自家的服务端 web_search 工具。
  String get label => switch (this) {
        WebSearchProvider.off => '关闭',
        WebSearchProvider.tavily => 'Tavily',
        WebSearchProvider.serper => 'Serper',
        WebSearchProvider.bocha => '博查',
        WebSearchProvider.deepseek => 'DeepSeek 官方',
        WebSearchProvider.bing => 'Bing（免费・不用 Key）',
        WebSearchProvider.duck => 'DuckDuckGo（免费・不用 Key）',
      };

  /// 要不要填 Key（免费源不用）。
  bool get needsKey =>
      this != WebSearchProvider.off &&
      this != WebSearchProvider.bing &&
      this != WebSearchProvider.duck;

  /// Key 从哪儿弄（界面上的如实说明，不让用户自己猜）。
  String get keyHint => switch (this) {
        WebSearchProvider.tavily => 'platform.tavily.com（有免费额度）',
        WebSearchProvider.serper => 'serper.dev（有免费额度）',
        WebSearchProvider.bocha => 'open.bochaai.com',
        WebSearchProvider.deepseek => 'platform.deepseek.com（用你的 DeepSeek 官方 Key）',
        WebSearchProvider.bing => '',
        WebSearchProvider.duck => '',
        WebSearchProvider.off => '',
      };

  static WebSearchProvider byId(String? id) {
    for (final p in WebSearchProvider.values) {
      if (p.id == id) return p;
    }
    return WebSearchProvider.off;
  }
}

/// 搜索失败 —— [message] 尽量带上厂商的原话（便于判断是 Key 错还是额度用完）。
class WebSearchException implements Exception {
  WebSearchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Key 存在安全区时用的"厂家 id"（与模型厂家的 id 空间分开，避免互相覆盖）。
String searchKeyId(WebSearchProvider p) => 'search-${p.id}';

/// 这个厂家现在能不能直接查：**免费源永远能查**；要 Key 的必须先有 Key。
///
/// 抽成纯函数是为了让这条规则**能被单测钉住**（`key == null` 时 Bing 必须能查）。
///
/// 依据是真机 2026-10-09 反馈的 bug：用户选了**免费的 Bing**，点 🔍 却被告知
/// "Bing（免费・不用 Key）还没填 Key" —— 因为调用方（本地对话页）当时**无条件**
/// 要求有 Key，根本不看 [WebSearchProviderInfo.needsKey]，而设置页那边是按
/// `needsKey` 判断的（对免费源连 Key 输入框都不显示）。**两处口径不一致**，
/// 用户在设置页找不到地方填，又被要求去填。
bool webSearchHasCredential(WebSearchProvider p, String? key) =>
    !p.needsKey || (key != null && key.trim().isNotEmpty);

/// 搜一次。返回空列表 = 没有结果（不算失败）；失败抛 [WebSearchException]。
Future<List<WebSearchResult>> webSearch({
  required WebSearchProvider provider,
  required String apiKey,
  required String query,
  int maxResults = 5,
  Duration timeout = const Duration(seconds: 20),
  HttpClient? httpClient,
  /// 覆盖厂商端点。默认 null = 用各家官方地址。
  ///
  /// 两个用途：① 自建/自托管的搜索服务（比如自己的 SearXNG）；② **自测** ——
  /// 单元测试拿它指到本地假服务，不去打真网络（测试打真网络既慢又不可复现）。
  String? endpointOverride,
}) async {
  if (provider == WebSearchProvider.off) return const <WebSearchResult>[];
  final q = query.trim();
  if (q.isEmpty) return const <WebSearchResult>[];
  final client = httpClient ?? HttpClient();
  try {
    switch (provider) {
      case WebSearchProvider.tavily:
        return await _tavily(client, apiKey, q, maxResults, timeout, endpointOverride);
      case WebSearchProvider.serper:
        return await _serper(client, apiKey, q, maxResults, timeout, endpointOverride);
      case WebSearchProvider.bocha:
        return await _bocha(client, apiKey, q, maxResults, timeout, endpointOverride);
      case WebSearchProvider.deepseek:
        return await _deepseek(client, apiKey, q, maxResults, timeout, endpointOverride);
      case WebSearchProvider.bing:
        return await _bing(client, q, maxResults, timeout, endpointOverride);
      case WebSearchProvider.duck:
        return await _duck(client, q, maxResults, timeout, endpointOverride);
      case WebSearchProvider.off:
        return const <WebSearchResult>[];
    }
  } finally {
    if (httpClient == null) client.close(force: true);
  }
}

/// 发一个 JSON POST（四家里有三家是这个形状），把响应体解析成 JSON。
Future<Object?> _postJson(
  HttpClient client,
  String url,
  Map<String, String> headers,
  Object body,
  Duration timeout,
) async {
  final req = await client.postUrl(Uri.parse(url));
  req.headers.contentType = ContentType.json;
  headers.forEach(req.headers.set);
  req.add(utf8.encode(jsonEncode(body)));
  final res = await req.close().timeout(timeout);
  final text = await res.transform(utf8.decoder).join();
  if (res.statusCode < 200 || res.statusCode >= 300) {
    // 以前是把厂商原话直接甩出来（`HTTP 401：{…}`）—— 用户看不懂，只能来问。
    // translateHttpError 本身就会读返回体来区分"额度不够"和"Key 无效"
    // （这两者修法完全不同，所以原话仍然有用，留在最后）。审计 P1-2。
    final human = translateHttpError(statusCode: res.statusCode, body: text).zh;
    throw WebSearchException('$human（HTTP ${res.statusCode}）${_clip(text, 160)}');
  }
  try {
    return jsonDecode(text);
  } catch (_) {
    throw WebSearchException('返回的不是 JSON：${_clip(text, 200)}');
  }
}

String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

Future<List<WebSearchResult>> _tavily(HttpClient c, String key, String q,
    int n, Duration t, String? override) async {
  final j = await _postJson(c, override ?? 'https://api.tavily.com/search', const <String, String>{},
      <String, dynamic>{
        'api_key': key,
        'query': q,
        'max_results': n,
        'search_depth': 'basic',
      }, t);
  final results = (j is Map ? j['results'] : null) as List? ?? const <Object?>[];
  return <WebSearchResult>[
    for (final r in results)
      if (r is Map)
        if (WebSearchResult.fromParts(r['title'], r['url'], r['content']) != null)
          WebSearchResult.fromParts(r['title'], r['url'], r['content'])!,
  ];
}

Future<List<WebSearchResult>> _serper(HttpClient c, String key, String q,
    int n, Duration t, String? override) async {
  final j = await _postJson(
      c,
      override ?? 'https://google.serper.dev/search',
      <String, String>{'X-API-KEY': key},
      <String, dynamic>{'q': q, 'num': n},
      t);
  final organic = (j is Map ? j['organic'] : null) as List? ?? const <Object?>[];
  return <WebSearchResult>[
    for (final r in organic)
      if (r is Map)
        if (WebSearchResult.fromParts(r['title'], r['link'], r['snippet']) != null)
          WebSearchResult.fromParts(r['title'], r['link'], r['snippet'])!,
  ];
}

Future<List<WebSearchResult>> _bocha(HttpClient c, String key, String q,
    int n, Duration t, String? override) async {
  final j = await _postJson(
      c,
      override ?? 'https://api.bochaai.com/v1/web-search',
      <String, String>{'Authorization': 'Bearer $key'},
      <String, dynamic>{'query': q, 'count': n, 'summary': true},
      t);
  final data = (j is Map ? j['data'] : null) as Map?;
  final pages = (data?['webPages'] as Map?)?['value'] as List? ?? const <Object?>[];
  return <WebSearchResult>[
    for (final r in pages)
      if (r is Map)
        if (WebSearchResult.fromParts(r['name'], r['url'], r['snippet']) != null)
          WebSearchResult.fromParts(r['name'], r['url'], r['snippet'])!,
  ];
}

/// DeepSeek 官方：走 Anthropic 兼容端点 + **服务端 web_search 工具**。
///
/// 形状与前三家完全不同（它不是"搜索 API"，是"让模型去搜"）：
/// 结果在 `content` 块的 `web_search_tool_result` 里，摘要则散在正文的 citations 里。
Future<List<WebSearchResult>> _deepseek(HttpClient c, String key, String q,
    int n, Duration t, String? override) async {
  final j = await _postJson(
      c,
      override ?? 'https://api.deepseek.com/anthropic/v1/messages',
      <String, String>{
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
      },
      <String, dynamic>{
        // ⚠️ 用**当前**的模型名（2026-10-16 核对）：官方 `/models` 现在只列
        //    `deepseek-flash` / `deepseek-v4-pro`，而 V4 这两个都声明了
        //    `api_capabilities.anthropic_messages` —— 也就是支持我们这条路
        //    （Anthropic 兼容端点 + 服务端 web_search 工具）。
        //    以前写的是 `deepseek-chat`（V3 时代的名字），有失效风险。
        'model': 'deepseek-flash',
        'max_tokens': 1024,
        'tools': <Object>[
          <String, dynamic>{
            'type': 'web_search_20250305',
            'name': 'web_search',
            'max_uses': n,
          },
        ],
        'messages': <Object>[
          <String, dynamic>{
            'role': 'user',
            'content': <Object>[
              <String, dynamic>{
                'type': 'text',
                'text': 'Perform a web search for the query: $q',
              },
            ],
          },
        ],
      },
      t);
  final blocks = (j is Map ? j['content'] : null) as List? ?? const <Object?>[];

  // ① 先把正文里的 citations 收成 url → 摘要（官方搜索结果是"无内联摘要"的，
  //    摘要只出现在引用里 —— DSH 自带的搜索插件也是这么抠的）。
  final snippets = <String, String>{};
  for (final b in blocks) {
    if (b is! Map || b['type'] != 'text') continue;
    for (final cite in (b['citations'] as List? ?? const <Object?>[])) {
      if (cite is! Map) continue;
      final url = (cite['url'] ?? '').toString();
      final text = (cite['cited_text'] ?? cite['text'] ?? '').toString();
      if (url.isNotEmpty && text.isNotEmpty) snippets[url] = text.trim();
    }
  }

  // ② 再从搜索结果块里取 url / title（并按 url 去重）。
  final out = <WebSearchResult>[];
  final seen = <String>{};
  for (final b in blocks) {
    if (b is! Map || b['type'] != 'web_search_tool_result') continue;
    for (final item in (b['content'] as List? ?? const <Object?>[])) {
      if (item is! Map) continue;
      final url = (item['url'] ?? '').toString();
      if (url.isEmpty || !seen.add(url)) continue;
      final r = WebSearchResult.fromParts(
          item['title'], url, snippets[url] ?? '');
      if (r != null) out.add(r);
      if (out.length >= n) break;
    }
  }
  return out;
}

/// 把结果拼成"参考资料"块（注入到那一轮的问题前面）。
///
/// 措辞是刻意的：**明确要求它只依据资料、不要编** —— 小模型最容易犯的正是
/// "资料里没有的部分自己圆一段"。
String formatSearchContext(
  List<WebSearchResult> results, {
  int maxSnippetChars = 240,
  int maxResults = 5,
}) {
  if (results.isEmpty) return '';
  final buf = StringBuffer()
    ..writeln('以下是联网搜索到的参考资料，请优先依据它们回答；')
    ..writeln('资料里没提到的部分不要编造，直接说不确定。')
    ..writeln();
  var i = 0;
  for (final r in results.take(maxResults)) {
    i++;
    buf.writeln('[$i] ${r.title}');
    if (r.url.isNotEmpty) buf.writeln('来源：${r.url}');
    final s = r.snippet.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isNotEmpty) {
      buf.writeln(s.length <= maxSnippetChars
          ? s
          : '${s.substring(0, maxSnippetChars)}…');
    }
    buf.writeln();
  }
  return buf.toString().trimRight();
}


// ───────────────────────── 免费源（抓公开搜索结果页，不用 Key）─────────────────────

/// 伪装成普通浏览器 —— 不带 UA 的话这些页面会返回一坨"请启用 JavaScript"。
const String _browserUa =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/122.0 Mobile Safari/537.36';

Future<String> _getText(
    HttpClient c, String url, Duration timeout) async {
  final req = await c.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, _browserUa);
  req.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml');
  final res = await req.close().timeout(timeout);
  final body = await res.transform(utf8.decoder).join();
  if (res.statusCode < 200 || res.statusCode >= 300) {
    final human = translateHttpError(statusCode: res.statusCode, body: body).zh;
    throw WebSearchException('$human（HTTP ${res.statusCode}）${_clip(body, 160)}');
  }
  return body;
}

String _stripTags(String html) => _unescape(html
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim());

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ');

/// Bing 的结果链接多半是 `bing.com/ck/a?...&u=a1<base64>` —— 把真网址解出来。
String _bingRealUrl(String href) {
  final m = RegExp(r'[?&]u=a1([^&]+)').firstMatch(href);
  if (m == null) return href;
  try {
    final b64 = Uri.decodeComponent(m.group(1)!);
    final padded = b64 + '=' * ((4 - b64.length % 4) % 4);
    final url = utf8.decode(base64.decode(padded));
    return url.startsWith('http') ? url : href;
  } catch (_) {
    return href;
  }
}

/// Bing（cn.bing.com，国内通常能访问）。
///
/// ⚠️ **这里有两代页面结构，必须都认**（2026-10-09 真机反馈「搜索依然不能用」的根因）：
///
///   旧版：`<h2 …><a href="…">标题</a></h2>`                —— 链接在 h2 **里面**
///   新版：`<a class="tilk" href="…"><h2><strong>标题</strong></h2></a>` —— 链接**包住** h2
///
/// 只认旧版时，新版页面**一个标题都匹配不到** → 结果为空 → 报
/// 「没解析出结果（页面可能改版了，或被要求验证）」，用户看到的就是"搜索不能用"。
/// 实测（2026-10-09，cn.bing.com 返回 61 KB）：`li.b_algo` 有 **5** 个块，
/// 而旧正则能匹配到标题的块数是 **0**。
///
/// 所以这里改成：① 块按 `<li … class="b_algo"` 切开（不依赖 `</li>` 配对 ——
/// 块里可能有嵌套列表，`.*?</li>` 会提前截断）；② 两代结构各试一次；
/// ③ 都失败就退一步用「块里第一个外链 + 第一个 h2 文本」兜底。
Future<List<WebSearchResult>> _bing(
    HttpClient c, String q, int n, Duration t, String? override) async {
  final html = await _getText(
      c,
      '${override ?? 'https://cn.bing.com/search'}'
      '?q=${Uri.encodeQueryComponent(q)}&count=$n',
      t);
  final out = <WebSearchResult>[];

  // ① 按开标签切块（属性顺序/其它属性都不影响匹配）。
  final starts = RegExp(r'<li[^>]*class="b_algo"', caseSensitive: false)
      .allMatches(html)
      .map((m) => m.start)
      .toList();

  final wrapRe =
      RegExp(r'<a[^>]*href="([^"]+)"[^>]*>\s*<h2[^>]*>(.*?)</h2>', dotAll: true);
  final innerRe = RegExp(
      r'<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
      dotAll: true);
  final pRe = RegExp(r'<p[^>]*>(.*?)</p>', dotAll: true);
  final h2Re = RegExp(r'<h2[^>]*>(.*?)</h2>', dotAll: true);
  final anyHrefRe = RegExp(r'href="(https?://[^"]+)"');

  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1] : html.length;
    final block = html.substring(starts[i], end);

    String? href;
    String title = '';
    final wrap = wrapRe.firstMatch(block);
    if (wrap != null) {
      href = wrap.group(1);
      title = wrap.group(2) ?? '';
    } else {
      final inner = innerRe.firstMatch(block);
      if (inner != null) {
        href = inner.group(1);
        title = inner.group(2) ?? '';
      } else {
        // ③ 兜底：结构又变了也别直接归零。
        href = anyHrefRe.firstMatch(block)?.group(1);
        title = h2Re.firstMatch(block)?.group(1) ?? '';
      }
    }
    if (href == null || title.trim().isEmpty) continue;
    final snip = pRe.firstMatch(block);
    final r = WebSearchResult.fromParts(
      _stripTags(title),
      _bingRealUrl(_unescape(href)),
      snip == null ? '' : _stripTags(snip.group(1)!),
    );
    if (r != null) out.add(r);
    if (out.length >= n) break;
  }
  if (out.isEmpty) {
    throw WebSearchException('没解析出结果（页面可能改版了，或被要求验证）');
  }
  return out;
}

/// DuckDuckGo lite（海外更稳、国内多半连不上）。抓 `a.result-link` 与
/// `td.result-snippet`。
Future<List<WebSearchResult>> _duck(
    HttpClient c, String q, int n, Duration t, String? override) async {
  final html = await _getText(
      c,
      '${override ?? 'https://lite.duckduckgo.com/lite/'}'
      '?q=${Uri.encodeQueryComponent(q)}',
      t);
  final linkRe =
      RegExp(r'<a[^>]*class="result-link"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
          dotAll: true);
  final snipRe =
      RegExp(r'<td[^>]*class="result-snippet"[^>]*>(.*?)</td>', dotAll: true);
  final links = linkRe.allMatches(html).toList();
  final snips = snipRe.allMatches(html).toList();
  final out = <WebSearchResult>[];
  for (var i = 0; i < links.length && out.length < n; i++) {
    final a = links[i];
    final r = WebSearchResult.fromParts(
      _stripTags(a.group(2)!),
      _unescape(a.group(1)!),
      i < snips.length ? _stripTags(snips[i].group(1)!) : '',
    );
    if (r != null) out.add(r);
  }
  if (out.isEmpty) {
    throw WebSearchException('没解析出结果（可能被限流或访问不到）');
  }
  return out;
}
