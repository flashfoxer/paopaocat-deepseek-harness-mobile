import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../i18n/dsh_i18n.dart';
import '../local/dsh_runtime.dart';
import 'configured_models.dart';

/// 「**免 Key 就能聊**」那条通道：**Pollinations**（用户 2026-10-15 的要求）。
///
/// ## 为什么要单开它（而不是继续修 OpenCode Zen）
///
/// 用户的原话是：「主要就是以前承诺过不需要填写 key」——这句承诺必须站得住。
/// 但 OpenCode Zen 那条匿名车道（见 `zen_channel.dart`）在 2026-10-13/14 **第五次**
/// 收紧之后已经不可靠：社区里测得最扎实的插件（`viztor/dsh-opencode-patch`）
/// 用它**真实账号的 token + org** 测过，免费模型仍然 `403 FreeTierError`，
/// 于是干脆不提供免费模型 —— 它的结论是"门禁不在请求里，免费层是**没授予**，不是坏了"。
///
/// 而 **Pollinations**（`github.com/pollinations/pollinations`，★5000+）**自己就开放
/// 匿名层**：它 README 的第一句就是 "Free API Classic: images and text from a plain
/// URL. **No signup, no key.**"，模型清单里也明写着 `"tier": "anonymous"`。
/// 所以这条不是"绕过限制"，是**它给的用法**。
///
/// ## 为什么不需要本地代理（和 zen 那条最大的区别）
///
/// Pollinations 的 OpenAI 兼容层就在 **`https://text.pollinations.ai/openai`** 下面：
///
/// | 请求 | 实测（2026-10-15 本机） |
/// |---|---|
/// | `POST https://text.pollinations.ai/openai/chat/completions` | **200**（带不带 Key 都 200） |
/// | `GET  https://text.pollinations.ai/openai/models` | **200**，OpenAI 形状，匿名层只有 `openai-fast` |
/// | 流式 `stream:true` | ✓ 标准 SSE |
/// | 工具调用 | ✓ 返回规范的 `tool_calls` |
///
/// 所以这里**直接写一个 provider**（`baseUrl` 指过去）就行 —— 不用起 node 进程、
/// 不用管端口、node 没起来也能用。这是选它的另一个实际好处。
///
/// ## 如实标注（界面上必须一起说）
///
///   * 匿名层**只有一个模型**：`openai-fast`（gpt-oss-20b）。能用工具、能聊天，
///     但**不是聪明模型**；写小说/长文/画布那类重活它接不住，别让用户误会；
///   * 有**速率限制**（官方没给固定数字），人多了会慢或被限；
///   * 上游是**社区项目**，随时可能改或关门 —— 失败时如实报出来，绝不假装成功。
class PolliChannel {
  PolliChannel._();

  /// 写进模型配置里的厂家 id（`providers.polli`，也是 route 前缀）
  static const String providerId = 'polli';

  /// 这个厂家用的环境变量名。**它其实不需要 Key** —— 这里给的是占位值，
  /// 只为让 DSH 的"这家有没有凭据"检查过得去（与 ROTATE/ZEN/LOCAL 同一个套路，
  /// 见 `provider_keys.dart` 的 `envFor`）。
  static const String apiKeyEnv = 'POLLI_API_KEY';

  /// 占位 Key 的值（不会真的当成凭据用：Pollinations 的匿名层不看它）。
  static const String placeholderKey = 'local-polli';

  /// OpenAI 兼容基址。
  ///
  /// ⚠️ **末尾不带 `/v1`**：它的兼容层就挂在 `/openai` 下，而 DSH 会在基址后面
  /// 自己接 `/chat/completions`、`/models` —— 所以这里写 `/openai` 才拼得对
  /// （拼成 `.../openai/chat/completions`、`.../openai/models`，两条都实测过 200）。
  static const String baseUrl = 'https://text.pollinations.ai/openai';

  /// 界面上显示的名字。**直接说清卖点：不用写 Key。**
  static String get label => tr('免费模型（无需 Key）');

