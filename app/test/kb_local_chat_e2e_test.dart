/// 知识库在「本地对话」里的**端到端**证据。
///
/// ## 为什么非有不可（用户 2026-10-11：「测试一下知识库在本地大模型的应用情况」）
///
/// 这条链上有三段，每段各自都有测试：
///   ① `kb_index.dart` —— 建索引 / 检索（`kb_index_test.dart`）；
///   ② `local_chat.dart` —— 把消息拼成 OpenAI 形状发出去（`local_chat_test.dart`）；
///   ③ 页面里把 ① 的结果塞进 ② 的 `LocalChatMessage.context`。
///
/// 但**没有一条测试证明它们真的接在一起**：中间任何一段"忘了传"都不会报错，
/// 表现只是"回答没用到知识库"（而界面上还会老老实实显示"知识库 N 段"）——
/// 这正是最难发现的那种坏。本文件把 ①→②→③ 整条跑一遍，断言
/// **知识库原文真的出现在发给引擎的请求正文里**。
///
/// 口径说明：这里不假装"模型一定会照资料回答"（那是模型行为，不是 App 能保证的）；
/// 只证明 App 把资料**送到了**引擎手里。
///
/// ⚠️ 2026-10-12 追加（用户：「本地大模型调用知识库是没什么效用的，感觉回答得乱七八糟」）：
/// 送得到 ≠ 送得对。那次抓到两个真问题 ——
///   ① 检索侧：`chunkText` 不按文档边界切，一块里塞 9 篇无关文档（见 `kb_index_test.dart`
///      的「文档边界」那组）；
///   ② 组装侧：旧轮材料永远重发 + 没有 system 位（见本文件下面两个测试）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/local/kb_index.dart';
import 'package:dsh_mobile/local/local_chat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('知识库检索 → 上下文 → 真的进了发给引擎的那条请求', () async {
    final dir = Directory.systemTemp.createTempSync('kb-e2e-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    // ① 一份"只有本机资料里才有"的小语料（用一个别处不可能出现的暗号）。
    const secret = '七号晾衣绳';
    final src = File('${dir.path}/doc.json');
    src.writeAsStringSync(jsonEncode(<Object>[
      <String, String>{
        'completion': '泡泡猫的出厂暗号是"$secret"，只有本机资料里写了这一句。',
      },
      <String, String>{
        'completion': '无关段落：昭通机场（ZPZT）位于中国云南昭通。',
      },
    ]));

    // ② 真建索引、真检索（不是打桩 —— 打桩就测不出"建索引坏了"）。
    final built = await KbIndexer.build(
        sourcePath: src.path, outDir: '${dir.path}/idx');
    expect(built.cancelled, isFalse);
    expect(built.chunks, greaterThan(0), reason: '一段都没切出来');

    final ret = await KbRetriever.open('${dir.path}/idx');
    expect(ret, isNotNull, reason: '刚建好的索引打不开 —— 第一段就断了');
    final hits = await ret!.search('泡泡猫的出厂暗号是什么', topK: 3);
    expect(hits, isNotEmpty, reason: '检索一条都没命中 —— 第一段就断了');
    expect(hits.first.text, contains(secret));

    final ctx = formatKbContext(hits);
    expect(ctx, contains(secret), reason: '拼出来的上下文里没有资料原文');
    expect(ctx, contains('不要编造'), reason: '缺"别编"的要求，模型容易自己编');

    // ③ 起一个假引擎，把收到的请求正文原样记下来。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    Map<String, dynamic>? seen;
    server.listen((req) async {
      seen = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      req.response.write(
          'data: {"choices":[{"delta":{"content":"$secret"},"finish_reason":null}]}\n\n');
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
    });

    final got = await localChatStream(
      port: server.port,
      history: <LocalChatMessage>[
        LocalChatMessage(
          role: 'user',
          text: '泡泡猫的出厂暗号是什么',
          context: ctx,
          kbHits: hits.length,
        ),
      ],
    ).toList();

    expect(got.join(), secret, reason: '流式解析把回答读坏了');

    expect(seen, isNotNull, reason: '引擎根本没收到请求');
    final body = jsonEncode(seen);
    // ★ 这条就是本文件存在的理由：资料原文必须真的在**请求正文**里。
    expect(body, contains(secret),
        reason: '知识库那一段没进请求 —— 界面上显示的"用了知识库"就是假的');
    expect(body, contains('不要编造'));
    expect(seen!['stream'], isTrue);

    // ⚠️ 契约变更（2026-10-12）：这条原来是 `isNot(contains('"system"'))`
    //    ——「简单对话的定义：一条 system 都不许有」。
    //    现在**有材料时必须有一条 system**，理由见 `local_chat.dart` 里的三坑说明：
    //    `formatKbContext` 那句"请优先依据它们回答 / 不要编造"以前粘在用户消息里，
    //    小模型对系统位指令的遵守度明显更高。
    //    下面两条把新契约钉死：**有材料 → 恰好一条 system；没材料 → 一条都没有**
    //    （后者见下一个测试，仍然不许带 system）。
    final msgs = seen!['messages'] as List;
    expect(msgs.where((m) => (m as Map)['role'] == 'system').length, 1,
        reason: '有检索材料时应当恰好一条 system 消息（放"依据资料回答"的要求）');
    expect((msgs.first as Map)['role'], 'system',
        reason: 'system 必须在最前面 —— 引擎按数组顺序喂给模型');
    expect((msgs.first as Map)['content'], contains('依据'),
        reason: 'system 里要写清"依据资料回答"，否则等于没放');
    // 材料本身仍在**用户**消息里（这是本文件存在的理由，不能被 system 换掉）。
    final userMsg = msgs.lastWhere((m) => (m as Map)['role'] == 'user') as Map;
    expect(userMsg['content'], contains(secret));

    // 有材料 → 降温度、提上限（读完材料还得有额度写答案）。
    expect(seen!['temperature'], lessThan(0.7),
        reason: '照资料回答时温度不能还是 0.7（小模型会顺着材料编）');
    expect(seen!['max_tokens'], greaterThan(512),
        reason: '512 会被"读材料"吃掉，答案写不完就被截断');
  });

  test('历史里**旧轮**的检索材料不许重发（这是"乱七八糟"的另一半）', () async {
    // 坑：`contentOf` 会把 `context` 拼回消息，而 `history` 是整段会话 ——
    // 问第 3 句时，前两句各自的"以下是知识库查到的资料，请优先依据它们回答"
    // 还全在上下文里，而且讲的是**别的**问题。1B 级模型被几坨互相矛盾的
    // "优先依据"一冲就是"乱七八糟"。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    Map<String, dynamic>? seen;
    server.listen((req) async {
      seen = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
    });

    await localChatStream(
      port: server.port,
      history: const <LocalChatMessage>[
        LocalChatMessage(role: 'user', text: '第一问', context: '旧材料暗号甲'),
        LocalChatMessage(role: 'model', text: '第一答'),
        LocalChatMessage(role: 'user', text: '第二问', context: '新材料暗号乙'),
      ],
    ).toList();

    final body = jsonEncode(seen);
    expect(body, contains('新材料暗号乙'), reason: '本轮的材料必须发');
    expect(body, isNot(contains('旧材料暗号甲')),
        reason: '上一轮的材料被重发了 —— 模型会拿上一问的资料答这一问');
    expect(body, contains('第一问'), reason: '历史对话本身要留着（丢的只是旧材料）');
    expect(body, contains('第一答'));
  });

  test('没开知识库（context 为空）时，请求正文里不该多出任何东西', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    Map<String, dynamic>? seen;
    server.listen((req) async {
      seen = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
    });

    await localChatStream(
      port: server.port,
      history: <LocalChatMessage>[
        const LocalChatMessage(role: 'user', text: '随便聊聊'),
      ],
    ).toList();

    final msgs = seen!['messages'] as List;
    expect((msgs.single as Map)['content'], '随便聊聊',
        reason: '没有资料时不该往正文里塞任何前缀/包装');
  });
}
