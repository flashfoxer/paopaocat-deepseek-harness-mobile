/// 「提示词专家」挑哪个模型 —— 用户 2026-10-12 报的那条 400 的回归测试。
///
/// ## 用户原话
///
/// 「影视工具点击提示词专家返回时是400，怀疑没有接文本模型」
///
/// ## 根因（读代码 + 真机报告确认）
///
/// 原来的 `_pickModel` 只做两件事：按 `models.json` 的顺序取**第一个**
/// 「有 baseUrl + 有凭据」的模型，然后 POST 到 `{baseUrl}/chat/completions`。
/// 它有两个洞，叠在一起就必然出事：
///
///   ① **完全不筛媒体模型**。Agnes 的 `agnes-image-2.5-flash` /
///      `agnes-video-2.5-flash` 是**内置端口**，不走 `/chat/completions`
///      （走 `/images/generations` 与 `/videos`）。把它们的名字发给
///      `/chat/completions`，上游只会回 **400**。
///      而"这两个名字不该当聊天模型"这条规则**只写在设置页**，
///      挡的是"写进 models.json"—— 清单里**已经在**的条目它管不着。
///   ② **不看用户选中的模型**。用户选的是 `zen/mimo-v2.6-flash-free`，
///      可它按清单顺序取第一个（内置厂家顺序里 agnes 排最前）。
///
/// 于是用户看到的就是一句光秃秃的 HTTP 400 —— 所以他只能"怀疑没有接文本模型"。
///
/// ## 这个文件钉什么
///
///   ① 规则本体（`isChatModelFor` / `isOpenAiCompatible`）—— 两个调用点共用一份；
///   ② **真的发一次请求**（本地起一个 HTTP 服务），证明：
///      选中项优先、媒体模型被跳过、组名不被当成模型名发出去；
///   ③ 某个候选 400 时会**自动换下一个**（这条让功能在配置有坏条目时仍能用）；
///   ④ 报错必须写清"用的是哪个模型、发去了哪台机器"—— 缺的就是这条信息。
///
/// ⚠️ `flutter_test` 默认把所有 HTTP 拦成 400，所以本文件显式把
/// `HttpOverrides.global` 置空，才能真的打到本地那个服务上。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/data/agnes_builtin.dart';
import 'package:dsh_mobile/data/chat_model_rule.dart';
import 'package:dsh_mobile/data/configured_models.dart';
import 'package:dsh_mobile/data/prompt_expert.dart';

/// 假的安全区（Android Keystore 的方法通道）。
final Map<String, String> _secure = <String, String>{};

const MethodChannel _secureChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// 一个只会记录请求的本地 OpenAI 风格端点。
class _FakeUpstream {
  _FakeUpstream(this.server) {
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      seen.add(jsonDecode(body) as Map<String, dynamic>);
      final model = (seen.last['model'] ?? '') as String;
      final code = badModels.contains(model) ? 400 : 200;
      req.response.statusCode = code;
      req.response.headers.contentType = ContentType.json;
      req.response.write(code == 200
          ? jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': '一只橘猫坐在窗台上看雨'}
                }
              ]
            })
          : jsonEncode({
              'error': {
                'message': 'model not found: $model',
                'type': 'invalid_request_error'
              }
            }));
      await req.response.close();
    });
  }

  final HttpServer server;

  /// 每次收到的请求体（按顺序）。
  final List<Map<String, dynamic>> seen = <Map<String, dynamic>>[];

  /// 这些模型名一律回 400（模拟"上游不认这个模型"）。
  final Set<String> badModels = <String>{};

  String get baseUrl => 'http://127.0.0.1:${server.port}/v1';

  /// 发出去的第一个请求用的模型名。
  String get firstModel => (seen.first['model'] ?? '') as String;

  List<String> get modelsSent =>
      seen.map((r) => (r['model'] ?? '') as String).toList();
}

