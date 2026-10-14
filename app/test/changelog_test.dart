import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/data/changelog.dart';

/// 「更新说明」的门禁（用户 2026-10-14 定：改完就要写进 `kChangelog`，随包一起发）。
///
/// 为什么这几条断言值得存在：更新说明最典型的失败方式**不是写错，而是忘了写** ——
/// 而它又只有一个检查点：出包。等出包那天再回头看改了什么，细节基本已经糊了。
/// 所以把它做成**跑测试就会红**的东西：忘了给新版本写说明，测试先拦下来。
///
/// 注意这里**不校验内容质量**（那要人来判断），只校验"结构上还在、非空、不重复"。
void main() {
  group('更新说明（kChangelog）', () {
    test('每条都有版本号 / 摘要 / 非空条目', () {
      for (final n in kChangelog) {
        expect(n.version.trim(), isNotEmpty, reason: '有版本号是空的');
        expect(n.headline.trim(), isNotEmpty,
            reason: '${n.version} 没有 headline（一句话摘要）');
        expect(n.changes, isNotEmpty, reason: '${n.version} 一条改动都没写');
        for (final c in n.changes) {
          expect(c.trim(), isNotEmpty, reason: '${n.version} 里有空白条目');
        }
        // 面向用户的要求：不出现内部路径 / 文件后缀这类只有开发者看得懂的东西。
        for (final c in n.changes) {
          expect(c.contains('.dart'), isFalse,
              reason: '${n.version} 的条目里出现了 .dart —— 那是写给我们自己看的，用户看不懂');
          expect(c.contains('lib/'), isFalse,
              reason: '${n.version} 的条目里出现了 lib/ 路径 —— 同上');
        }
      }
    });

    test('版本号不重复（否则界面上会出现两条同名版本）', () {
      final seen = <String>{};
      for (final n in kChangelog) {
        expect(seen.add(n.version), isTrue, reason: '版本 ${n.version} 出现了两次');
      }
    });

    test('必须有一条「当前版本」，用户点进去先看到自己这版', () {
      final cur = kChangelog
          .where((n) => (n.status ?? '').contains('当前版本'))
          .toList();
      expect(cur, isNotEmpty, reason: '没有任何一条标了「当前版本」');
    });

    test('必须留着「下一版」这条活条目，而且放在最前面', () {
      final live =
          kChangelog.where((n) => (n.status ?? '').contains('下一版')).toList();
      expect(live, isNotEmpty,
          reason: '缺「下一版」条目 —— 改了功能 / 修了 bug 就写进 kChangelog 的第一条，'
              '约定见 docs/DEVELOPMENT.md（这份说明要随包发出去，写进 docs 的 markdown 不算）');
      expect((kChangelog.first.status ?? '').contains('下一版'), isTrue,
          reason: '「下一版」这条要放在 kChangelog 的最前面');
    });
  });
}
