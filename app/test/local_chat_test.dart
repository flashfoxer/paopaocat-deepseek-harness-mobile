/// 「本地对话（简单对话）」的回归测试。
///
/// 这里锁住三件**一旦坏掉就悄悄坏掉**的事：
///
///   1. **不带系统提示、不带历史快照** —— 这是"简单对话"与"会话里当 Agent"的
///      分界线，也是用户 2026-10-09 定的口径。它要是被谁顺手加回去，界面上看不出来，
///      只有模型又开始吐乱码才会被发现。
///   2. **SSE 逐段解析**，且引擎偶尔插的非 JSON 行不能打断整段回答。
///   3. **引擎的报错原样抛出** —— 判断"某种模型构建能不能用"就靠这句话。
///   4. **引擎报错里认得出来的那几类能被认出来**（`classifyLocalChatError`）——
///      真机 2026-10-09 的 Status 9 就是这样被翻成人话的；认不出来的必须**原样**吐出去，
///      不许猜（猜错的提示比不提示更糟）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/local/local_chat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('简单对话的落盘', () {
    test('存 → 读 → 清，三步都对（离开页面再回来不该丢）', () async {
      final dir = await Directory.systemTemp.createTemp('local_chat_');
      final store = LocalChatStore(dshHome: dir.path);
      await store.save(<LocalChatMessage>[
        const LocalChatMessage(role: 'user', text: '你好'),
        const LocalChatMessage(role: 'model', text: '你好呀'),
      ]);
      final back = await store.load();
      expect(back.map((m) => m.text).toList(), <String>['你好', '你好呀']);
      expect(back.first.isUser, isTrue);
      expect(back.last.isUser, isFalse);
      await store.clear();
      expect(await store.load(), isEmpty);
    });

    test('磁盘上写坏了，也不能让整段历史读不出来', () async {
      final dir = await Directory.systemTemp.createTemp('local_chat_');
      File('${dir.path}/local_chat.json').writeAsStringSync(
          '[{"role":"user","text":"ok"},{"role":"x"},7,{"role":"model","text":"好"}]');
      final back = await LocalChatStore(dshHome: dir.path).load();
      expect(back.map((m) => m.text).toList(), <String>['ok', '好']);
    });
  });

  group('流式请求与解析（真起一个本机 HTTP 服务端）', () {
    test('请求里**没有系统消息**：只有 user，且 stream=true', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      Map<String, dynamic>? seen;
      server.listen((req) async {
        seen = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });

      await localChatStream(
        port: server.port,
        history: <LocalChatMessage>[
          const LocalChatMessage(role: 'user', text: '第一句'),
          const LocalChatMessage(role: 'model', text: '回一句'),
          const LocalChatMessage(role: 'user', text: '第二句'),
        ],
      ).toList();
      await server.close(force: true);

      expect(seen, isNotNull);
      expect(seen!['stream'], isTrue);
      final msgs = seen!['messages'] as List;
      // ⚠️ 一条 system 都不许有 —— 这条断言就是"简单对话"的定义。
      expect(jsonEncode(msgs), isNot(contains('system')));
      expect(msgs.length, 3);
      expect((msgs.first as Map)['role'], 'user');
      expect((msgs[1] as Map)['role'], 'assistant');
      expect((msgs[1] as Map)['content'], '回一句');
    });

    test('逐段吐增量；引擎插的非 JSON 行不打断整段回答', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        req.response.write('data: {"choices":[{"delta":{"content":"你"}}]}\n\n');
        req.response.write('data: {"choices":[{"delta":{"content":"好"}}]}\n\n');
        req.response.write('data: 这一行不是 JSON（引擎偶尔会插）\n\n');
        req.response.write('data: {"timings":{"approx":true}}\n\n');
        req.response.write('data: {"choices":[{"delta":{"content":"呀"}}]}\n\n');
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });

      final got = <String>[];
      await for (final p in localChatStream(
        port: server.port,
        history: <LocalChatMessage>[
          const LocalChatMessage(role: 'user', text: '嗨'),
        ],
      )) {
        got.add(p);
      }
      await server.close(force: true);
      expect(got.join(), '你好呀');
    });

    test('带图片的消息发 content 数组（data: 内联），并且仍然不带 system', () async {
      final dir = await Directory.systemTemp.createTemp('local_chat_img_');
      final img = File('${dir.path}/a.png')..writeAsBytesSync(const <int>[1, 2, 3, 4]);
      Map<String, dynamic>? seen;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        seen = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });

      await localChatStream(
        port: server.port,
        history: <LocalChatMessage>[
          LocalChatMessage(role: 'user', text: '这是什么？', images: <String>[img.path]),
        ],
      ).toList();
      await server.close(force: true);

      final msgs = seen!['messages'] as List;
      final content = (msgs.first as Map)['content'] as List;
      // 第一段是文字，第二段是按内联 data URL 传的图片。
      expect((content.first as Map)['type'], 'text');
      final url = ((content[1] as Map)['image_url'] as Map)['url'] as String;
      expect(url.startsWith('data:image/png;base64,'), isTrue);
      expect(jsonEncode(msgs), isNot(contains('system')));
    });

    test('图片文件不在 → 退回纯文本那条路（不因为一张图废掉整轮）', () async {
      Map<String, dynamic>? seen;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        seen = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });

      await localChatStream(
        port: server.port,
        history: <LocalChatMessage>[
          const LocalChatMessage(
              role: 'user', text: '还在吗', images: <String>['/definitely/not/here.png']),
        ],
      ).toList();
      await server.close(force: true);

      final content = ((seen!['messages'] as List).first as Map)['content'];
      expect(content, isA<String>()); // 纯文本，不是数组
      expect(content, '还在吗');
    });

    test('非 200 时把引擎的原文抛出来（不加工、不翻译）', () async {      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.statusCode = 500;
        req.response.write(
            'inference failed: Failed to apply template: invalid operation '
            '(in template:16)');
        await req.response.close();
      });

      Object? err;
      try {
        await localChatStream(
          port: server.port,
          history: <LocalChatMessage>[
            const LocalChatMessage(role: 'user', text: 'x'),
          ],
        ).toList();
      } catch (e) {
        err = e;
      }
      await server.close(force: true);

      expect(err, isA<LocalChatException>());
      expect('$err', contains('in template:16'));
      expect('$err', contains('HTTP 500'));
    });

    // ── P0-10：半截回复绝不能当成完整回答 ────────────────────────────────────
    //
    // 后果链：native 抛 Error（属 Error 不属 Exception）→ 穿透桥的 catch →
    // socket 被关 → 这里 `await for` 看到"流正常结束" → 半截内容被存成完整回答。
    // 桥那边已经改成 catch Throwable（不再让 Error 穿过去）；这一组守的是
    // **即使流真的断了，我们也不会把它当成答完**。

    test('流在没有 finish_reason 的情况下结束 → 必须报错（半截）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        // 吐了半句话，然后**直接断开**，不发 finish_reason、不发 [DONE]。
        req.response.write('data: {"choices":[{"delta":{"content":"半截"}}]}\n\n');
        await req.response.flush();
        await req.response.close();
      });

      final got = <String>[];
      Object? err;
      try {
        await for (final p in localChatStream(
          port: server.port,
          history: <LocalChatMessage>[
            const LocalChatMessage(role: 'user', text: '说一下晋城'),
          ],
        )) {
          got.add(p);
        }
      } catch (e) {
        err = e;
      }
      await server.close(force: true);

      // 已经吐出来的部分**不撤回**（用户至少能看到），但必须报错。
      expect(got.join(), '半截');
      expect(err, isA<LocalChatException>(),
          reason: '流没以 finish_reason 收尾却被当成完整回答 —— 半截回复落盘了');
      expect('$err', contains('finish_reason'));
    });

    test('收尾分片（delta 空 + finish_reason）算正常结束，且不重复追加正文', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.write('data: {"choices":[{"delta":{"content":"完"}}]}\n\n');
        // 桥真实发的收尾分片形状（LiteRtLmBridge.writeTimingsChunk）
        req.response.write(
            'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"timings":{"x":1}}\n\n');
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });

      final got = <String>[];
      Object? err;
      try {
        await for (final p in localChatStream(
          port: server.port,
          history: <LocalChatMessage>[
            const LocalChatMessage(role: 'user', text: '嗨'),
          ],
        )) {
          got.add(p);
        }
      } catch (e) {
        err = e;
      }
      await server.close(force: true);

      expect(err, isNull, reason: '带 finish_reason 的正常收尾不该报错');
      expect(got.join(), '完', reason: '收尾分片的空 delta 不该被当成正文追加');
    });

    test('只有 [DONE] 没有 finish_reason 也算收尾（两种收尾标记都认）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.write('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n');
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });
      Object? err;
      try {
        await localChatStream(
          port: server.port,
          history: <LocalChatMessage>[
            const LocalChatMessage(role: 'user', text: '嗨'),
          ],
        ).toList();
      } catch (e) {
        err = e;
      }
      await server.close(force: true);
      expect(err, isNull);
    });
  });

  group('引擎报错的归类（真机 Status 9 的现场）', () {
    // 真机原话（2026-10-09 诊断报告 16:32:35，Gemma 3 1B，文件名带 ekv4096）：
    //   Status Code: 9. Message: Prefill input length exceeds available state
    //   entries (remaining capacity: 176).
    // 当时用户只看到一句 `HTTP 500 {…}`，只能来问"这是什么意思"。
    const String realDevice =
        'HTTP 500 {"error":{"message":"推理失败：Status Code: 9. '
        'Message: Prefill input length exceeds available state entries '
        '(remaining capacity: 176).","type":"invalid_request_error"}}';

    test('会话缓存满 → 认出来（这才是能给出"下一步"的那一类）', () {
      expect(classifyLocalChatError(realDevice), LocalChatErrorKind.contextFull);
    });

    test('措辞变了也能认（引擎改字不该让这个判断失效）', () {
      for (final s in <String>[
        'Prefill input length exceeds available state entries',
        'prefill input length exceeds',
        'available state entries',
        'remaining capacity: 12',
      ]) {
        expect(classifyLocalChatError(s), LocalChatErrorKind.contextFull,
            reason: '认不出来：$s');
      }
    });

    test('别的错一律归 unknown —— **不许猜**', () {
      for (final s in <String>[
        'HTTP 401 unauthorized',
        'Connection refused',
        'Conversation roles must alternate',
        '模板没找到：in template:16',
        '',
      ]) {
        expect(classifyLocalChatError(s), LocalChatErrorKind.unknown,
            reason: '这不该被归成缓存满：$s');
      }
    });
  });
}
