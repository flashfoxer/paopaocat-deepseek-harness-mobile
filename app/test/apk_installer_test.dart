/// 安装侧（`local/apk_installer.dart`）的回归测试。
///
/// ## 为什么这一组特别重要
///
/// 真正去"读签名、拉安装界面"的活儿在原生（Kotlin）里，Dart 测不到；
/// 但**原生结果怎么被解释**全在这里，而这里恰恰是最容易松口的地方 ——
/// 一句"拿不到就当它过吧"就能让整条签名防线失效。
///
/// 所以这组测试钉住三条**不许松**的铁律：
///   1. **通道不可用 / 返回 null → 一律"不通过"**（不是"未知"、更不是"通过"）；
///   2. **读不到已装签名 → 不通过**（宁可不装，也不装一个来源不明的包）；
///   3. **每个失败原因都有具体的中文话**（不能只丢一句"校验失败"，
///      尤其"签名不一致"必须说清"只能卸载重装、数据会丢"）。
library;

import 'package:dsh_mobile/local/apk_installer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InstallEnv 解析（原生给的键值对 → 强类型）', () {
    test('原生没回话 → unknown，且 canInstall 必须是 false', () {
      final env = InstallEnv.fromMap(null);
      expect(env.canInstall, isFalse,
          reason: '"状态未知"绝不能表现成"可以装" —— 否则用户会白点一次');
      expect(env.installedSignature, isNull);
      expect(InstallEnv.unknown.canInstall, isFalse);
    });

    test('正常值都解析出来', () {
      final env = InstallEnv.fromMap(<String, Object?>{
        'canInstall': true,
        'installedSignature': 'ab' * 32,
        'versionCode': 75,
        'versionName': '0.0.75',
        'sdkInt': 34,
      });
      expect(env.canInstall, isTrue);
      expect(env.installedSignature, 'ab' * 32);
      expect(env.versionCode, 75);
      expect(env.versionName, '0.0.75');
      expect(env.sdkInt, 34);
    });

    test('versionCode 是 double 也认（JSON 过来的数字可能是 double）', () {
      expect(InstallEnv.fromMap(<String, Object?>{'versionCode': 75.0}).versionCode,
          75);
    });

    test('空串/错类型的签名一律当"读不到"（不给下游一个空字符串冒充签名）', () {
      expect(
          InstallEnv.fromMap(<String, Object?>{'installedSignature': '   '})
              .installedSignature,
          isNull);
      expect(
          InstallEnv.fromMap(<String, Object?>{'installedSignature': 42})
              .installedSignature,
          isNull);
    });
  });

  group('SignatureCheck（这里是签名防线的解释层）', () {
    test('原生返回 null → matched=false，且给得出原因', () {
      final c = SignatureCheck.fromMap(null);
      expect(c.matched, isFalse);
      expect(c.reason, isNotNull);
    });

    test('matched 只有为 true 时才算通过（false/缺字段都不算）', () {
      expect(SignatureCheck.fromMap(<String, Object?>{'matched': false}).matched,
          isFalse);
      expect(SignatureCheck.fromMap(<String, Object?>{}).matched, isFalse);
      expect(
          SignatureCheck.fromMap(
                  <String, Object?>{'matched': true, 'reason': null})
              .matched,
          isTrue);
    });

    test('每个失败原因都有一句**针对它**的中文话（不是一个笼统兜底句）', () {
      // 这五个是原生会给的全部原因，每一个都该有具体解释。
      const known = <String>[
        'not_an_apk',
        'apk_unsigned',
        'installed_unknown',
        'signature_mismatch',
        'read_failed',
      ];
      final messages = <String, String>{};
      for (final r in known) {
        final m = SignatureCheck(matched: false, reason: r).message.trim();
        expect(m, isNotEmpty, reason: '$r 没有对应的话');
        messages[r] = m;
      }
      // 五句必须互不相同 —— 否则就是把同一句笼统的话复制了五份（等于没说）。
      expect(messages.values.toSet().length, known.length,
          reason: '不同原因却给了同一句话：$messages');
      // 没见过的新原因也要有兜底，不能给空白。
      expect(const SignatureCheck(matched: false, reason: '没见过').message.trim(),
          isNotEmpty);
    });

    test('"签名不一致"必须把后果说清（只能卸载重装、数据会丢）', () {
      final m = const SignatureCheck(matched: false, reason: 'signature_mismatch')
          .message;
      expect(m, contains('卸载重装'));
      expect(m, contains('数据'));
    });

    test('通过时的话是"可以安装"，不要说成"已安装"（我们根本不知道装没装上）', () {
      final m = const SignatureCheck(matched: true).message;
      expect(m, contains('可以安装'));
      expect(m, isNot(contains('已安装')));
    });
  });
}
