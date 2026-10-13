// 错误翻译层的单元测试。
//
// 为什么专门为这个文件建测试：**用户真机截图给过一条真实报错**，我必须保证
// 那条串真的会被翻译成中文（而不是"我以为会"）。这类纯字符串逻辑用测试锁住，
// 比在真机上一条条试便宜得多。
//
// 跑法（必须在 ASCII 镜像里，中文路径会让 flutter 挂）：
//   robocopy <proj>\app D:\dev\build\app-main /MIR /XD build .dart_tool .idea .gradle
//   cd D:\dev\build\app-main && flutter test test/api_error_text_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/data/api_error_text.dart';

/// 用户 2026-10-04 真机截图里的**原文**（一字未改）。
const String kRealUserError =
    '执行失败: Bad state: session/prompt 失败: Internal error: turn failed: '
    'llm-pi-ai: no credential for provider route "agnes"; its profile resolves '
    'AGNES_API_KEY, which is not set -- store AGNES_API_KEY through the '
    'credentials service (the web Models page writes it) or export it, and remove '
    'apiKeyEnv only if this provider should authenticate from pi-ai\'s own '
    'environment discovery';

void main() {
  test('真机上那条缺 Key 的报错必须被翻译成中文，并带上厂家名与下一步', () {
    final t = translateDshError(kRealUserError);
    expect(t, isNotNull, reason: '这条真实报错必须命中翻译规则');
    // 中文说明里要点：厂家名（agnes）、"还没配 Key"、去哪修、Agnes 注册地址
    expect(t!.zh, contains('agnes'));
    expect(t.zh, contains('Key'));
    expect(t.zh, contains('设置'));
    expect(t.zh, contains('platform.agnes-ai.cn'));
    // 原文不能丢（排查要靠它），且要指出缺的是哪个环境变量
    expect(t.detail, contains('AGNES_API_KEY'));
  });

  test('缺凭据的其它写法（MISSING_CREDENTIAL）也要命中', () {
    final t = translateDshError('turn failed: MISSING_CREDENTIAL: something');
    expect(t, isNotNull);
    expect(t!.zh, contains('Key'));
  });

  test('连不上端点 → 中文说明且标为可重试', () {
    final t =
        translateDshError('session/prompt 失败: TRANSPORT: Connection error.');
    expect(t, isNotNull);
    expect(t!.retryable, isTrue);
    expect(t.zh, contains('连不上'));
  });

  test('模型没注册 → 提示"重新点一次默认模型/重新选一次"', () {
    final t = translateDshError('Unknown model "foo" for provider "bar"');
    expect(t, isNotNull);
    expect(t!.zh, contains('重新'));
  });

  test('沙箱没有可用后端（Android 上不该出现）也要有自救提示', () {
    final t = translateDshError('bash: no backend usable under read-only mode');
    expect(t, isNotNull);
    expect(t!.zh, contains('danger-full-access'));
  });

  test('认不出来的错误返回 null —— 调用方原样展示，不编造原因', () {
    expect(translateDshError('some totally unrelated failure'), isNull);
    expect(translateDshError(''), isNull);
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 会话路径（ACP）的 HTTP 报错也必须能翻译
  //
  // 依据：2026-10-12 别人那份 v0.57 真机日志。那位用户切到 Command 聚合后连撞
  // 401，而原始报错长这样：
  //   `Bad state: session/prompt 失败：Internal error: turn failed: 401: {…}`
  // 上面那些具体分支**一条都匹配不上** → 返回 null → 界面只能说
  // 「这条没能回上来。可以再发一次」。而对 401 来说"再发一次"是**错的建议**：
  // 他因此白试了 4 次（App 自动重试一轮 + 他手动再来一轮）。
  // 最冤的是：401 的人话早就写在 `translateHttpError` 里了，这条路就是碰不到它。
  // ══════════════════════════════════════════════════════════════════════════
  group('会话路径的 HTTP 报错兜底', () {
    const acp401 = 'Bad state: session/prompt 失败：Internal error: turn failed: 401: '
        '{"message":"Invalid \'Authorization\' header or token.",'
        '"type":"authentication_error","code":"UNAUTHORIZED"}';

    test('真机那条 401：要翻译成"Key 无效"，而不是让他再发一次', () {
      final t = translateDshError(acp401);
      expect(t, isNotNull,
          reason: '又变成"这条没能回上来"了 —— 用户永远不知道是 Key 的问题');
      expect(t!.zh, contains('Key'));
      expect(t.retryable, isFalse,
          reason: '401 重试结果一模一样 —— 不该让用户再白等一轮');
      expect(t.detail, contains('Authorization'),
          reason: '上游原话要留在"技术细节"里（排查要用）');
    });

    test('429 / 5xx 要判成"值得重试"', () {
      final r = translateDshError('turn failed: 429: {"message":"rate limit"}');
      expect(r, isNotNull);
      expect(r!.retryable, isTrue);
      final s5 = translateDshError('turn failed: 503: {"message":"server error"}');
      expect(s5, isNotNull);
      expect(s5!.retryable, isTrue, reason: '服务端错误重试是对的，别一刀切成不重试');
    });

    test('404 不重试（模型名/端点写错了，重试没用）', () {
      final r = translateDshError('turn failed: 404: {"message":"no such model"}');
      expect(r, isNotNull);
      expect(r!.retryable, isFalse);
    });

    test('不许乱抓：形状不对的仍然返回 null（不能凭空编一个原因）', () {
      expect(translateDshError('some totally unrelated failure'), isNull);
      expect(translateDshError('花了 401 毫秒'), isNull);
      expect(translateDshError('error code 401 happened'), isNull);
      expect(translateDshError(''), isNull);
    });
  });
}
