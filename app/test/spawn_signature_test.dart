// 用户 2026-10-15 第 1 条：「切换模型不要重建会话，看看有没有这个问题发生」。
//
// 这条逻辑的判据（`provider_plumbing` / `selectedRoutePlumbing`）是纯函数，
// 直接测 —— 界面层那套（`ChatPage._applyModelChangeOnce`）要真起 node 进程，
// 测不到这一层。
//
// 三件事必须成立（每一条都对应一个真实场景）：
//   ① **改别的厂家**（Key / 端点 / 模型）→ 这条路由的管路**不许变** ——
//      这正是"改别的厂家却重启了正在聊的会话"的来源；
//   ② **改自己这个厂家**（Key 值 / baseUrl / api / 模型条目）→ 管路**必须变**，
//      否则进程还揣着旧 Key / 旧端点继续跑；
//   ③ 轮换组：成员清单变了也算变（组里的转发目标换了）。

import 'package:dsh_mobile/data/configured_models.dart';
import 'package:dsh_mobile/state/spawn_signature.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderSpec _p(String id, {String baseUrl = 'https://a/v1', String env = 'A_KEY'}) =>
    ProviderSpec(id: id, label: id, baseUrl: baseUrl, apiKeyEnv: env);

ModelSpec _m(String provider, String id) =>
    ModelSpec(provider: provider, id: id, name: id, context: 128000);

ConfiguredConfig _cfg({
  List<ProviderSpec>? providers,
  List<ModelSpec>? models,
  List<RotationGroupSpec>? groups,
}) =>
    ConfiguredConfig(
      version: ConfiguredModels.currentVersion,
      providers: providers ?? <ProviderSpec>[_p('com'), _p('agnes', env: 'AGNES_KEY')],
      models: models ??
          <ModelSpec>[_m('com', 'deepseek-v4.1-flash'), _m('agnes', 'agnes-3.0-flash')],
      groups: groups ?? const <RotationGroupSpec>[],
      selected: 'com/deepseek-v4.1-flash',
    );

void main() {
  group('providerOfRoute', () {
    test('从 route 取 provider 段', () {
      expect(providerOfRoute('com/deepseek-v4.1-flash'), 'com');
      expect(providerOfRoute('rotate/cat'), 'rotate');
      expect(providerOfRoute('没有斜杠'), '');
      expect(providerOfRoute('/前面就是斜杠'), '');
      expect(providerOfRoute(''), '');
    });
  });

  group('这条路由的管路指纹', () {
    test('① 改别的厂家的 Key → 当前这条路由的管路不变（不该重启会话）', () {
      final before = selectedRoutePlumbing(
        cfg: _cfg(),
        keys: <String, String>{'A_KEY': 'k-a', 'AGNES_KEY': 'old'},
        route: 'com/deepseek-v4.1-flash',
        legacyKey: '',
      );
      final after = selectedRoutePlumbing(
        cfg: _cfg(),
        keys: <String, String>{'A_KEY': 'k-a', 'AGNES_KEY': 'brand-new-key'},
        route: 'com/deepseek-v4.1-flash',
        legacyKey: '',
      );
      expect(after, before,
          reason: '用户的场景就是"改了 agnes 的 Key，com 的会话被重启了"');
    });

    test('② 改自己这个厂家的 Key 值 → 管路变（必须重建，否则还用旧 Key）', () {
      final before = selectedRoutePlumbing(
        cfg: _cfg(),
        keys: <String, String>{'A_KEY': 'old'},
        route: 'com/deepseek-v4.1-flash',
        legacyKey: '',
      );
      final after = selectedRoutePlumbing(
        cfg: _cfg(),
        keys: <String, String>{'A_KEY': 'new'},
        route: 'com/deepseek-v4.1-flash',
        legacyKey: '',
      );
      expect(after, isNot(before));
    });

    test('② 改自己这个厂家的 baseUrl / api / 模型条目 → 管路变', () {
      final base = selectedRoutePlumbing(
        cfg: _cfg(),
        keys: <String, String>{'A_KEY': 'k'},
        route: 'com/deepseek-v4.1-flash',
        legacyKey: '',
      );

      final otherUrl = selectedRoutePlumbing(
        cfg: _cfg(providers: <ProviderSpec>[
          _p('com', baseUrl: 'https://b/v1'),
          _p('agnes', env: 'AGNES_KEY'),
        ]),
        keys: <String, String>{'A_KEY': 'k'},
        route: 'com/deepseek-v4.1-flash',
        legacyKey: '',
      );
      expect(otherUrl, isNot(base), reason: '端点变了，进程里那份不会热更新');

      final moreModels = selectedRoutePlumbing(
        cfg: _cfg(models: <ModelSpec>[
          _m('com', 'deepseek-v4.1-flash'),
          _m('com', 'deepseek-v4-pro'),
          _m('agnes', 'agnes-3.0-flash'),
        ]),
        keys: <String, String>{'A_KEY': 'k'},
        route: 'com/deepseek-v4.1-flash',
        legacyKey: '',
      );
      expect(moreModels, isNot(base), reason: '给这个厂家加了模型 = 进程里没注册过');
    });

    test('② 老键（v1 设置页那个）变了也算变', () {
      final before = selectedRoutePlumbing(
          cfg: _cfg(), keys: <String, String>{'A_KEY': 'k'},
          route: 'com/deepseek-v4.1-flash', legacyKey: '');
      final after = selectedRoutePlumbing(
          cfg: _cfg(), keys: <String, String>{'A_KEY': 'k'},
          route: 'com/deepseek-v4.1-flash', legacyKey: 'legacy-key');
      expect(after, isNot(before));
    });

    test('③ 轮换组：成员清单变了 → 管路变（组里转发目标换了）', () {
      final one = selectedRoutePlumbing(
        cfg: _cfg(groups: <RotationGroupSpec>[
          const RotationGroupSpec(
              name: 'cat', members: <String>['com/deepseek-v4.1-flash']),
        ]),
        keys: <String, String>{'A_KEY': 'k'},
        route: 'rotate/cat',
        legacyKey: '',
      );
      final two = selectedRoutePlumbing(
        cfg: _cfg(groups: <RotationGroupSpec>[
          const RotationGroupSpec(name: 'cat', members: <String>[
            'com/deepseek-v4.1-flash',
            'agnes/agnes-3.0-flash',
          ]),
        ]),
        keys: <String, String>{'A_KEY': 'k'},
        route: 'rotate/cat',
        legacyKey: '',
      );
      expect(two, isNot(one));
    });

    test('没注册过的 route → 空串（调用方据此走重建）', () {
      expect(
        providerPlumbing(
            cfg: _cfg(), keys: <String, String>{}, providerId: 'nope'),
        '',
      );
      expect(
        selectedRoutePlumbing(
            cfg: _cfg(), keys: <String, String>{}, route: '', legacyKey: ''),
        isNot(isEmpty),
        reason: '空 route 交给上层判：这里只是"没有 provider 段"，legacy 标记仍在',
      );
    });

    test('同一条路由两次取值稳定（不能每次都不一样，否则每次切模型都重建）', () {
      final a = selectedRoutePlumbing(
          cfg: _cfg(), keys: <String, String>{'A_KEY': 'k'},
          route: 'com/deepseek-v4.1-flash', legacyKey: 'x');
      final b = selectedRoutePlumbing(
          cfg: _cfg(), keys: <String, String>{'A_KEY': 'k'},
          route: 'com/deepseek-v4.1-flash', legacyKey: 'x');
      expect(a, b);
    });
  });
}
