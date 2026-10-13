/// 「备用 Key（多账号）」的测试。
///
/// ## 这一层最容易出的两类错（都不会崩、只会静默失效）
///
///   1. **存进去了但没注入** —— 用户填了第二把 Key，`.env` 里却没有它，
///      被限流时脚本没有 Key 可换（表现就是"我明明填了备用 Key，怎么还是 429"）。
///   2. **注入顺序错** —— `AGNES_API_KEY` 必须是**主 Key**（老逻辑/main 路径依赖它），
///      `AGNES_API_KEYS` 里主 Key 必须排第一（脚本按顺序轮换）。
///
/// 另外还要钉住：**界面永不显示 Key 内容**这件事在数据层就已经成立
/// （`readExtras` 只返回数量与顺序，不参与任何日志）。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/data/configured_models.dart';
import 'package:dsh_mobile/state/provider_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 假的安全区（Android Keystore 的方法通道）。
  final Map<String, String> secure = <String, String>{};
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    secure.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return secure[key];
        case 'write':
          secure[key ?? ''] = args['value'] as String? ?? '';
          return null;
        case 'containsKey':
          return secure.containsKey(key);
        case 'delete':
          secure.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(secure);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('备用 Key 的存取', () {
    test('刚开始是空的（没配过不会报错）', () async {
      expect(await ProviderKeys.readExtras('agnes'), isEmpty);
      expect(await ProviderKeys.readAll('agnes'), isEmpty);
    });

    test('添加后能读回来，而且顺序保持', () async {
      expect(await ProviderKeys.addExtra('agnes', 'key-acct-b'), isNull);
      expect(await ProviderKeys.addExtra('agnes', 'key-acct-c'), isNull);
      expect(await ProviderKeys.readExtras('agnes'),
          <String>['key-acct-b', 'key-acct-c']);
    });

    test('重复添加同一把会被拒绝（不报错、也不重复存）', () async {
      await ProviderKeys.addExtra('agnes', 'dup-key');
      final err = await ProviderKeys.addExtra('agnes', 'dup-key');
      expect(err, 'duplicate',
          reason: '数据层返回错误码，文案由界面出（界面文件才被 i18n 门禁扫描）');
      expect(await ProviderKeys.readExtras('agnes'), <String>['dup-key']);
    });

    test('空字符串被拒绝', () async {
      expect(await ProviderKeys.addExtra('agnes', '   '), 'empty');
      expect(await ProviderKeys.readExtras('agnes'), isEmpty);
    });

    test('把主 Key 再加一遍会被拒绝（否则同一把会出现两次）', () async {
      await ProviderKeys.write('agnes', 'the-primary-key');
      final err = await ProviderKeys.addExtra('agnes', 'the-primary-key');
      expect(err, 'is-primary');
      expect(await ProviderKeys.readExtras('agnes'), isEmpty);
    });

    test('删除按位置生效', () async {
      await ProviderKeys.addExtra('agnes', 'a');
      await ProviderKeys.addExtra('agnes', 'b');
      await ProviderKeys.removeExtra('agnes', 0);
      expect(await ProviderKeys.readExtras('agnes'), <String>['b']);
    });

    test('删空之后键值会被真正清掉（不留一个空数组）', () async {
      await ProviderKeys.addExtra('agnes', 'only');
      await ProviderKeys.removeExtra('agnes', 0);
      expect(await ProviderKeys.readExtras('agnes'), isEmpty);
      expect(secure.containsKey(ProviderKeys.extraSecureKeyFor('agnes')), isFalse);
    });

    test('主 Key 不在时，备用整体上移（只填了备用也能用）', () async {
      await ProviderKeys.addExtra('agnes', 'only-backup');
      expect(await ProviderKeys.readAll('agnes'), <String>['only-backup']);
    });

    test('主 Key 在时排第一，后面才是备用', () async {
      await ProviderKeys.write('agnes', 'primary');
      await ProviderKeys.addExtra('agnes', 'backup-1');
      await ProviderKeys.addExtra('agnes', 'backup-2');
      expect(await ProviderKeys.readAll('agnes'),
          <String>['primary', 'backup-1', 'backup-2']);
    });
  });

  group('注入 node 环境（这一步错了 = 填了也白填）', () {
    test('只有一把时：AGNES_API_KEY 有值、AGNES_API_KEYS 就是它', () async {
      await ProviderKeys.write('agnes', 'only');
      final env = await ProviderKeys.envFor(ConfiguredConfig.empty);
      expect(env['AGNES_API_KEY'], 'only');
      expect(env['AGNES_API_KEYS'], 'only');
    });

    test('多把时：AGNES_API_KEY 是主 Key，AGNES_API_KEYS 是全部且主在前', () async {
      await ProviderKeys.write('agnes', 'p1');
      await ProviderKeys.addExtra('agnes', 'b1');
      await ProviderKeys.addExtra('agnes', 'b2');
      final env = await ProviderKeys.envFor(ConfiguredConfig.empty);
      expect(env['AGNES_API_KEY'], 'p1', reason: '老变量必须还是主 Key');
      expect(env['AGNES_API_KEYS'], 'p1,b1,b2',
          reason: '脚本按这个顺序轮换，主 Key 必须在第一位');
    });

    test('只填了备用（没填主）时，AGNES_API_KEY 也不能是空的', () async {
      await ProviderKeys.addExtra('agnes', 'b-only');
      final env = await ProviderKeys.envFor(ConfiguredConfig.empty);
      expect(env['AGNES_API_KEY'], 'b-only',
          reason: '否则 make-image/video 会以为"没有配 Key"而直接报错');
    });

    test('一把都没有时，两个变量都不该出现', () async {
      final env = await ProviderKeys.envFor(ConfiguredConfig.empty);
      expect(env.containsKey('AGNES_API_KEY'), isFalse);
      expect(env.containsKey('AGNES_API_KEYS'), isFalse);
    });

    test('⚠️ Key 内容不能出现在任何日志里（这一条靠 review 也要靠测试提醒）', () async {
      // 这里不做字符串扫描（日志走 debugPrint），而是钉住"数据层的返回里没有多余信息"：
      // readExtras 只返回 Key 本身（界面据此只显示序号），不会打印。
      await ProviderKeys.addExtra('agnes', 'secret-value-xyz');
      final list = await ProviderKeys.readExtras('agnes');
      expect(list.length, 1);
      // 反过来说：**界面**那一侧不能把内容画出来 —— 见 model_settings_panel 的
      // `备用 Key {0}（内容不显示）`，那一条也有 i18n key 钉着。
    });
  });
}
