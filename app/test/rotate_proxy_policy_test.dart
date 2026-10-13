/// 轮换代理的两条安全策略（审计 P0-2 / P0-3）—— 用**便宜的断言**把口径钉住。
///
/// 为什么值得一条测试：
///   * 这两条守的是"凭据不出 App 私有目录"和"代理不能被同机别的应用白用"，
///     写错了应用照样跑、测试照样绿，只有真出事才知道；
///   * 细节（尤其**文件名**）很容易被后来的人"顺手改回去"——
///     比如把状态文件又起名叫 `rotate-config.json`，那正是老版本凭据落盘的那个名字。
library;

import 'dart:io';

import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/local/rotation_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('P0-3 轮换代理的客户端令牌', () {
    test('是 32 位十六进制、且同一进程内稳定（两侧必须读到同一个值）', () {
      final a = DshRuntime.rotateToken;
      final b = DshRuntime.rotateToken;
      expect(a, equals(b), reason: '两次读到不同的令牌 → 代理和 DSH 会对不上，轮换直接不可用');
      expect(a.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(a), isTrue,
          reason: '应该是 32 位十六进制随机串，实际：$a');
    });

    test('写进 DSH 环境的是同一个值（overlay 用 apiKeyEnv: ROTATE_API_KEY 引用它）', () {
      final rt = DshRuntime(<String, dynamic>{'filesDir': '/tmp/x', 'nodeHome': '/tmp/x'});
      expect(rt.environment['ROTATE_API_KEY'], equals(DshRuntime.rotateToken));
    });

    test('令牌**不能**出现在 exec shim 的默认白名单里', () {
      // 白名单在 node 侧（android-exec-shim.cjs 的 DEFAULT_ENV_PASSTHROUGH），
      // 由 install/test-toolbox-node.mjs 逐条测。这里只在 Dart 侧留一条"别加回去"的提醒：
      // ROTATE_API_KEY 是以 ROTATE_ 开头的，而白名单里没有 ROTATE_ ——
      // 一旦有人往白名单里加了它，模型就能自己拿用户的 Key 去打代理。
      final shim = File('assets/toolbox/android-exec-shim.cjs').readAsStringSync();
      final m = RegExp(r'DEFAULT_ENV_PASSTHROUGH\s*=\s*\[([^\]]*)\]').firstMatch(shim);
      expect(m, isNotNull, reason: 'shim 里找不到 DEFAULT_ENV_PASSTHROUGH');
      expect(m!.group(1), isNot(contains('ROTATE_')),
          reason: '白名单里出现了 ROTATE_ —— 令牌会漏给模型驱动的 shell（P0-2/P0-3 边界）');
    });
  });

  group('P0-2 配置不再以"含 Key 的文件"形式落盘', () {
    test('状态文件名不是老的那个（老名字 = 老版本凭据落盘的文件名）', () {
      final rt = DshRuntime(<String, dynamic>{'filesDir': '/tmp/x', 'nodeHome': '/tmp/x'});
      final p = RotationProxy.instance.statePathFor(rt);
      expect(p, endsWith('rotate-state.json'));
      expect(p, isNot(endsWith('rotate-config.json')),
          reason: '这正是老版本写各厂家真实 Key 的那个文件名');
    });

    test('代理源码里没有把整份配置回写的代码（那次回归的形状）', () {
      final src = File('assets/toolbox/rotate-proxy.mjs').readAsStringSync();
      expect(src.contains(RegExp(r'JSON\.stringify\(raw')), isFalse,
          reason: '又把整份 config（含 Key）写回磁盘了');
    });
  });
}
