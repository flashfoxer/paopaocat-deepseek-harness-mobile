// 「免费模型（无需 Key）」= **Pollinations**（用户 2026-10-15：「主要就是以前承诺过
// 不需要填写 key」）。
//
// 这个测试钉住三件**必须成立**的事，它们各自对应一个真实的失败模式：
//
//   ① **"不用 Key" 不能只是文案**：`polli` 必须在 `appProvidedCredentialIds` 里 ——
//      否则模型选择器会给它打红字「未配 Key」、还催用户去填 Key，而这条通道
//      本来就不需要 Key（2026-10-11 用户为 zen 纠正过同一个毛病）。
//   ② **只动自己那部分**：写/摘配置时，用户自己的厂家、模型、轮换池、以及
//      "他选中了哪个" 一个都不能被顺手改掉。
//   ③ **拉不到就如实说**：上游 404 / 坏 JSON / 空列表时不许编一个模型出来 ——
//      宁可在设置页显示"没取到"，也不能写一批"点了就报错"的模型进列表。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/data/configured_models.dart';
import 'package:dsh_mobile/data/polli_channel.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

ConfiguredConfig _cfg({
  List<ProviderSpec>? providers,
  List<ModelSpec>? models,
  List<RotationGroupSpec>? groups,
  String? selected,
}) =>
    ConfiguredConfig(
      version: ConfiguredModels.currentVersion,
      providers: providers ??
          <ProviderSpec>[
            const ProviderSpec(
              id: 'com',
              label: 'DeepSeek',
              baseUrl: 'https://api.deepseek.com/v1',
              apiKeyEnv: 'COM_API_KEY',
            ),
          ],
      models: models ??
          <ModelSpec>[
            const ModelSpec(provider: 'com', id: 'deepseek-v4.1-flash'),
          ],
      groups: groups ?? const <RotationGroupSpec>[],
      selected: selected ?? 'com/deepseek-v4.1-flash',
    );

