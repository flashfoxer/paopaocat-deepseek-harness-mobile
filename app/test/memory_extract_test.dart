/// 「从会话里提炼记忆」的测试。
///
/// ## 这一组钉的是什么
///
/// 提炼这条链路有两个**会静默骗人**的失效方式：
///
///   1. **把"模型输出不是 JSON"读成"这段对话没有可记的"** —— 用户看到"0 条候选"，
///      以为一切正常，实际上这次根本没解析出来。所以 `parseMemoryExtraction` 必须
///      把 **空结果** 与 **失败** 分成两种状态，这里逐个钉。
///   2. **解析太脆**：模型爱在 JSON 前后加一句解释、爱套 ```json 围栏、爱把
///      importance 写成 9 或 "2"。这些都应该救回来，而不是整批丢掉。
///
/// ⚠️ 这里**没有**覆盖真机上的 `runtime.headless(...)`（那要真的起 node 进程 +
/// 一次真实模型调用，自动化测试里做不到）。覆盖到的是：提示词拼装、解析纯函数、
/// 以及"没有对话内容时**不 spawn 进程**就直接如实失败"这条短路。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/data/memory_extract.dart';
import 'package:dsh_mobile/data/memory_store.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/local/session_transcript.dart';

SessionTranscriptMessage _u(String t) =>
    SessionTranscriptMessage(role: 'user', text: t);
SessionTranscriptMessage _a(String t) =>
    SessionTranscriptMessage(role: 'assistant', text: t);

