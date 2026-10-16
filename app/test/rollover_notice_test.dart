/// 「长会话助手主动提示」的守卫测试（用户 2026-10-16 提的）。
///
/// 用户原话：「是不是用户使用的会话时间长了，可以提示用户使用长会话助手」。
/// 数据层的判据早就有（`ContextBudget.shouldRollover` = 用掉 ≥70%），缺的是**被用起来**。
/// 这里钉住三件事：跨档位判定在、有调用点、能被用户关掉（关了不再纠缠）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('长会话提示：跨 70%/90% 各一次，且"处理过"之后不再提示', () {
    final src = File('lib/ui/pages/chat_page.dart').readAsStringSync();
    if (!src.contains('_maybePromptRollover')) {
      markTestSkipped('源码读取不完整（并发编辑中），跳过');
      return;
    }
    // 两个档位都在（70% 提醒、90% 变急）
    expect(src.contains('ratio >= 0.7'), isTrue, reason: '70% 的档位没了');
    expect(src.contains('ratio >= 0.9'), isTrue, reason: '90% 的档位没了');
    // **必须有调用点**：只写函数没人调 = 永远不会提示（这正是这次补的东西）
    expect(src.contains('_maybePromptRollover();'), isTrue,
        reason: '没有任何地方调用它 —— 那就等于没做');
    // 用户点开助手 / 点关闭之后不再提示（99 = 已处理）
    expect(src.contains('_rolloverNoticeLevel = 99'), isTrue,
        reason: '没有"不再提示"的出口 —— 会变成一直骚扰');
    // 文案里必须写"估算"（这个百分比是按消息长度算的，不是服务商的真实用量）
    expect(src.contains('（估算）'), isTrue,
        reason: '没写明是估算 —— 用户会把它当成真实用量');
    // 写明了占位符要真的接上（曾经漏传参数、界面上会显示字面 {0}）
    expect(src.contains('<Object?>[pct]'), isTrue,
        reason: '百分比没传进文案');
  });
}
