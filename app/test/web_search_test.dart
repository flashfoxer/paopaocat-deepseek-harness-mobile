/// 联网搜索的回归测试。
///
/// 全部用**本地假服务**（`endpointOverride` 指过去），**不打真网络** ——
/// 测试打真网络既慢又不可复现，而且会把"厂商今天改版了"混进"我代码坏了"里。
///
/// 这里锁住四件事：
///   1. 四家付费 API 的**请求形状**（Key 放哪儿、参数名对不对）与**解析**；
///   2. DeepSeek 那种"结果在工具块里、摘要在引用里"的怪形状能抠出来；
///   3. 免费源（Bing / DuckDuckGo）的 **HTML 解析**与跳转链还原；
///   4. 出错时**把厂商原话带出来**（401 和 429 的修法完全不同）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/local/web_search.dart';
import 'package:flutter_test/flutter_test.dart';

/// 起一个本地假服务，按路径回不同的假响应；把收到的请求记下来给断言用。
Future<({HttpServer server, List<Map<String, dynamic>> seen})> _fakeServer(
  Future<void> Function(HttpRequest req, String body) handler,
) async {
  final seen = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = await utf8.decoder.bind(req).join();
    seen.add(<String, dynamic>{
      'path': req.uri.path,
      'query': req.uri.query,
      'body': body,
      'headers': <String, String>{
        for (final k in <String>['x-api-key', 'authorization', 'x-api-key'.toUpperCase()])
          if (req.headers.value(k) != null) k: req.headers.value(k)!,
      },
    });
    await handler(req, body);
  });
  return (server: server, seen: seen);
}