void main() {
  group('解析：宽容（能救回来的别丢）', () {
    test('标准输出：items 逐条收下，字段保真', () {
      final r = parseMemoryExtraction(
          '{"items":[{"text":"我是中文用户","kind":"identity","importance":1},'
          '{"text":"回答先给结论","kind":"preference","importance":2}]}');
      expect(r.ok, isTrue);
      expect(r.failure, isNull);
      expect(r.items.length, 2);
      expect(r.items[0].text, '我是中文用户');
      expect(r.items[0].kind, MemoryKind.identity);
      expect(r.items[0].importance, 1);
      expect(r.items[1].kind, MemoryKind.preference);
    });

    test('带 ```json 围栏 → 照样解析', () {
      final r = parseMemoryExtraction(
          '```json\n{"items":[{"text":"围栏里的","kind":"other","importance":2}]}\n```');
      expect(r.ok, isTrue);
      expect(r.items.single.text, '围栏里的');
    });

    test('前后带解释文字 → 从第一个 { 截到最后一个 }', () {
      final r = parseMemoryExtraction(
          '好的，我提炼出这些：\n{"items":[{"text":"夹缝里的"}]}\n以上。');
      expect(r.ok, isTrue);
      expect(r.items.single.text, '夹缝里的');
    });

    test('顶层直接是数组 → 也认', () {
      final r = parseMemoryExtraction('[{"text":"数组里的"}]');
      expect(r.ok, isTrue);
      expect(r.items.single.text, '数组里的');
    });

    test('字段越界：kind 认不出来 → other；importance 越界夹到 1..3', () {
      final r = parseMemoryExtraction(
          '{"items":[{"text":"a","kind":"不存在的分类","importance":9},'
          '{"text":"b","importance":0},'
          '{"text":"c","importance":"2"},'
          '{"text":"d"}]}');
      expect(r.ok, isTrue);
      expect(r.items.map((c) => c.kind).toList(),
          <MemoryKind>[MemoryKind.other, MemoryKind.other, MemoryKind.other, MemoryKind.other]);
      expect(r.items.map((c) => c.importance).toList(), <int>[3, 1, 2, 2]);
    });

    test('结构不完整的条目被丢掉并如实计数（但不影响这次成功）', () {
      final r = parseMemoryExtraction(
          '{"items":[{"text":"有效的"},{"kind":"identity"},"字符串",'
          '{"text":"   "},{"text":"也有效"}]}');
      expect(r.ok, isTrue);
      expect(r.items.map((c) => c.text).toList(), <String>['有效的', '也有效']);
      expect(r.dropped, 3);
    });

    test('成功但 0 条 与 失败 必须能区分', () {
      final empty = parseMemoryExtraction('{"items":[]}');
      expect(empty.ok, isTrue, reason: '"确实没什么可记的"是成功');
      expect(empty.items, isEmpty);
      expect(empty.failure, isNull);

      final bad = parseMemoryExtraction('这段对话里好像没什么值得记的。');
      expect(bad.ok, isFalse, reason: '解析不出来必须报失败，不能伪装成"0 条候选"');
      expect(bad.items, isEmpty);
      expect(bad.failure, isNotNull);
      expect(bad.raw, isNotNull, reason: '原始输出要留着，排障要看');
    });
  });

  group('解析：硬失败（绝不静默返回空列表）', () {
    test('完全不是 JSON → 失败，且原因里带原文片段', () {
      final r = parseMemoryExtraction('抱歉，我无法完成这个任务。');
      expect(r.ok, isFalse);
      expect(r.failure, contains('找不到 JSON'));
      expect(r.failure, contains('抱歉'));
    });

    test('空输出 → 失败', () {
      expect(parseMemoryExtraction('').ok, isFalse);
      expect(parseMemoryExtraction('   \n  ').ok, isFalse);
    });

    test('JSON 语法坏掉 → 失败（不是空成功）', () {
      final r = parseMemoryExtraction('{"items":[{"text":"没闭合"');
      expect(r.ok, isFalse);
      expect(r.items, isEmpty);
      expect(r.failure, isNotNull);
    });

    test('对象里没有 items 数组 → 失败', () {
      final r = parseMemoryExtraction('{"result":"啥也没有"}');
      expect(r.ok, isFalse);
      expect(r.failure, contains('items'));
    });

    test('items 不是数组 → 失败', () {
      final r = parseMemoryExtraction('{"items":"不是数组"}');
      expect(r.ok, isFalse);
      expect(r.failure, contains('items'));
    });
  });

  group('提示词拼装', () {
    test('带上角色、要求只输出 JSON、说明 0~5 条', () {
      final prompt = buildMemoryExtractPrompt(
        messages: <SessionTranscriptMessage>[_u('回答用中文'), _a('好')],
      );
      expect(prompt, contains('用户：回答用中文'));
      expect(prompt, contains('助手：好'));
      expect(prompt, contains('只输出 JSON'));
      expect(prompt, contains('0~5 条'));
      expect(prompt, contains('不要记流水账'));
      expect(prompt, contains('importance'));
    });

    test('已有记忆一起给模型去重', () {
      final prompt = buildMemoryExtractPrompt(
        messages: <SessionTranscriptMessage>[_u('随便说说')],
        existingTexts: <String>['我是中文用户', '先给结论'],
      );
      expect(prompt, contains('【已有记忆（不要重复）】'));
      expect(prompt, contains('我是中文用户'));
      expect(prompt, contains('不要重复'));
    });

    test('只取最近 30 条：更早的对话不进提示词', () {
      final messages = <SessionTranscriptMessage>[
        for (var i = 0; i < 40; i++) _u('第$i句'),
      ];
      final prompt = buildMemoryExtractPrompt(messages: messages);
      expect(prompt, contains('第39句'));
      expect(prompt, isNot(contains('第9句')),
          reason: '超过 30 条的旧对话应该被丢掉（只保留最近 30 条）');
    });

    test('超长单条被截断（不会把一段巨长输出整个塞进去）', () {
      final prompt = buildMemoryExtractPrompt(
        messages: <SessionTranscriptMessage>[_u('长' * 5000)],
      );
      expect(prompt.length, lessThan(4000));
      expect(prompt, contains('后文略'));
    });

    test('notice（App 侧的失败提示）不算对话内容，不进提示词', () {
      final prompt = buildMemoryExtractPrompt(messages: <SessionTranscriptMessage>[
        const SessionTranscriptMessage(role: 'notice', text: '这次没回上来：超时'),
        _u('真正的问题'),
      ]);
      expect(prompt, contains('真正的问题'));
      expect(prompt, isNot(contains('这次没回上来')));
    });
  });

  group('extractMemoryCandidates 的短路（不起进程）', () {
    test('没有对话内容 → 如实失败，而不是"0 条候选"', () async {
      final r = await extractMemoryCandidates(
        runtime: DshRuntime(<String, dynamic>{}),
        messages: const <SessionTranscriptMessage>[],
      );
      expect(r.ok, isFalse);
      expect(r.failure, contains('没有可提炼的对话内容'));
    });

    test('只有 notice 消息 → 同样如实失败', () async {
      final r = await extractMemoryCandidates(
        runtime: DshRuntime(<String, dynamic>{}),
        messages: <SessionTranscriptMessage>[
          const SessionTranscriptMessage(role: 'notice', text: '没回上来'),
        ],
      );
      expect(r.ok, isFalse);
    });
  });
}