  /// 拉取可用模型（OpenAI 形状的 `/models`）。
  ///
  /// **不抛异常**：网络不通返回空列表，由调用方如实显示"没取到"。
  /// [clientFactory] 只在测试里注入（本地假服务），生产走默认。
  static Future<List<String>> fetchModels({
    Duration timeout = const Duration(seconds: 8),
    HttpClient Function()? clientFactory,
    /// **只给测试用**：把基址指到本地假服务上（生产永远用 [baseUrl]）。
    String? baseOverride,
  }) async {
    final base = (baseOverride ?? baseUrl).replaceAll(RegExp(r'/+$'), '');
    final client = (clientFactory ?? HttpClient.new)();
    client.connectionTimeout = timeout;
    try {
      final req = await client
          .getUrl(Uri.parse('$base/models'))
          .timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        debugPrint('[dsh-polli] /models 返回 ${res.statusCode}');
        return const <String>[];
      }
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const <String>[];
      final data = decoded['data'];
      if (data is! List) return const <String>[];
      final out = <String>[];
      for (final item in data) {
        final id = item is Map ? item['id']?.toString().trim() ?? '' : '';
        if (id.isEmpty || out.contains(id)) continue;
        out.add(id);
      }
      debugPrint('[dsh-polli] 取到 ${out.length} 个模型：${out.join(", ")}');
      return out;
    } catch (e) {
      debugPrint('[dsh-polli] 拉模型失败（当成没取到）：$e');
      return const <String>[];
    } finally {
      client.close(force: true);
    }
  }

  /// 打开（或启动时刷新）：把 provider 与模型写进本机模型配置。
  ///
  /// 返回 `models` = 写进去的模型数；失败时 [error] 是给用户看的中文。
  /// 匿名层**已知**的那几个模型 id。
  ///
  /// 为什么要写死一份：`enable()` 要**联网**拉 `/openai/models` 才写配置，而
  /// **首次安装时不一定有网**（或那次请求刚好失败）—— 于是"免费模型默认开"这个
  /// 承诺就落空了，用户打开会话看到的是"还没有可用模型，去填 API Key"。
  /// 有这份兜底，首启哪怕离线也能把免费通道登记上（上游匿名层目前就 `openai-fast`）。
  static const List<String> builtinModelIds = <String>['openai-fast'];

  /// **首启登记**：全新安装时把免费通道写好，让"直接就能用"成立。
  ///
  /// ⚠️ 只在 `models.json` **完全空白**时做（用户主动关掉免费通道之后，
  /// 配置里会留下别的厂家/模型，或者 `_withPolli` 的痕迹 —— 这里一律不再插手，
  /// 免得把人家关掉的东西又加回来）。
  ///
  /// 返回是否真的写过配置；失败**不抛**（启动路径上不能因为它起不来）。
  static Future<bool> ensureRegisteredOnFirstRun({required String filesDir}) async {
    if (filesDir.trim().isEmpty) return false;
    try {
      final cfg = ConfiguredModels.readConfig(filesDir);
      if (cfg.models.isNotEmpty || cfg.providers.isNotEmpty) return false;
      var models = <String>[];
      try {
        models = await fetchModels();
      } catch (e) {
        debugPrint('[dsh-polli] 首启拉免费模型失败（改用内置兜底）：$e');
      }
      if (models.isEmpty) models = builtinModelIds;
      await ConfiguredModels.saveConfig(
        filesDir: filesDir,
        config: _withPolli(cfg, models: models),
      );
      debugPrint('[dsh-polli] 首启已登记 ${models.length} 个免费模型（免 Key，直接能用）');
      return true;
    } catch (e) {
      debugPrint('[dsh-polli] 首启登记失败（不影响启动）：$e');
      return false;
    }
  }

  static Future<({bool ok, String? error, int models})> enable({
    required DshRuntime runtime,
    HttpClient Function()? clientFactory,
    /// **只给测试用**（见 [fetchModels]）。
    String? baseOverride,
  }) async {
    final models =
        await fetchModels(clientFactory: clientFactory, baseOverride: baseOverride);
    if (models.isEmpty) {
      return (
        ok: false,
        error: tr('没取到免费模型 —— 上游那条通道可能暂时不可用（或这台机器上不了网）。'),
        models: 0,
      );
    }
    try {
      final cfg = ConfiguredModels.readConfig(runtime.filesDir);
      await ConfiguredModels.saveConfig(
        filesDir: runtime.filesDir,
        config: _withPolli(cfg, models: models),
      );
      debugPrint('[dsh-polli] 已写入 ${models.length} 个免费模型（免 Key）');
      return (ok: true, error: null, models: models.length);
    } catch (e) {
      debugPrint('[dsh-polli] 写配置失败：$e');
      return (ok: false, error: tr('写模型配置失败：{0}', <Object?>['$e']), models: 0);
    }
  }

  /// 关闭：把厂家与它的模型从配置里摘掉。
  ///
  /// ⚠️ **只摘自己那部分**：用户自己的厂家、模型、轮换池一个都不能动。
  static Future<void> disable({required DshRuntime runtime}) async {
    try {
      final cfg = ConfiguredModels.readConfig(runtime.filesDir);
      if (!cfg.providers.any((p) => p.id == providerId) &&
          !cfg.models.any((m) => m.provider == providerId)) {
        return;
      }
      await ConfiguredModels.saveConfig(
        filesDir: runtime.filesDir,
        config: ConfiguredConfig(
          version: cfg.version,
          providers: <ProviderSpec>[
            for (final p in cfg.providers)
              if (p.id != providerId) p,
          ],
          models: <ModelSpec>[
            for (final m in cfg.models)
              if (m.provider != providerId) m,
          ],
          groups: cfg.groups,
          // 选中的如果正好是这条通道的模型，退回"没选"（让界面自己挑一个），
          // 而不是留一个已经不存在的 route。
          selected: (cfg.selected ?? '').startsWith('$providerId/')
              ? null
              : cfg.selected,
        ),
      );
    } catch (e) {
      debugPrint('[dsh-polli] 关闭时清理配置失败：$e');
    }
  }

  /// 启动时调用：开关开着就刷新一遍模型清单（开关关着就把残留痕迹清掉）。
  ///
  /// 与 zen 那条的区别：**这条不用起本地进程**，所以"刷新"就是再拉一次清单；
  /// 失败也**不摘模型** —— 因为 provider 的地址是固定的公网地址，不像 zen 那样
  /// 每次启动都会换端口（摘掉反而会让用户莫名少了一批能用的模型）。
  static Future<void> refreshIfEnabled({
    required bool enabled,
    required DshRuntime runtime,
    HttpClient Function()? clientFactory,
  }) async {
    if (!enabled) {
      await disable(runtime: runtime);
      return;
    }
    final r = await enable(runtime: runtime, clientFactory: clientFactory);
    if (!r.ok) {
      _lastRefreshError = r.error;
      debugPrint('[dsh-polli] 启动刷新失败（保留已有配置）：${r.error}');
      return;
    }
    _lastRefreshError = null;
  }

  /// 上一次刷新的失败原因（设置页显示用；进程内有效）。
  static String? _lastRefreshError;
  static String? get lastRefreshError => _lastRefreshError;

  static void clearRefreshError() => _lastRefreshError = null;

  static ConfiguredConfig _withPolli(
    ConfiguredConfig cfg, {
    required List<String> models,
  }) {
    return ConfiguredConfig(
      version: cfg.version,
      providers: <ProviderSpec>[
        // 先摘掉旧的自己，再**追加**一份新的。
        //
        // 为什么追加在末尾、而不是插到最前面：`ModelStore._firstUsable()`
        // 是按清单顺序挑"第一家能用的" —— 插到前面会让**已经自己配了 Key 的用户**
        // 被自动切到这个 20B 的小模型上。追加在末尾时：没配 Key 的用户本来就
        // 只有它能用（自动选中它 ✓），配了 Key 的用户仍然优先用自己那家 ✓。
        for (final p in cfg.providers)
          if (p.id != providerId) p,
        ProviderSpec(
          id: providerId,
          label: label,
          baseUrl: baseUrl,
          apiKeyEnv: apiKeyEnv,
        ),
      ],
      models: <ModelSpec>[
        for (final m in cfg.models)
          if (m.provider != providerId) m,
        for (final id in models)
          ModelSpec(provider: providerId, id: id, name: id),
      ],
      groups: cfg.groups,
      selected: cfg.selected,
    );
  }
}

/// 让"是否已写入配置"这类判断可以离线测试（不碰网络）。
bool polliConfiguredIn(ConfiguredConfig cfg) =>
    cfg.providers.any((p) => p.id == PolliChannel.providerId) ||
    cfg.models.any((m) => m.provider == PolliChannel.providerId);

/// 仅供测试：暴露"把 polli 写进配置"的纯函数（不联网）。
ConfiguredConfig polliConfigForTest(
  ConfiguredConfig cfg, {
  required List<String> models,
}) =>
    PolliChannel._withPolli(cfg, models: models);

/// 某条 route 是不是"免 Key 免费通道"的（界面据此加标注）。
bool isPolliRoute(String? route) =>
    (route ?? '').startsWith('${PolliChannel.providerId}/');