ProviderSpec _provider(String id, String baseUrl, {String api = 'openai-completions'}) =>
    ProviderSpec(
      id: id,
      label: id,
      baseUrl: baseUrl,
      api: api,
      apiKeyEnv: '${id.toUpperCase()}_API_KEY',
    );

ConfiguredConfig _cfg({
  required List<ProviderSpec> providers,
  required List<ModelSpec> models,
  String? selected,
}) =>
    ConfiguredConfig(
      version: ConfiguredModels.currentVersion,
      providers: providers,
      models: models,
      groups: const <RotationGroupSpec>[],
      selected: selected,
    );

final PromptExpert _expert =
    kPromptExperts.firstWhere((e) => e.key == 't2i');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_test 默认把 HTTP 拦成 400；这里放行，才能打到本地的假上游。
  setUpAll(() {
    HttpOverrides.global = null;
  });

  setUp(() {
    _secure.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async {
      final args =
          (call.arguments as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return _secure[key];
        case 'write':
          _secure[key ?? ''] = args['value'] as String? ?? '';
          return null;
        case 'containsKey':
          return _secure.containsKey(key);
        case 'delete':
          _secure.remove(key);
          return null;
        case 'deleteAll':
          _secure.clear();
          return null;
        case 'readAll':
          return Map<String, String>.from(_secure);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
  });

  // ══════════════════════════════════════════════════════════════════════════
  // ① 规则本体：两个调用点必须共用一份
  // ══════════════════════════════════════════════════════════════════════════
  group('能聊天的模型判定（设置页与提示词专家共用一份）', () {
    test('Agnes 的文本模型可以', () {
      expect(isChatModelFor('agnes', AgnesBuiltin.textModel), isTrue);
      expect(isChatModelFor('agnes', 'agnes-3.0-flash'), isTrue);
    });

    test('Agnes 的图像 / 视频模型不可以 —— 它们走的是内置媒体端口', () {
      expect(isChatModelFor('agnes', AgnesBuiltin.imageModel), isFalse);
      expect(isChatModelFor('agnes', AgnesBuiltin.videoModel), isFalse);
    });

    test('判定写得够宽：官方以后换名字（agnes-image-3）也照样挡住', () {
      expect(isChatModelFor('agnes', 'agnes-image-3'), isFalse);
      expect(isChatModelFor('agnes', 'AGNES-VIDEO-9'), isFalse);
    });

    test('别的厂家的模型一律放行（这条规则只针对 Agnes 的内置媒体端口）', () {
      expect(isChatModelFor('com', 'deepseek/deepseek-v4.1-flash'), isTrue);
      expect(isChatModelFor('zen', 'mimo-v2.6-flash-free'), isTrue);
      // 别的厂家哪怕名字里有 image，也不该被 Agnes 的规则误伤
      expect(isChatModelFor('openai', 'gpt-image-1'), isTrue);
    });

    test('协议不是 OpenAI 兼容的厂家，不该被硬拼 /chat/completions', () {
      expect(
          isOpenAiCompatible(_provider('x', 'https://a.example/v1')), isTrue);
      expect(
          isOpenAiCompatible(_provider('x', 'https://a.example/v1',
              api: 'anthropic-messages')),
          isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // ② 真的发一次请求：选中的模型优先、媒体模型被跳过
  // ══════════════════════════════════════════════════════════════════════════
  group('挑模型：真的发出去的是什么', () {
    late _FakeUpstream up;
    late _FakeUpstream zen;

    setUp(() async {
      up = _FakeUpstream(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
      zen = _FakeUpstream(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
      _secure['dsh_provider_key_agnes'] = 'sk-agnes-fake';
    });

    tearDown(() async {
      await up.server.close(force: true);
      await zen.server.close(force: true);
    });

    /// 真机上那份清单的形状：agnes 排第一（内置厂家顺序），而且里面
    /// **混着**内置媒体模型 —— 这正是老版本写进 models.json 的样子。
    ConfiguredConfig realishShape() => _cfg(
          providers: <ProviderSpec>[
            _provider('agnes', up.baseUrl),
            _provider('zen', zen.baseUrl),
          ],
          models: const <ModelSpec>[
            // ⚠️ 媒体模型排在**最前面** —— 这就是"挑第一个"会踩雷的原因。
            ModelSpec(provider: 'agnes', id: 'agnes-image-2.5-flash'),
            ModelSpec(provider: 'agnes', id: 'agnes-video-2.5-flash'),
            ModelSpec(provider: 'agnes', id: 'agnes-3.0-flash'),
            ModelSpec(provider: 'zen', id: 'mimo-v2.6-flash-free'),
          ],
          selected: 'zen/mimo-v2.6-flash-free',
        );

    test('用户选中的模型优先 —— 不许偷偷换成清单里的第一个', () async {
      final r = await expandPrompt(
          expert: _expert, input: '一只猫在夕阳下的海滩散步', cfg: realishShape());
      expect(r.ok, isTrue, reason: r.error ?? '');
      // 选中项是 zen 的免费模型 → 请求该打到 zen 那个端点
      expect(zen.seen, hasLength(1), reason: '没有打到选中的那个端点');
      expect(zen.firstModel, 'mimo-v2.6-flash-free');
      expect(up.seen, isEmpty, reason: '不该往 agnes 打');
    });

    test('清单最前面是图像模型时，绝不拿它去 POST /chat/completions', () async {
      // 选中项故意换成一个 agnes **文本**模型，让请求打到 up 上；
      // 关键断言：发出去的绝不能是 image / video 那两个。
      final cfg = _cfg(
        providers: <ProviderSpec>[
          _provider('agnes', up.baseUrl),
        ],
        models: const <ModelSpec>[
          ModelSpec(provider: 'agnes', id: 'agnes-image-2.5-flash'),
          ModelSpec(provider: 'agnes', id: 'agnes-3.0-flash'),
        ],
        selected: 'agnes/agnes-3.0-flash',
      );
      final r = await expandPrompt(expert: _expert, input: '一只橘猫', cfg: cfg);
      expect(r.ok, isTrue, reason: r.error ?? '');
      expect(up.firstModel, 'agnes-3.0-flash');
      expect(up.modelsSent, isNot(contains('agnes-image-2.5-flash')));
    });

    test('选中项是轮换组时：组名不是模型名，不许发出去', () async {
      final cfg = _cfg(
        providers: <ProviderSpec>[
          _provider('agnes', up.baseUrl),
        ],
        models: const <ModelSpec>[
          ModelSpec(provider: 'agnes', id: 'agnes-image-2.5-flash'),
          ModelSpec(provider: 'agnes', id: 'agnes-3.0-flash'),
        ],
        selected: 'rotate/cat',
      );
      final r = await expandPrompt(expert: _expert, input: '一只橘猫', cfg: cfg);
      expect(r.ok, isTrue, reason: r.error ?? '');
      expect(up.firstModel, 'agnes-3.0-flash');
      expect(up.modelsSent, isNot(contains('cat')));
      expect(up.modelsSent, isNot(contains('rotate/cat')));
    });

    test('清单里只剩媒体模型 → 说"没有可用模型"，不许发出去换一个 400', () async {
      final cfg = _cfg(
        providers: <ProviderSpec>[
          _provider('agnes', up.baseUrl),
        ],
        models: const <ModelSpec>[
          ModelSpec(provider: 'agnes', id: 'agnes-image-2.5-flash'),
          ModelSpec(provider: 'agnes', id: 'agnes-video-2.5-flash'),
        ],
        selected: 'agnes/agnes-image-2.5-flash',
      );
      final r = await expandPrompt(expert: _expert, input: '一只橘猫', cfg: cfg);
      expect(r.ok, isFalse);
      expect(r.error, contains('还没有可用的云端模型'));
      expect(up.seen, isEmpty, reason: '一个请求都不该发出去');
    });

    test('协议不是 OpenAI 兼容的厂家会被跳过，不会硬拼路径', () async {
      final cfg = _cfg(
        providers: <ProviderSpec>[
          _provider('weird', up.baseUrl, api: 'anthropic-messages'),
        ],
        models: const <ModelSpec>[
          ModelSpec(provider: 'weird', id: 'some-model'),
        ],
        selected: 'weird/some-model',
      );
      final r = await expandPrompt(expert: _expert, input: '一只橘猫', cfg: cfg);
      expect(r.ok, isFalse);
      expect(up.seen, isEmpty);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // ③ 某个候选 400 → 自动换下一个（配置里有坏条目时功能仍可用）
  // ══════════════════════════════════════════════════════════════════════════
  group('候选依次真试 + 报错必须写清用的是谁', () {
    late _FakeUpstream up;

    setUp(() async {
      up = _FakeUpstream(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
      _secure['dsh_provider_key_agnes'] = 'sk-agnes-fake';
    });

    tearDown(() async {
      await up.server.close(force: true);
    });

    test('第一个模型被上游拒（400）→ 自动换下一个，最终成功', () async {
      up.badModels.add('agnes-bad-model');
      final cfg = _cfg(
        providers: <ProviderSpec>[_provider('agnes', up.baseUrl)],
        models: const <ModelSpec>[
          ModelSpec(provider: 'agnes', id: 'agnes-bad-model'),
          ModelSpec(provider: 'agnes', id: 'agnes-3.0-flash'),
        ],
        selected: 'agnes/agnes-bad-model',
      );
      final r = await expandPrompt(expert: _expert, input: '一只橘猫', cfg: cfg);
      expect(r.ok, isTrue, reason: r.error ?? '');
      expect(up.modelsSent, <String>['agnes-bad-model', 'agnes-3.0-flash']);
    });

    test('全都 400 → 报错里必须写清"用的哪个模型 @ 哪台机器"，以及试了几个', () async {
      up.badModels.addAll(<String>['m-a', 'm-b', 'm-c']);
      final cfg = _cfg(
        providers: <ProviderSpec>[_provider('agnes', up.baseUrl)],
        models: const <ModelSpec>[
          ModelSpec(provider: 'agnes', id: 'm-a'),
          ModelSpec(provider: 'agnes', id: 'm-b'),
          ModelSpec(provider: 'agnes', id: 'm-c'),
        ],
        selected: 'agnes/m-a',
      );
      final r = await expandPrompt(expert: _expert, input: '一只橘猫', cfg: cfg);
      expect(r.ok, isFalse);
      // ⚠️ 这条就是这次修 bug 时最缺的信息：界面以前只说一句 HTTP 400。
      expect(r.error, contains('HTTP 400'));
      expect(r.error, contains('m-c'), reason: '没说用的是哪个模型');
      expect(r.error, contains('127.0.0.1'), reason: '没说发去了哪台机器');
      expect(r.error, contains('试过 3 个模型'), reason: '没说试了几个');
      // 上限 3 个：清单再长也不许无限试下去
      expect(up.seen, hasLength(3));
    });

    test('限流（429）不换候选 —— 换个模型也只是换个地方失败，还让用户白等', () async {
      // 用一个只回 429 的端点
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      s.listen((req) async {
        await utf8.decoder.bind(req).join();
        req.response.statusCode = 429;
        await req.response.close();
      });
      final cfg = _cfg(
        providers: <ProviderSpec>[
          _provider('agnes', 'http://127.0.0.1:${s.port}/v1'),
        ],
        models: const <ModelSpec>[
          ModelSpec(provider: 'agnes', id: 'm-a'),
          ModelSpec(provider: 'agnes', id: 'm-b'),
        ],
        selected: 'agnes/m-a',
      );
      final r = await expandPrompt(expert: _expert, input: '一只橘猫', cfg: cfg);
      expect(r.ok, isFalse);
      expect(r.error, contains('429'));
      await s.close(force: true);
    });
  });
}
