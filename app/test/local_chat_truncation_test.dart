/// 「回答被长度上限截断」必须说出来（用户 2026-10-12 排查时发现）。
///
/// ## 为什么非有不可
///
/// 真机报告里有一轮：`生成完成：首字 2617ms · **768 段** · 26.7 段/s` ——
/// 768 正好等于 `groundedMaxTokens`。也就是说那一轮**不是答完了**，
/// 是被 `max_tokens` 砍掉的。
///
/// 而 `localChatStream` 原来只检查"流里有没有 `finish_reason`"（半截就报错），
/// **不检查 `finish_reason == 'length'`** —— 于是被砍的回答被当成完整回答
/// 存进会话、落盘，界面上一个字都不说。用户看到的只是"句子说到一半没了"，
/// 跟"答得乱七八糟"长得一模一样。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/local/local_chat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 起一个假引擎，把给定的 SSE 行原样吐回来。
  Future<HttpServer> fakeEngine(List<String> sseLines) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await utf8.decoder.bind(req).join(); // 请求体读掉再回话
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      for (final l in sseLines) {
        req.response.write('$l\n\n');
      }
      await req.response.close();
    });
    return server;
  }

  Future<String> drain(HttpServer server, List<String> notices) async {
    final buf = StringBuffer();
    await for (final p in localChatStream(
      port: server.port,
      history: <LocalChatMessage>[
        const LocalChatMessage(role: 'user', text: '你好'),
      ],
      notices: notices,
    )) {
      buf.write(p);
    }
    return buf.toString();
  }

  test('finish_reason=length → notices 记上 length，且已吐出的正文不许丢', () async {
    final server = await fakeEngine(<String>[
      'data: {"choices":[{"delta":{"content":"这段话还没写完"},"finish_reason":null}]}',
      'data: {"choices":[{"delta":{},"finish_reason":"length"}]}',
      'data: [DONE]',
    ]);
    addTearDown(() => server.close(force: true));

    final notices = <String>[];
    final text = await drain(server, notices);
    expect(text, '这段话还没写完', reason: '被截断的正文不许丢');
    expect(notices, contains('length'),
        reason: '被截断了却当成功处理 —— 用户只会看到"话说一半没了"');
  });

  test('finish_reason=stop → 不许误报截断', () async {
    final server = await fakeEngine(<String>[
      'data: {"choices":[{"delta":{"content":"答完了"},"finish_reason":null}]}',
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}',
      'data: [DONE]',
    ]);
    addTearDown(() => server.close(force: true));

    final notices = <String>[];
    await drain(server, notices);
    expect(notices, isEmpty,
        reason: '正常答完却报"被截断"，会让用户以为功能坏了');
  });

  test('截断标记跟着消息落盘 / 读回来 —— 刷新之后提示还在', () {
    const m = LocalChatMessage(role: 'model', text: '半截话', truncated: true);
    final back = LocalChatMessage.fromJson(m.toJson());
    expect(back, isNotNull);
    expect(back!.truncated, isTrue, reason: '刷新后截断提示就没了');

    final ok = LocalChatMessage.fromJson(
        const LocalChatMessage(role: 'model', text: '完整回答').toJson());
    expect(ok, isNotNull);
    expect(ok!.truncated, isFalse, reason: '完整回答被标成截断');
  });

  test('界面确实会把这个标记显示出来（防"记了不说"）', () {
    // 为什么读源码：这条要证明的是"页面用了 truncated"，没有可断言的返回值；
    // 而"记下来了但界面不说"正是这次要修的那个洞。
    final src = File('lib/ui/pages/local_chat_page.dart').readAsStringSync();
    expect(src.contains('truncated: notices.contains'), isTrue,
        reason: '流里的截断事件没被接到消息上');
    expect(src.contains('if (m.truncated)'), isTrue,
        reason: '消息带了这个标记，界面却不显示 —— 等于没修');
  });
}
