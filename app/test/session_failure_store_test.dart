// 会话丢失修复单 · 缺陷 C（失败不进会话）
//
// 实测标本 `c6a74bd7`：转录里 5 条全是 `user/message`（1 条真实提问 + 4 条系统注入），
// `assistant/message` **0 条**，也没有任何错误事件；原因（`Connection error`）
// 只在诊断日志里。用户重新打开这条会话，看到的就是"我发了话、什么都没有"。
//
// 写入方是运行时（node DSH，不在本仓库），所以 App 侧的修法是：
//   失败时记一份本地账本 → 回放时合并成一条 `notice`（"没有回答" + 原因）。
//
// 这个测试钉住三件事：
//   ① 账本读得回来、**同一会话只留最新一条**、有上限；
//   ② 合并规则只在"最后一条是用户消息"时生效（否则会挂一条过期的失败提示）；
//   ③ 失败发生在会话创建之前时**不合并**（防跨会话串 id）。
//
// 如实说明边界：这不是写进 DSH 转录的事件 —— 换设备/重装就没了，
// 命令行直接读转录也看不到。要做成"转录里就有"，得改 dsh-acp 的落盘（上游）。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/local/session_failure_store.dart';
import 'package:dsh_mobile/local/session_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late DshRuntime runtime;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsh-failure-');
    runtime = DshRuntime(<String, dynamic>{
      'filesDir': tmp.path,
      'nodeHome': '${tmp.path}/dshhome',
    });
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  SessionTranscriptMessage msg(String role, String text) =>
      SessionTranscriptMessage(role: role, text: text);

  group('失败账本', () {
    test('记了就读得回来；同一会话再失败一次只留最新那条', () async {
      await recordSessionFailure(
          runtime: runtime,
          sessionId: 's-1',
          friendly: '连不上模型服务。',
          detail: 'Connection error');
      var rec = readSessionFailure(runtime: runtime, sessionId: 's-1');
      expect(rec, isNotNull);
      expect(rec!.friendly, '连不上模型服务。');
      expect(rec.detail, 'Connection error');

      await recordSessionFailure(
          runtime: runtime,
          sessionId: 's-1',
          friendly: '这次是超时。',
          detail: null);
      rec = readSessionFailure(runtime: runtime, sessionId: 's-1');
      expect(rec!.friendly, '这次是超时。');
      expect(rec.detail, isNull);

      // 账本文件是给人排查也能看的明文 JSON（不是二进制）
      final f = File('${tmp.path}/session_failures.json');
      expect(f.existsSync(), isTrue);
      final raw = jsonDecode(f.readAsStringSync()) as Map;
      expect((raw['items'] as Map).keys, ['s-1']);
    });

    test('成功一次就擦掉 —— 免得回放里挂着一条过期的"没回答"', () async {
      await recordSessionFailure(
          runtime: runtime, sessionId: 's-2', friendly: '失败了');
      expect(readSessionFailure(runtime: runtime, sessionId: 's-2'), isNotNull);
      await clearSessionFailure(runtime: runtime, sessionId: 's-2');
      expect(readSessionFailure(runtime: runtime, sessionId: 's-2'), isNull);
      // 擦一条不影响别的
      await recordSessionFailure(
          runtime: runtime, sessionId: 's-3', friendly: '失败了');
      await clearSessionFailure(runtime: runtime, sessionId: 's-2');
      expect(readSessionFailure(runtime: runtime, sessionId: 's-3'), isNotNull);
    });

    test('账本有上限：超过 $kMaxFailureRecords 条丢最旧的（文件不许无限长大）',
        () async {
      for (var i = 0; i < kMaxFailureRecords + 5; i++) {
        await recordSessionFailure(
            runtime: runtime, sessionId: 's-$i', friendly: '失败 $i');
      }
      final raw = jsonDecode(
              File('${tmp.path}/session_failures.json').readAsStringSync())
          as Map;
      expect((raw['items'] as Map).length, kMaxFailureRecords);
      // 丢的是最旧的几条，最新的那几条还在
      expect(readSessionFailure(runtime: runtime, sessionId: 's-0'), isNull);
      expect(
          readSessionFailure(
              runtime: runtime, sessionId: 's-${kMaxFailureRecords + 4}'),
          isNotNull);
    });

    test('会话 id 为空时不写账本（不该有这种 key）', () async {
      await recordSessionFailure(runtime: runtime, sessionId: '  ', friendly: 'x');
      expect(File('${tmp.path}/session_failures.json').existsSync(), isFalse);
    });
  });

  group('回放时合并成"没有回答"（缺陷 C 的另一半）', () {
    final failure = SessionFailureRecord(
      at: DateTime(2026, 10, 14, 23, 6).millisecondsSinceEpoch,
      friendly: '连不上模型服务，这条没能回上来。',
      detail: 'Connection error',
    );
    final createdAt = DateTime(2026, 10, 14, 23, 5);

    test('最后一条是用户消息 → 末尾挂一条 notice（这就是用户看到的"没有回答"）', () {
      final messages = <SessionTranscriptMessage>[
        msg('user', '请阅读这个文件'),
      ];
      mergeFailureNotice(messages, failure, createdAt);
      expect(messages.length, 2);
      expect(messages.last.isNotice, isTrue);
      expect(messages.last.isUser, isFalse);
      expect(messages.last.text, '连不上模型服务，这条没能回上来。');
      expect(messages.last.detail, 'Connection error');
    });

    test('最后一条是助手消息 → 不合并（后面成功过了，别挂过期提示）', () {
      final messages = <SessionTranscriptMessage>[
        msg('user', '你好'),
        msg('assistant', '在的'),
      ];
      mergeFailureNotice(messages, failure, createdAt);
      expect(messages.length, 2);
      expect(messages.any((m) => m.isNotice), isFalse);
    });

    test('没有失败记录 → 什么都不加', () {
      final messages = <SessionTranscriptMessage>[msg('user', '你好')];
      mergeFailureNotice(messages, null, createdAt);
      expect(messages.length, 1);
    });

    test('空转录 → 不加（没有"上一轮"可挂）', () {
      final messages = <SessionTranscriptMessage>[];
      mergeFailureNotice(messages, failure, createdAt);
      expect(messages, isEmpty);
    });

    test('失败时间早于会话创建时间 → 不合并（串了 id 的极端情况）', () {
      final messages = <SessionTranscriptMessage>[msg('user', '你好')];
      final stale = SessionFailureRecord(
        at: DateTime(2026, 10, 1).millisecondsSinceEpoch,
        friendly: '很旧的失败',
      );
      mergeFailureNotice(messages, stale, createdAt);
      expect(messages.length, 1);
    });
  });
}
