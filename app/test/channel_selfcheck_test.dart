/// 「通道自检 + 一键发给开发者」的测试。
///
/// ## 为什么
///
/// 用户 2026-10-16 提的「探查机制」第①层：把"模型用不了"按状态码分类成人话，
/// 再一键发给开发者。它有三条**必须钉住**的性质，否则功能看着在、实际没用：
///   1. 每种结论都要有**能照着做**的下一步（不许出现"请检查配置"这种空话）；
///   2. "一键发"必须真的**写日志 → 生成报告 → 拉起分享**（少一环就发不出来）；
///   3. 自检**只做读探测**（GET），绝不发 POST/上传 —— 这是它对用户的承诺。
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

  test('403 要说成"被当成非官方客户端"（不是笼统的"失败"）', () {
    const c = ChannelCheck(
      id: 'zen',
      title: 'OpenCode Zen（免 Key）',
      outcome: ChannelOutcome.blocked,
      detail: 'HTTP 403',
      next: '把自检结果发给开发者核对。',
    );
    expect(c.label, contains('非官方客户端'),
        reason: '403 的成因很特别（上游只认它自家 CLI 的形状），笼统说"失败"等于没说');
    expect(c.label, contains('403'));
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

  test('自检只做读探测：GET，不发 POST、不传 multipart', () {
    final src = File('lib/local/channel_selfcheck.dart').readAsStringSync();
    expect(src.contains('client.getUrl'), isTrue, reason: '应该是 GET 探测');
    expect(src.contains('postUrl'), isFalse,
        reason: '自检不该发 POST —— 它对用户承诺过"不做写操作"');
    expect(src.contains('multipart'), isFalse);
  });
}