void main() {
  group('"不用填 Key" 是事实，不只是文案', () {
    test('polli 被当成"凭据由 App 自己提供"的厂家（否则界面会催用户填 Key）', () {
      expect(ConfiguredModels.appProvidedCredentialIds.contains('polli'), isTrue);
      // 老的两家不能因为这次改动被弄丢
      expect(ConfiguredModels.appProvidedCredentialIds.contains('zen'), isTrue);
      expect(ConfiguredModels.appProvidedCredentialIds.contains('local'), isTrue);
    });

    test('写进配置的 provider：基址是 Pollinations 的 OpenAI 兼容层、Key 变量是占位用的', () {
      final out = polliConfigForTest(_cfg(), models: <String>['openai-fast']);
      final p = out.providers.firstWhere((x) => x.id == 'polli');
      expect(p.baseUrl, PolliChannel.baseUrl);
      expect(p.baseUrl, endsWith('/openai'),
          reason: '末尾不能带 /v1：DSH 会自己接 /chat/completions 与 /models');
      expect(p.apiKeyEnv, PolliChannel.apiKeyEnv);
      expect(PolliChannel.placeholderKey, isNotEmpty);
    });
  });

  group('只动自己那部分（用户的东西一个都不能碰）', () {
    test('写入：追加自己的厂家与模型，不动用户原有的', () {
      final before = _cfg();
      final after = polliConfigForTest(before, models: <String>['openai-fast']);

      expect(after.providers.map((p) => p.id), <String>['com', 'polli'],
          reason: '追加在末尾 —— 已经配了 Key 的用户不该被自动切到这个小模型上');
      expect(after.models.map((m) => m.route),
          <String>['com/deepseek-v4.1-flash', 'polli/openai-fast']);
      expect(after.selected, before.selected, reason: '不该顺手改用户选中的模型');
      expect(after.groups, before.groups);
    });

    test('重复写入：不会越写越多（同一个 provider/模型只留一份）', () {
      final once = polliConfigForTest(_cfg(), models: <String>['openai-fast']);
      final twice = polliConfigForTest(once, models: <String>['openai-fast']);
      expect(twice.providers.where((p) => p.id == 'polli').length, 1);
      expect(twice.models.where((m) => m.provider == 'polli').length, 1);
    });

    test('isPolliRoute 只认自己家的 route', () {
      expect(isPolliRoute('polli/openai-fast'), isTrue);
      expect(isPolliRoute('com/deepseek-v4.1-flash'), isFalse);
      expect(isPolliRoute('zen/mimo-v2.6-flash-free'), isFalse);
      expect(isPolliRoute(null), isFalse);
    });
  });

  group('拉模型清单（对着本地假服务，不碰真上游）', () {
    late HttpServer server;
    late String base;
    String body = '{"object":"list","data":[{"id":"openai-fast"}]}';
    int status = 200;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        req.response.statusCode = status;
        req.response.headers.contentType = ContentType.json;
        req.response.write(body);
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('正常：解析 OpenAI 形状的 data[].id', () async {
      body = '{"object":"list","data":[{"id":"openai-fast"},{"id":"another"}]}';
      final ids = await PolliChannel.fetchModels(baseOverride: base);
      expect(ids, <String>['openai-fast', 'another']);
    });

    test('垃圾条目丢掉、重复去掉（不许把脏 id 写进模型列表）', () async {
      body = jsonEncode(<String, Object?>{
        'data': <Object?>[
          <String, Object?>{'id': 'openai-fast'},
          <String, Object?>{'id': '  '},
          <String, Object?>{'nope': 1},
          'not-a-map',
          <String, Object?>{'id': 'openai-fast'},
        ],
      });
      expect(await PolliChannel.fetchModels(baseOverride: base), <String>['openai-fast']);
    });

    test('上游 500 → 空列表（不抛、不编）', () async {
      status = 500;
      expect(await PolliChannel.fetchModels(baseOverride: base), isEmpty);
    });

    test('坏 JSON → 空列表', () async {
      body = '{不是 JSON';
      expect(await PolliChannel.fetchModels(baseOverride: base), isEmpty);
    });

    test('没有 data 数组 → 空列表', () async {
      body = '{"object":"list"}';
      expect(await PolliChannel.fetchModels(baseOverride: base), isEmpty);
    });
  });

  group('enable / disable 写盘（真读真写，用临时目录）', () {
    late Directory tmp;
    late DshRuntime runtime;
    late HttpServer server;
    late String base;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('dsh-polli-');
      runtime = DshRuntime(<String, dynamic>{
        'filesDir': tmp.path,
        'nodeHome': '${tmp.path}/dshhome',
      });
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"data":[{"id":"openai-fast"}]}');
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('enable 把模型写进 models.json；disable 只摘自己、并处理"选中的是它"', () async {
      // 先给用户放一份自己的配置（并且**选中了它**）
      await ConfiguredModels.saveConfig(filesDir: tmp.path, config: _cfg());

      final r = await PolliChannel.enable(runtime: runtime, baseOverride: base);
      expect(r.ok, isTrue);
      expect(r.models, 1);

      var cfg = ConfiguredModels.readConfig(tmp.path);
      expect(polliConfiguredIn(cfg), isTrue);
      expect(cfg.models.map((m) => m.route), contains('polli/openai-fast'));
      expect(cfg.providers.map((p) => p.id), contains('com'),
          reason: '用户自己的厂家还在');

      // 把选中改成那条免费模型，再关掉 → 选中必须退回"没选"，而不是留个死 route
      await ConfiguredModels.saveConfig(
        filesDir: tmp.path,
        config: ConfiguredConfig(
          version: cfg.version,
          providers: cfg.providers,
          models: cfg.models,
          groups: cfg.groups,
          selected: 'polli/openai-fast',
        ),
      );
      await PolliChannel.disable(runtime: runtime);
      cfg = ConfiguredModels.readConfig(tmp.path);
      expect(polliConfiguredIn(cfg), isFalse);
      expect(cfg.models.map((m) => m.route), <String>['com/deepseek-v4.1-flash']);
      expect(cfg.selected, isNull, reason: '指向已删除的 route 会让界面选不中任何模型');
    });

    test('拉不到就**不写**配置，并如实返回原因', () async {
      await ConfiguredModels.saveConfig(filesDir: tmp.path, config: _cfg());
      await server.close(force: true); // 上游没了
      final r = await PolliChannel.enable(runtime: runtime, baseOverride: base);
      expect(r.ok, isFalse);
      expect(r.error, isNotNull);
      expect(polliConfiguredIn(ConfiguredModels.readConfig(tmp.path)), isFalse,
          reason: '宁可在设置页说"没取到"，也不能写一批点了就报错的模型进列表');
    });
  });
}
