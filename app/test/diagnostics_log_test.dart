/// 诊断日志**分级**与**工具调用记录**的测试。
///
/// ## 为什么值得钉住
///
/// 真机日志（2026-10-16）里「错误 10 条」有 **8 条其实是模型的原话**：模型在写游戏代码，
/// 满屏 `fail` / `throw new Error` / `异常`，而分级是拿关键词判的 —— 于是用户看到
/// 一个吓人的数字，我排查时也得先把这些噪音剔掉。
///
/// 另一件事：用户问「能不能看出来是不是使用了子代理」，而日志里**工具调用一条都不记**
/// —— 所以这次给工具调用加了独立 tag（`chat:tool`），这里把它的形状钉住。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/local/diagnostics_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('分级：模型/工具的输出不算错误', () {
    test('裸 print（模型原话、含 fail/throw/异常 等词）→ I', () {
      expect(
          DiagnosticsLog.levelOf(
              'function fail() { throw new Error("boom") } // 异常处理', tag: 'print'),
          'I');
      expect(DiagnosticsLog.levelOf('All checks failed to parse', tag: 'print'), 'I');
    });

    test('print:chat 的会话正常事件 → I（哪怕内容里有失败字样）', () {
      for (final s in <String>[
        'thought: the harness fails, let me fix it',
        'message: 一处失败原因是玩家阵亡导致炸弹调用被拒',
        'prompt: 继续',
        'stopReason=max_tokens（第 1 次尝试成功）',
      ]) {
        expect(DiagnosticsLog.levelOf(s, tag: 'print:chat'), 'I', reason: s);
      }
    });

    test('App 自己的失败日志**照旧**判 E（别把真问题一起静音）', () {
      expect(
          DiagnosticsLog.levelOf(
              '保存产物索引失败：PathNotFoundException: Cannot rename file',
              tag: 'print:dsh-artifacts'),
          'E');
      expect(
          DiagnosticsLog.levelOf(
              'prompt failed（第 1 次）: Bad state: session/prompt 失败：Connection error.',
              tag: 'print:chat'),
          'E');
      // 反例：`连不上模型端点` 是**给用户看的翻译文案**，自己不含"失败"字样 → 判 I 是对的。
      // （真正该紧张的是它旁边那条 App 自己的日志，而不是这句提示。）
      expect(DiagnosticsLog.levelOf('连不上模型端点', tag: 'print:dsh-nav'), 'I');
    });

    test('“失败 0 / 错误: 0”这类自证清白仍然是 I', () {
      expect(DiagnosticsLog.levelOf('本轮失败 0 次', tag: 'print:dsh-X'), 'I');
    });
  });

  group('工具调用要能在日志里看出来', () {
    test('工具调用以独立 tag 进缓冲（以后能从日志分辨用了哪些工具 / 有没有子代理）', () {
      DiagnosticsLog.add('chat:tool', '开始 subagent · create a helper file');
      DiagnosticsLog.add('chat:tool', '结束 subagent → completed');
      final dump = DiagnosticsLog.snapshot();
      expect(dump.contains('[chat:tool] 开始 subagent'), isTrue,
          reason: '开始那条没进日志');
      expect(dump.contains('[chat:tool] 结束 subagent → completed'), isTrue,
          reason: '结束那条没进日志');
      // 必须挂在**独立 tag** 上：混进 `print` 的话又会被当成"模型输出"不判级、
      // 也没法用 tag 过滤出"这次用了哪些工具"。
      expect(dump.contains('[print] 开始 subagent'), isFalse);
    });
  });
}
