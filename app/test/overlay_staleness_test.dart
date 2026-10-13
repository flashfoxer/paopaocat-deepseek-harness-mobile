import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/data/configured_models.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/ui/app_shell.dart';

/// `overlayLooksStale` 的契约测试。
///
/// 它守的是用户报的那条：「设置里配好了 A，会话却在用 B」——
/// 同一个厂家只改了 Base URL（provider id 和模型数都没变）时，启动逻辑原来会
/// 认为 overlay "无需重写"，于是新会话打到旧端点。这里把判定钉死。
///
/// overlay 的正文格式与 `DshRuntime.writeOverlayFromConfig` 一致
/// （6 空格是厂家段、10 空格是模型条目）。
void main() {
  late Directory dir;
  late DshRuntime runtime;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dsh-overlay-stale');
    runtime = DshRuntime(<String, dynamic>{
      'filesDir': dir.path,
      'nodeHome': dir.path,
    });
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  ConfiguredConfig cfg(String baseUrl) => ConfiguredConfig(
        version: ConfiguredModels.currentVersion,
        providers: <ProviderSpec>[
          ConfiguredModels.provider(id: 'com', baseUrl: baseUrl),
        ],
        models: <ModelSpec>[
          const ModelSpec(provider: 'com', id: 'model-alpha'),
        ],
        groups: const <RotationGroupSpec>[],
        selected: 'com/model-alpha',
      );

  void writeOverlay(String baseUrl, {String model = 'model-alpha'}) {
    File(runtime.overlayPath).writeAsStringSync('''
- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      com:
        apiKeyEnv: COM_API_KEY
        api: openai-completions
        baseURL: "$baseUrl"
        models:
          - id: $model
            name: "alpha"
            contextWindow: 65536

- id: agent-default-model
  config:
    provider: com
    model: $model
''');
  }

  test('端点与模型都一致 → 不过期（不会每次启动都白重写）', () {
    writeOverlay('http://127.0.0.1:8891/com/v1');
    expect(
      overlayLooksStale(
        runtime: runtime,
        cfg: cfg('http://127.0.0.1:8891/com/v1'),
        activeRoute: 'com/model-alpha',
      ),
      isFalse,
    );
  });

  test('同厂家改了 Base URL → 过期（必须重写，否则会话仍打旧端点）', () {
    writeOverlay('http://127.0.0.1:8891/com/v1');
    expect(
      overlayLooksStale(
        runtime: runtime,
        cfg: cfg('http://127.0.0.1:8892/com2/v1'),
        activeRoute: 'com/model-alpha',
      ),
      isTrue,
    );
  });

  test('模型 id 不在 overlay 里 → 过期', () {
    writeOverlay('http://127.0.0.1:8891/com/v1', model: 'model-beta');
    expect(
      overlayLooksStale(
        runtime: runtime,
        cfg: cfg('http://127.0.0.1:8891/com/v1'),
        activeRoute: 'com/model-alpha',
      ),
      isTrue,
    );
  });

  test('overlay 文件不存在 → 过期', () {
    expect(
      overlayLooksStale(
        runtime: runtime,
        cfg: cfg('http://127.0.0.1:8891/com/v1'),
        activeRoute: 'com/model-alpha',
      ),
      isTrue,
    );
  });

  test('该厂家在配置里、但 overlay 里没写它 → 过期', () {
    writeOverlay('http://127.0.0.1:8891/com/v1');
    // 配置里再加一个厂家（overlay 里没有它）→ 默认指向它就该重写。
    final two = ConfiguredConfig(
      version: ConfiguredModels.currentVersion,
      providers: <ProviderSpec>[
        ConfiguredModels.provider(
            id: 'com', baseUrl: 'http://127.0.0.1:8891/com/v1'),
        ConfiguredModels.provider(
            id: 'agnes', baseUrl: 'http://127.0.0.1:8891/agnes/v1'),
      ],
      models: <ModelSpec>[
        const ModelSpec(provider: 'com', id: 'model-alpha'),
        const ModelSpec(provider: 'agnes', id: 'agnes-model'),
      ],
      groups: const <RotationGroupSpec>[],
      selected: 'agnes/agnes-model',
    );
    expect(
      overlayLooksStale(
          runtime: runtime, cfg: two, activeRoute: 'agnes/agnes-model'),
      isTrue,
    );
  });

  test('route 不属于这份配置（自愈/兜底路径）→ 不作判断，不乱重写', () {
    writeOverlay('http://127.0.0.1:8891/com/v1');
    expect(
      overlayLooksStale(
        runtime: runtime,
        cfg: cfg('http://127.0.0.1:8891/com/v1'),
        activeRoute: 'agnes/whatever',
      ),
      isFalse,
    );
  });

  test('轮换组不参与端点对账（端点永远是本地代理）', () {
    writeOverlay('http://127.0.0.1:8891/com/v1');
    expect(
      overlayLooksStale(
        runtime: runtime,
        cfg: cfg('http://127.0.0.1:9/broken/v1'),
        activeRoute: 'rotate/cat',
      ),
      isFalse,
    );
  });
}
