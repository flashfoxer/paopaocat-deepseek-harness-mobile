/// 自定义厂家的 provider id 必须**唯一且可用**（用户 2026-10-12 定：放进 0.68）。
///
/// ## 依据：别人那份 v0.57 真机日志
///
/// 那位用户把「书生·端砚」加成自建厂家，日志里处处是 `provider=provider`
/// —— 它的 id 就叫 `provider`。原因：`sanitizeProviderId` 把非
/// `[a-z0-9_.-]` 的字符换成 `-`，**纯中文名字换完是空的** → 兜底成固定的
/// `'provider'`。后果：
///   * 再加一家纯中文名字的厂家 → **id 相同，在 models.json 里互相覆盖（真丢数据）**；
///   * 安全区 key 变成 `dsh_provider_key_provider`、环境变量变成 `PROVIDER_API_KEY`；
///   * `provider` 又恰好是解析坏数据时的**哨兵值**，真假分不出来。
library;

import 'dart:io';

import 'package:dsh_mobile/data/configured_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('uniqueProviderId', () {
    test('正常的英文名字照旧（别把能用的东西改坏）', () {
      expect(ConfiguredModels.uniqueProviderId('qwen', taken: <String>{}), 'qwen');
      expect(ConfiguredModels.uniqueProviderId('My-API.v2', taken: <String>{}),
          'my-api.v2');
    });

    test('**纯中文名字**不许变成 `provider` —— 那是哨兵值，会撞名', () {
      final id = ConfiguredModels.uniqueProviderId('书生·端砚', taken: <String>{});
      expect(id, isNot('provider'),
          reason: '又兜回哨兵值了 —— 两家纯中文厂家会互相覆盖');
      expect(id, 'custom');
    });

    test('已被占用就自动编号（第二家纯中文厂家不能覆盖第一家）', () {
      expect(
        ConfiguredModels.uniqueProviderId('书生·端砚', taken: <String>{'custom'}),
        'custom-2',
      );
      expect(
        ConfiguredModels.uniqueProviderId('另一家中文',
            taken: <String>{'custom', 'custom-2'}),
        'custom-3',
      );
    });

    test('英文名字被占用时也编号，不静默覆盖', () {
      expect(ConfiguredModels.uniqueProviderId('qwen', taken: <String>{'qwen'}),
          'qwen-2');
    });

    test('保留名要让开：rotate（轮换组占用）与 local（本机模型）', () {
      // sanitize 本来就处理 rotate（→ rotate-real），这里确认口径没变
      expect(ConfiguredModels.uniqueProviderId('rotate', taken: <String>{}),
          'rotate-real');
      // local 是本机模型的虚拟厂家：被占用时要编号，不能撞
      expect(ConfiguredModels.uniqueProviderId('local', taken: <String>{'local'}),
          'local-2');
    });

    test('结果永远不落在"已占用"集合里（含 999 家同名那种极端）', () {
      final taken = <String>{'custom'};
      for (var i = 2; i < 20; i++) {
        taken.add('custom-$i');
      }
      final id = ConfiguredModels.uniqueProviderId('中文名字', taken: taken);
      expect(taken.contains(id), isFalse, reason: '返回了一个已经用掉的名字');
    });
  });

  group('面板必须把它接到"看得见"的地方', () {
    test('预览与保存**共用同一个函数**（两套规则必然跑偏）', () {
      // 为什么读源码：这条要证明的是"用户在下载之前能看见会用什么 id"。
      // 老逻辑的坑正是"推导藏在保存里，用户看不见"。
      final src =
          File('lib/ui/pages/model_settings_panel.dart').readAsStringSync();
      expect(src.contains('_cIdPreview('), isTrue, reason: '对话框里没有 id 预览');
      expect(src.contains('uniqueProviderId('), isTrue,
          reason: '没有用唯一 id 推导 —— 纯中文名字又会变成 provider');
      // 预览与保存各调一次（同一个函数），少于两次说明有一边没用它
      final uses = 'uniqueProviderId('.allMatches(src).length;
      expect(uses, greaterThanOrEqualTo(2),
          reason: '预览和保存必须都走 uniqueProviderId（现在只用了 $uses 处）');
      // 改了名字/id 要能立刻刷新预览
      expect(src.contains('onChanged: (_) => setState(() {}),'), isTrue,
          reason: '输入框没接 onChanged，预览不会跟着变');
    });
  });
}
