/// 「首次安装就能直接用免费模型」的回归测试。
///
/// ## 为什么要有它
///
/// 真机反馈（2026-10-16）：「用户首次安装后，让配置模型，**实际免费大模型是可以
/// 直接用的**」—— 这句抱怨背后是一件真事：免费通道（Pollinations，免 Key）
/// 以前**只在用户手动打开那个开关时**才写进 `models.json`，所以全新安装打开会话
/// 看到的是"还没有可用模型，去填 API Key"，而免 Key 的那条路就在旁边。
///
/// 另外这里顺带钉住**离线兜底**：`ensureRegisteredOnFirstRun` 会先联网拉模型清单，
/// 而 `flutter_test` 把所有 HTTP 拦成 400（等价于"没网/上游挂了"）——
/// 所以下面第一条测试恰好走的就是**内置兜底 id** 那条路，这比"联网成功"更有价值。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/data/configured_models.dart';
import 'package:dsh_mobile/data/polli_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('全新安装（models.json 不存在）：首启就把免费模型登记好', () async {
    final dir = Directory.systemTemp.createTempSync('dsh-polli-fresh-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    expect(ConfiguredModels.readConfig(dir.path).models, isEmpty,
        reason: '前提：这一份是全新安装（空目录）');

    final wrote = await PolliChannel.ensureRegisteredOnFirstRun(filesDir: dir.path);
    expect(wrote, isTrue, reason: '首启没有登记免费模型 —— 用户又会看到"去填 API Key"');

    final cfg = ConfiguredModels.readConfig(dir.path);
    final free = cfg.models.where((m) => m.provider == PolliChannel.providerId);
    expect(free.isNotEmpty, isTrue, reason: '配置里没有免费通道的模型');
    // 离线（测试里 HTTP 一律 400）时必须落到**内置兜底**，不能登记成空
    expect(free.map((m) => m.id).toList(),
        containsAll(PolliChannel.builtinModelIds),
        reason: '内置兜底 id 没写进去 —— 没网的首启仍然是"没有可用模型"');
  });

  test('不是全新安装（已经有别的厂家/模型）→ 不再插手', () async {
    final dir = Directory.systemTemp.createTempSync('dsh-polli-used-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    await ConfiguredModels.saveConfig(
      filesDir: dir.path,
      config: ConfiguredConfig.empty.copyWith(
        providers: <ProviderSpec>[
          ConfiguredModels.provider(
            id: 'deepseek',
            baseUrl: 'https://api.deepseek.com',
            label: 'DeepSeek 官方',
          ),
        ],
        models: const <ModelSpec>[
          ModelSpec(provider: 'deepseek', id: 'deepseek-chat'),
        ],
      ),
    );

    final wrote = await PolliChannel.ensureRegisteredOnFirstRun(filesDir: dir.path);
    expect(wrote, isFalse, reason: '已经有配置了还去写 —— 会把用户关掉的免费通道加回来');
    final cfg = ConfiguredModels.readConfig(dir.path);
    expect(cfg.models.any((m) => m.provider == PolliChannel.providerId), isFalse);
    expect(cfg.models.any((m) => m.provider == 'deepseek'), isTrue,
        reason: '用户自己的模型不许被动到');
  });

  test('内置兜底 id 非空（上游匿名层至少有一个）', () {
    expect(PolliChannel.builtinModelIds, isNotEmpty);
    expect(PolliChannel.builtinModelIds, contains('openai-fast'));
  });
}
