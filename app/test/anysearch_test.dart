// 「会话联网搜索」= **AnySearch**（用户 2026-10-15 选定 B 方案）。
//
// 这个测试钉住的是**最容易悄悄坏掉、而且坏了在真机上很难看明白**的几件事：
//
//   ① **ACP 的 mcpServers 形状**：`dsh-acp` 会逐条校验（`type:'http'`、url 必须是
//      http(s)、headers 是**有序的 name/value 条目**）。写错不是"搜索不能用"，
//      而是整个 `session/new` 被拒 —— 会话根本开不起来。所以形状必须被单测咬住。
//   ② **匿名可用**：没有 Key 时**不许**发一个空的 `Authorization`（那等于自报"我有凭据
//      但无效"）。这条对应"不用填 Key 也能搜"的产品口径。
//   ③ **失败要如实**：上游返回非 200 / 不是 JSON 时，设置页必须能拿到人话，
//      而不是抛异常或者假装成功。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/data/anysearch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ACP 的 mcpServers 条目（形状写错 = 整个会话请求被拒）', () {
    test('匿名：只有一个 http 服务器，且**不带** Authorization', () {
      final servers = AnySearch.mcpServers();
      expect(servers.length, 1);
      final s = servers.single;
      expect(s['name'], AnySearch.serverName);
      expect(s['type'], 'http');
      expect(s['url'], AnySearch.mcpUrl);
      expect(s['url'].toString().startsWith('https://'), isTrue,
          reason: 'ACP 会 assertHttpUrl，非 http(s) 直接拒');

      final headers = (s['headers'] as List).cast<Map<String, String>>();
      expect(headers.map((h) => h['name']), contains(AnySearch.clientHeaderName));
      expect(headers.any((h) => h['name'] == 'Authorization'), isFalse,
          reason: '没 Key 就不能发 Authorization —— 否则等于自报一个无效凭据');
    });

    test('带 Key：多一条 Bearer，且客户端头仍在', () {
      final servers = AnySearch.mcpServers(apiKey: '  as_sk_test  ');
      final headers =
          (servers.single['headers'] as List).cast<Map<String, String>>();
      final auth = headers.firstWhere((h) => h['name'] == 'Authorization');
      expect(auth['value'], 'Bearer as_sk_test',
          reason: '前后空格要去掉（用户从网页复制经常带空格）');
      expect(headers.first['name'], AnySearch.clientHeaderName,
          reason: '客户端头永远在第一位');
    });

    test('空白 Key 等于没 Key（别把一个空串当凭据发出去）', () {
      for (final v in <String?>[null, '', '   ']) {
        final servers = AnySearch.mcpServers(apiKey: v);
        final headers =
            (servers.single['headers'] as List).cast<Map<String, String>>();
        expect(headers.any((h) => h['name'] == 'Authorization'), isFalse,
            reason: 'key=$v 不该产生 Authorization');
      }
    });
  });

  group('响应解析（形状：{code, data:{results:[…]}}）', () {
    test('正常：数得出来', () {
      expect(
        AnySearch.countResults(
            '{"code":0,"data":{"results":[{"title":"a"},{"title":"b"}]}}'),
        2,
      );
    });

    test('怪形状一律返回 -1（宁可说"认不出来"，也不假装成功）', () {
      for (final body in <String>[
        'not json',
        '[]',
        '{"data":{}}',
        '{"data":{"results":"nope"}}',
        '{"code":0}',
      ]) {
        expect(AnySearch.countResults(body), -1, reason: 'body=$body');
      }
    });

    test('renderResults 出 Markdown 链接（引用卡片/正文都用它）', () {
      final html = AnySearch.renderResults(jsonEncode(<String, Object?>{
        'data': <String, Object?>{
          'results': <Object?>[
            <String, Object?>{
              'title': '标题',
              'url': 'https://example.com/a',
              'snippet': '摘要',
            },
          ],
        },
      }));
      expect(html, contains('[标题](https://example.com/a)'));
      expect(html, contains('摘要'));
    });
  });

  group('「测一下」（对着本地假服务，不碰真上游）', () {
    late HttpServer server;
    late String base;
    int status = 200;
    String body = '{"code":0,"data":{"results":[{"title":"x"}]}}';
    final seen = <String, String>{};

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}/v1/search';
      server.listen((req) async {
        await utf8.decoder.bind(req).join();
        seen.clear();
        req.headers.forEach((k, v) => seen[k.toLowerCase()] = v.join(','));
        req.response.statusCode = status;
        req.response.headers.contentType = ContentType.json;
        req.response.write(body);
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('匿名也能通，并报出结果条数', () async {
      final r = await AnySearch.testConnection(baseOverride: base);
      expect(r.ok, isTrue);
      expect(r.results, 1);
      expect(seen['x-anysearch-client'], AnySearch.clientHeaderValue);
      expect(seen.containsKey('authorization'), isFalse);
    });

    test('带 Key 时发 Bearer（大小写不敏感地出现在请求头里）', () async {
      await AnySearch.testConnection(apiKey: 'as_sk_x', baseOverride: base);
      expect(seen['authorization'], 'Bearer as_sk_x');
    });

    test('上游 429 → 如实报错，不当成功', () async {
      status = 429;
      body = '{"message":"rate limited"}';
      final r = await AnySearch.testConnection(baseOverride: base);
      expect(r.ok, isFalse);
      expect(r.error, contains('429'));
    });

    test('连不上 → 如实报错（不抛异常给界面）', () async {
      await server.close(force: true);
      final r = await AnySearch.testConnection(baseOverride: base);
      expect(r.ok, isFalse);
      expect(r.error, isNotNull);
    });
  });

  group('身份常量（改错会让"两处填 Key 互不相认"重演）', () {
    test('Key 的存储 id 与端侧对话 🔍 那套同一个命名空间', () {
      expect(AnySearch.keyStorageId, startsWith('search-'),
          reason: '与 local/web_search.dart 的 searchKeyId() 同口径');
      expect(AnySearch.serverName, isNotEmpty);
      expect(AnySearch.mcpUrl, endsWith('/mcp'));
      expect(AnySearch.searchUrl, endsWith('/v1/search'));
    });
  });
}