void main() {
  group('付费源：请求形状与解析', () {
    test('Tavily：Key 在请求体里，结果从 results[] 取', () async {
      final f = await _fakeServer((req, body) async {
        req.response.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        req.response.write(jsonEncode(<String, Object>{
          'results': <Object>[
            <String, Object>{
              'title': '晋城 - 维基百科',
              'url': 'https://zh.wikipedia.org/wiki/晋城',
              'content': '晋城位于山西省东南部。',
            },
          ],
        }));
        await req.response.close();
      });
      final r = await webSearch(
        provider: WebSearchProvider.tavily,
        apiKey: 'tvly-123',
        query: '晋城',
        endpointOverride: 'http://127.0.0.1:${f.server.port}/search',
      );
      await f.server.close(force: true);

      expect(r.length, 1);
      expect(r.first.title, contains('晋城'));
      expect(r.first.snippet, contains('山西省东南部'));
      final body = jsonDecode(f.seen.first['body'] as String) as Map;
      expect(body['api_key'], 'tvly-123');
      expect(body['query'], '晋城');
    });

    test('Serper：Key 在 X-API-KEY 头里，结果从 organic[] 取', () async {
      final f = await _fakeServer((req, body) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object>{
          'organic': <Object>[
            <String, Object>{
              'title': '晋城市人民政府',
              'link': 'https://www.jcgov.gov.cn/',
              'snippet': '晋城市人民政府门户网站',
            },
          ],
        }));
        await req.response.close();
      });
      final r = await webSearch(
        provider: WebSearchProvider.serper,
        apiKey: 'sp-abc',
        query: '晋城',
        endpointOverride: 'http://127.0.0.1:${f.server.port}/search',
      );
      await f.server.close(force: true);
      expect(r.first.url, 'https://www.jcgov.gov.cn/');
      expect((jsonDecode(f.seen.first['body'] as String) as Map)['q'], '晋城');
    });

    test('博查：Bearer 头 + data.webPages.value[]', () async {
      final f = await _fakeServer((req, body) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object>{
          'data': <String, Object>{
            'webPages': <String, Object>{
              'value': <Object>[
                <String, Object>{
                  'name': '晋城百科',
                  'url': 'https://example.com/jc',
                  'snippet': '晋城，古称泽州。',
                },
              ],
            },
          },
        }));
        await req.response.close();
      });
      final r = await webSearch(
        provider: WebSearchProvider.bocha,
        apiKey: 'sk-bocha',
        query: '晋城',
        endpointOverride: 'http://127.0.0.1:${f.server.port}/v1/web-search',
      );
      await f.server.close(force: true);
      expect(r.first.title, '晋城百科');
      expect(r.first.snippet, '晋城，古称泽州。');
    });

    test('DeepSeek 官方：结果在工具块、摘要在引用里 —— 两块要拼起来', () async {
      final f = await _fakeServer((req, body) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object>{
          'content': <Object>[
            <String, Object>{
              'type': 'web_search_tool_result',
              'content': <Object>[
                <String, Object>{
                  'type': 'web_search_result',
                  'url': 'https://zh.wikipedia.org/wiki/晋城',
                  'title': '晋城 - 维基百科',
                },
              ],
            },
            <String, Object>{
              'type': 'text',
              'text': '晋城是山西省的一个地级市。',
              'citations': <Object>[
                <String, Object>{
                  'url': 'https://zh.wikipedia.org/wiki/晋城',
                  'cited_text': '晋城位于山西省东南部，古称泽州。',
                },
              ],
            },
          ],
        }));
        await req.response.close();
      });
      final r = await webSearch(
        provider: WebSearchProvider.deepseek,
        apiKey: 'sk-ds',
        query: '晋城',
        endpointOverride: 'http://127.0.0.1:${f.server.port}/anthropic/v1/messages',
      );
      await f.server.close(force: true);

      expect(r.length, 1);
      expect(r.first.title, '晋城 - 维基百科');
      // 关键：摘要来自 citations（官方搜索结果本身不带摘要）。
      expect(r.first.snippet, contains('古称泽州'));
      final body = jsonDecode(f.seen.first['body'] as String) as Map;
      expect(jsonEncode(body['tools']), contains('web_search'));
    });
  });

  group('免费源：HTML 解析', () {
    test('Bing：解析 b_algo 块，并把 ck/a 跳转链还原成真网址', () async {
      // u=a1 + base64('https://www.jcgov.gov.cn/')
      final real = base64.encode(utf8.encode('https://www.jcgov.gov.cn/'));
      final html = '''
<html><body><ol id="b_results">
<li class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1$real">晋城市人民政府</a></h2>
<p>晋城市人民政府门户网站，发布政务信息。</p></li>
<li class="b_algo"><h2><a href="https://zh.wikipedia.org/wiki/%E6%99%8B%E5%9F%8E">晋城 - 维基百科</a></h2>
<p>晋城位于山西省东南部。</p></li>
</ol></body></html>''';
      final f = await _fakeServer((req, body) async {
        req.response.headers.contentType = ContentType.html;
        req.response.write(html);
        await req.response.close();
      });
      final r = await webSearch(
        provider: WebSearchProvider.bing,
        apiKey: '',
        query: '晋城',
        endpointOverride: 'http://127.0.0.1:${f.server.port}/search',
      );
      await f.server.close(force: true);

      expect(r.length, 2);
      expect(r.first.url, 'https://www.jcgov.gov.cn/'); // 跳转链已还原
      expect(r.first.title, '晋城市人民政府');
      expect(r.first.snippet, contains('政务信息'));
      expect(r[1].url, contains('zh.wikipedia.org'));
    });

    test('Bing 新版结构：链接**包住** h2 —— 真机 2026-10-09「搜索依然不能用」的根因',
        () async {
      // 结构与实测抓到的 cn.bing.com 一致（2026-10-09 抓，页面 61 KB 返回 200）：
      //   <a class="tilk" aria-label="capcut.cn" RedirectUrl="" tabindex="-1"
      //      href="https://www.capcut.cn/"><h2><strong>剪映</strong>官网…</h2></a>
      //   <div class="b_caption"><p class="b_lineclamp3">摘要…</p></div>
      //
      // 旧解析器要求 `<h2 …><a href>`（链接在 h2 **里面**）—— 方向正好相反，
      // 于是 `li.b_algo` 有 5 个块、**能匹配到标题的 0 个** → 抛
      // 「没解析出结果（页面可能改版了，或被要求验证）」，用户看到的就是"搜索不能用"。
      // 这条测试把"两代结构都要认"钉住。
      const html = '''
<html><body><ol id="b_results">
<li class="b_algo" data-id iid=SERP.5252><link rel="stylesheet" href="/rp/x.css" type="text/css"/><a class="tilk" aria-label="capcut.cn" RedirectUrl="" tabindex="-1" href="https://www.capcut.cn/"><h2><strong>剪映</strong>官网-<strong>剪映</strong>AI 创作无限新可能</h2></a><div class="b_caption"><p class="b_lineclamp3" data-rslinkclamp-iid="">剪映，你的全能AI创作伙伴。</p></div></li>
<li class="b_algo" data-id iid=SERP.5253><a class="tilk" href="https://zh.wikipedia.org/wiki/%E5%89%AA%E6%98%A0"><h2>剪映 - 维基百科</h2></a><div class="b_caption"><p>剪映是由字节跳动开发的视频剪辑软件。</p></div></li>
</ol></body></html>''';
      final f = await _fakeServer((req, body) async {
        req.response.headers.contentType = ContentType.html;
        req.response.write(html);
        await req.response.close();
      });
      final r = await webSearch(
        provider: WebSearchProvider.bing,
        apiKey: '',
        query: '剪映',
        endpointOverride: 'http://127.0.0.1:${f.server.port}/search',
      );
      await f.server.close(force: true);

      expect(r.length, 2, reason: '新版结构必须能解析出结果 —— 这就是根因所在');
      expect(r.first.url, 'https://www.capcut.cn/');
      // 标题里的 <strong> 要被去掉（否则界面上会显示一堆标签）。
      expect(r.first.title, contains('剪映'));
      expect(r.first.title, isNot(contains('<')));
      expect(r.first.snippet, contains('全能AI创作伙伴'));
      expect(r[1].url, contains('zh.wikipedia.org'));
    });

    test('Bing 结构又变时兜底：至少不整页归零', () async {
      // 第三种形状（既不是包住也不是装在 h2 里）：块里有个外链和 h2。
      // 兜底不追求完美，只保证"不要一条都没有"——否则用户看到的是彻底不能用。
      const html = '''
<html><body><ol id="b_results">
<li class="b_algo" data-id><div class="b_title"><h2>晋城 - 维基百科</h2></div><div><a href="https://zh.wikipedia.org/wiki/晋城">链接</a></div><p>晋城位于山西省东南部。</p></li>
</ol></body></html>''';
      final f = await _fakeServer((req, body) async {
        req.response.headers.contentType = ContentType.html;
        req.response.write(html);
        await req.response.close();
      });
      final r = await webSearch(
        provider: WebSearchProvider.bing,
        apiKey: '',
        query: '晋城',
        endpointOverride: 'http://127.0.0.1:${f.server.port}/search',
      );
      await f.server.close(force: true);

      expect(r, isNotEmpty, reason: '兜底至少要取到一条');
      expect(r.first.url, contains('zh.wikipedia.org'));
      expect(r.first.title, contains('晋城'));
    });

    test('DuckDuckGo lite：result-link 与 result-snippet 配对', () async {
      const html = '''
<html><body><table>
<tr><td><a class="result-link" href="https://example.com/a">甲</a></td></tr>
<tr><td class="result-snippet">甲的摘要</td></tr>
<tr><td><a class="result-link" href="https://example.com/b">乙</a></td></tr>
<tr><td class="result-snippet">乙的摘要</td></tr>
</table></body></html>''';
      final f = await _fakeServer((req, body) async {
        req.response.headers.contentType = ContentType.html;
        req.response.write(html);
        await req.response.close();
      });
      final r = await webSearch(
        provider: WebSearchProvider.duck,
        apiKey: '',
        query: 'x',
        endpointOverride: 'http://127.0.0.1:${f.server.port}/lite/',
      );
      await f.server.close(force: true);
      expect(r.length, 2);
      expect(r.first.title, '甲');
      expect(r.first.snippet, '甲的摘要');
      expect(r[1].url, 'https://example.com/b');
    });

    test('免费源不需要 Key 也照样能搜（needsKey=false）', () {
      expect(WebSearchProvider.bing.needsKey, isFalse);
      expect(WebSearchProvider.duck.needsKey, isFalse);
      expect(WebSearchProvider.tavily.needsKey, isTrue);
      expect(WebSearchProviderInfo.byId('bing'), WebSearchProvider.bing);
      expect(WebSearchProviderInfo.byId('不存在'), WebSearchProvider.off);
    });
  });

  group('出错与注入', () {
    test('非 2xx 时把厂商的原话带出来（401 / 429 修法不同）', () async {
      final f = await _fakeServer((req, body) async {
        req.response.statusCode = 429;
        req.response.write('{"error":"rate limit exceeded"}');
        await req.response.close();
      });
      Object? err;
      try {
        await webSearch(
          provider: WebSearchProvider.serper,
          apiKey: 'k',
          query: 'x',
          endpointOverride: 'http://127.0.0.1:${f.server.port}/search',
        );
      } catch (e) {
        err = e;
      }
      await f.server.close(force: true);
      expect(err, isA<WebSearchException>());
      expect('$err', contains('429'));
      expect('$err', contains('rate limit'));
    });

    test('没选厂家 / 空查询 → 不请求、直接返回空', () async {
      expect(
        await webSearch(
            provider: WebSearchProvider.off, apiKey: 'k', query: 'x'),
        isEmpty,
      );
      expect(
        await webSearch(
            provider: WebSearchProvider.bing, apiKey: '', query: '   '),
        isEmpty,
      );
    });

    test('formatSearchContext：带编号/来源，并且明确要求“别编”', () {
      final text = formatSearchContext(const <WebSearchResult>[
        WebSearchResult(
            title: '晋城', url: 'https://a/1', snippet: '山西省东南部'),
      ]);
      expect(text, contains('[1] 晋城'));
      expect(text, contains('https://a/1'));
      expect(text, contains('山西省东南部'));
      expect(text, contains('不要编造'));
      expect(formatSearchContext(const <WebSearchResult>[]), isEmpty);
    });

    test('超长摘要会截断（别把窗口吃光）', () {
      final long = '甲' * 900;
      final text = formatSearchContext(
        <WebSearchResult>[
          WebSearchResult(title: 't', url: 'u', snippet: long),
        ],
        maxSnippetChars: 100,
      );
      expect(text.contains('甲' * 101), isFalse);
      expect(text, contains('…'));
    });
  });

  group('免费源不该要 Key（真机 2026-10-09 反馈的 bug）', () {
    // 用户选了**免费的 Bing**、点 🔍，却被告知"还没填 Key"。
    //
    // 根因不在搜索本身，而在**调用方的门槛**：本地对话页当时**无条件**要求有 Key，
    // 根本不看 needsKey；而设置页是按 needsKey 判断的（对免费源连 Key 输入框都不
    // 显示）。于是用户在设置页找不到填的地方，却被要求去填。
    //
    // 这条规则现在只有一处实现（webSearchHasCredential），下面把它钉死。

    test('Bing / DuckDuckGo：没有 Key 也必须能查', () {
      for (final p in <WebSearchProvider>[
        WebSearchProvider.bing,
        WebSearchProvider.duck,
      ]) {
        expect(p.needsKey, isFalse, reason: '${p.id} 是免费源');
        expect(webSearchHasCredential(p, null), isTrue,
            reason: '${p.id} 没 Key 也该能查 —— 这就是用户碰到的那条');
        expect(webSearchHasCredential(p, ''), isTrue);
        expect(webSearchHasCredential(p, '   '), isTrue);
      }
    });

    test('要 Key 的厂家：没有 Key 就查不了（不能静默发一个空 Key 出去）', () {
      for (final p in <WebSearchProvider>[
        WebSearchProvider.tavily,
        WebSearchProvider.serper,
        WebSearchProvider.bocha,
        WebSearchProvider.deepseek,
      ]) {
        expect(p.needsKey, isTrue, reason: '${p.id} 要 Key');
        expect(webSearchHasCredential(p, null), isFalse);
        expect(webSearchHasCredential(p, ''), isFalse);
        expect(webSearchHasCredential(p, '   '), isFalse, reason: '空白不算填了');
        expect(webSearchHasCredential(p, 'sk-x'), isTrue);
      }
    });

    test('off 的 needsKey 也是 false —— 所以"能查"必须由调用方先拦掉 off', () {
      // 记录这个事实，免得以后有人把 needsKey 当成"能查"的同义词，
      // 那会把"还没选厂家"这一种状态放过去。
      expect(WebSearchProvider.off.needsKey, isFalse);
      expect(WebSearchProvider.off.id, 'off');
    });
  });
}
