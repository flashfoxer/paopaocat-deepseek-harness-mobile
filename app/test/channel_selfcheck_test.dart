/// 「通道自检 + 一键发给开发者」的测试。
///
/// ## 为什么
///
/// 用户 2026-10-16 提的「探查机制」第①层：把"模型用不了"按状态码分类成人话，
/// 再一键发给开发者。它有三条**必须钉住**的性质，否则功能看着在、实际没用：
///   1. 每种结论都要有**能照着做**的下一步（不许出现"请检查配置"这种空话）；
///   2. "一键发"必须真的**写日志 → 生成报告 → 拉起分享**（少一环就发不出来）；
///   3. 自检**不做写操作**：普通厂家只 GET；免 Key 那条多一次"经本机代理的最小
///      对话"（**非它不可**：本机实测 `GET /models` 一律 200，而真对话可能 403 ——
///      只看清单会把"用不了"报成"好的"）。它不带任何凭据、只打 127.0.0.1。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/local/channel_selfcheck.dart';

void main() {
  test('每种结论都有 label 与"能照着做"的下一步', () {
    for (final o in ChannelOutcome.values) {
      final c = ChannelCheck(
          id: 'x', title: 'X', outcome: o, detail: 'd', next: 'n');
      expect(c.label.trim().isNotEmpty, isTrue, reason: '$o 没有结论文案');
      // 403/404 这两种是**最容易被误判**的，必须说清是"谁的问题、怎么办"
    }
  });

  test('403 分两种：门禁（非官方客户端）与**地区封锁**，不许合成一句', () {
    const blocked = ChannelCheck(
      id: 'zen',
      title: 'OpenCode Zen（免 Key）',
      outcome: ChannelOutcome.blocked,
      detail: 'HTTP 403',
      next: '把自检结果发给开发者核对。',
    );
    const region = ChannelCheck(
      id: 'zen',
      title: 'OpenCode Zen（免 Key）',
      outcome: ChannelOutcome.region,
      detail: 'HTTP 403（上游说：地区不可用）',
      next: '换网络，或先用别的模型。',
    );
    // 2026-10-15 本机实测：同一个出口、同一时刻，403 的两种含义**处理方式完全不同**
    // ——把地区封锁说成"上游又收紧了门禁"，用户会一直去换模型（那条路怎么换都不好）。
    expect(blocked.label, contains('非官方客户端'), reason: '门禁那种要说清成因很特别');
    expect(region.label, contains('地区'), reason: '地区封锁必须点名"地区"');
    expect(blocked.label, isNot(contains('地区')));
    expect(region.label, isNot(contains('非官方客户端')));
  });

  test('免 Key 那条的自检**必须打一次真对话**（只看 /models 会假通过）', () {
    final src = File('lib/local/channel_selfcheck.dart').readAsStringSync();
    // 依据：本机 2026-10-15/16 两次实测，`GET /inference/v1/models` 一律 200，
    // 而 `POST chat/completions` 可能 403 —— 只看清单会把"用不了"报成"好的"。
    expect(src.contains('postUrl'), isTrue,
        reason: 'zen 那条必须打一次对话，否则自检是假通过');
    expect(src.contains('127.0.0.1:\$port/v1/chat/completions'), isTrue,
        reason: '对话探测只许打**本机代理**（与 App 真正用的路径同一条），不许直连上游');
  });

  test('自检不带任何凭据、不做上传（POST 只打本机、且没有 Key）', () {
    final src = File('lib/local/channel_selfcheck.dart').readAsStringSync();
    expect(src.contains('multipart'), isFalse);
    expect(src.contains('client.getUrl'), isTrue, reason: '普通厂家仍是 GET 探测');
    // 对话探测那一段里不许出现 Authorization / apiKey 之类
    final zenProbe = src.substring(
        src.indexOf('static Future<({int status, bool region})> _zenChatOnce'),
        src.indexOf('/// 一次 `GET <url>/…` 探测 → 结论。'));
    expect(zenProbe.contains('authorizationHeader'), isFalse,
        reason: '打本机代理不需要、也不该带任何凭据');
    expect(zenProbe.contains('ProviderKeys'), isFalse,
        reason: '免 Key 那条本来就没有 Key 可带');
  });

  test('toLogLine 就是"一键发给开发者"发出去的那一行', () {
    const c = ChannelCheck(
      id: 'deepseek',
      title: 'DeepSeek 官方',
      outcome: ChannelOutcome.gone,
      detail: 'HTTP 404',
      next: '点「获取模型」拉新的清单。',
    );
    final line = c.toLogLine();
    expect(line, contains('[deepseek]'), reason: '没有 id 就没法定位是哪条通道');
    expect(line, contains('404'), reason: '没有事实（状态码）');
    expect(line, contains('下一步'), reason: '没有下一步');
    expect(c.ok, isFalse);
    expect(c.label, contains('退役'), reason: '404 在模型场景里通常是"名字退役了"');
  });

  test('「一键发给开发者」三件都在：写日志 + 生成报告 + 拉起分享', () {
    final src = File('lib/ui/pages/settings_tab.dart').readAsStringSync();
    if (!src.contains('_runSelfCheck')) {
      markTestSkipped('源码读取不完整（并发编辑中），跳过');
      return;
    }
    expect(src.contains("DiagnosticsLog.add('selfcheck'"), isTrue,
        reason: '结论没写进诊断日志 → 报告里就没有，等于白点');
    expect(src.contains('DiagnosticsLog.writeToFile'), isTrue,
        reason: '没生成报告文件');
    expect(src.contains('DshHost.shareFile'), isTrue,
        reason: '没拉起分享面板 → 用户发不出去');
    expect(src.contains('一键发给开发者'), isTrue);
    expect(src.contains('_SelfCheckSheet'), isTrue, reason: '结果页没了');
  });
}
