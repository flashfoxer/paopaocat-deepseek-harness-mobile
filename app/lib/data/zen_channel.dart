import 'package:flutter/foundation.dart' show debugPrint;

import '../i18n/dsh_i18n.dart';
import '../local/dsh_runtime.dart';
import '../local/zen_proxy.dart';
import 'configured_models.dart';

/// 「社区免费通道（实验）」的**开关逻辑**。
///
/// ## 它到底做了什么（一句话，别在界面里含糊）
///
/// 起一个**本地代理**（`assets/toolbox/zen-proxy.mjs`），由它把请求按
/// **官方 CLI 的形状**转发到 OpenCode Zen 的匿名免费额度，然后把拿到的免费模型
/// 写进本机的模型配置 —— 于是"设置里打开开关 → 模型选择器里出现一批免费模型"。
///
/// ⚠️ 上游的免费层**只允许它自家 CLI 用**（非官方形状会被 403 拒），所以这属于
/// **绕过一个有意设置的访问限制**。因此在本 App 里的定位被刻意收窄为：
///   * 默认关闭、必须用户显式打开（[AppSettings.zenEnabled]）；
///   * 界面**如实标注**：随时可能失效、不承诺稳定性，并且**不需要用户填任何 Key**
///     （这条通道本来就是匿名的，上游凭据是公开的 `public` —— 别催用户去配
///     一个自己的 Key，那与它的事实不符，2026-10-11 用户纠正过）；
///   * **不做** IP 轮换 / 重试轰炸（不实现任何"放大器"）。
///
/// ## 端口每次都会变
///
/// 代理监听的是系统分配的随机端口（`--port 0`），所以**每次启动都要把
/// `baseUrl` 重新写一遍** —— 否则配置里还指着上次那个已经不存在的端口，
/// 表现就是"打开了开关但所有模型都连不上"。见 [refresh]。
class ZenChannel {
  ZenChannel._();

  /// 写进模型配置里的厂家 id（`providers.zen`，也是 route 前缀）。
  static const String providerId = 'zen';

  /// 这个厂家用的环境变量名（占位值由 `ProviderKeys.envFor` 注入）。
  static const String apiKeyEnv = 'ZEN_API_KEY';

  /// 界面上显示的名字 —— 直接说清它的卖点：**不用写 Key**。
  ///
  /// 名字里不再带"实验/社区"：这条通道确实随时可能失效（设置页那个开关旁边
  /// 写明了风险），但"实验"两个字会让用户以为"要用得先做点什么"——比如去配一个
  /// Key —— 而它恰恰**不用配 Key**（2026-10-11 用户纠正：
  /// "这个项目的特点就是不用写key"）。
  static String get label => tr('免费模型（无需 Key）');

  /// 开启（或在启动时刷新）：起代理、取模型、写配置。
  ///
  /// 返回 `models` = 写进去的模型数；失败时 `error` 是给用户看的中文。
  static Future<({bool ok, String? error, int models})> enable({
    required DshRuntime runtime,
  }) async {
    final port = await ZenProxy.instance.ensureRunning(runtime: runtime);
    if (port == null) {
      return (
        ok: false,
        error: tr('本地代理没能启动起来（详见运行日志）。'),
        models: 0,
      );
    }
    final models = await ZenProxy.instance.fetchFreeModels(port);
    if (models.isEmpty) {
      return (
        ok: false,
        error: tr('连上了代理，但没取到任何免费模型 —— 上游那条通道可能暂时不可用。'),
        models: 0,
      );
    }
    try {
      final cfg = ConfiguredModels.readConfig(runtime.filesDir);
      await ConfiguredModels.saveConfig(
        filesDir: runtime.filesDir,
        config: _withZen(cfg, port: port, models: models),
      );
      debugPrint('[dsh-zen] 已写入 ${models.length} 个免费模型（端口 $port）');
      return (ok: true, error: null, models: models.length);
    } catch (e) {
      debugPrint('[dsh-zen] 写配置失败：$e');
      return (ok: false, error: tr('写模型配置失败：{0}', <Object?>['$e']), models: 0);
    }
  }

  /// 关闭：把厂家与它的模型从配置里摘掉，并停掉代理。
  ///
  /// ⚠️ **只摘自己那部分**：用户自己的厂家、模型、轮换池一个都不能动。
  static Future<void> disable({required DshRuntime runtime}) async {
    try {
      final cfg = ConfiguredModels.readConfig(runtime.filesDir);
      if (cfg.providers.any((p) => p.id == providerId) ||
          cfg.models.any((m) => m.provider == providerId)) {
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
            // 选中的如果正好是免费通道的模型，退回"没选"（让界面自己挑一个），
            // 而不是留一个已经不存在的 route。
            selected: (cfg.selected ?? '').startsWith('$providerId/')
                ? null
                : cfg.selected,
          ),
        );
      }
    } catch (e) {
      debugPrint('[dsh-zen] 关闭时清理配置失败（不影响停代理）：$e');
    }
    await ZenProxy.instance.stop();
  }

  /// 启动时调用：若开关是开的，就把端口与模型列表刷新一遍。
  ///
  /// 为什么每次启动都要刷：端口是系统随机分配的（见类注释），配置里那份
  /// 昨天的 `baseUrl` 今天一定是错的。
  static Future<void> refreshIfEnabled({
    required bool enabled,
    required DshRuntime runtime,
  }) async {
    if (!enabled) {
      // 开关关着但配置里还留着上次的痕迹（比如用户在别处改过配置）→ 清掉。
      await disable(runtime: runtime);
      return;
    }
    final r = await enable(runtime: runtime);
    if (r.ok) return;
    // ⚠️ 刷新失败就把免费模型**从配置里摘掉**，而不是留着指向一个已经失效的本地端口
    // —— 留着的话用户会在模型列表里看到一批"选了就报错"的模型，比"暂时没有它"更糟。
    debugPrint('[dsh-zen] 启动刷新失败（先把免费模型摘掉）：${r.error}');
    _lastRefreshError = r.error;
    await disable(runtime: runtime);
  }

  /// 上一次启动刷新的失败原因（设置页显示用；进程内有效）。
  static String? _lastRefreshError;
  static String? get lastRefreshError => _lastRefreshError;

  /// 清楚记录/清除上次错误（用户在设置页手动重试成功时调用）。
  static void clearRefreshError() => _lastRefreshError = null;

  /// 现在通不通（设置页显示状态用）。
  static Future<({bool running, int? port, int models, String? lastError})> status() async {
    final port = ZenProxy.instance.port;
    if (port == null) {
      return (running: false, port: null, models: 0, lastError: null);
    }
    final h = await ZenProxy.instance.health(port);
    return (
      running: true,
      port: port,
      models: h?.models ?? 0,
      lastError: h?.lastError,
    );
  }

  static ConfiguredConfig _withZen(
    ConfiguredConfig cfg, {
    required int port,
    required List<String> models,
  }) {
    return ConfiguredConfig(
      version: cfg.version,
      providers: <ProviderSpec>[
        // 先摘掉旧的自己（端口变了要覆盖），再追加一份新的
        for (final p in cfg.providers)
          if (p.id != providerId) p,
        ProviderSpec(
          id: providerId,
          label: label,
          baseUrl: 'http://127.0.0.1:$port/v1',
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

/// 让"是否已写入配置"这类判断可以离线测试（不碰进程/网络）。
bool zenConfiguredIn(ConfiguredConfig cfg) =>
    cfg.providers.any((p) => p.id == ZenChannel.providerId);

/// 仅供测试：暴露"把 zen 写进配置"的纯函数（不启动任何进程）。
ConfiguredConfig zenConfigForTest(
  ConfiguredConfig cfg, {
  required int port,
  required List<String> models,
}) =>
    ZenChannel._withZen(cfg, port: port, models: models);

/// 某条 route 是不是"社区免费通道"的（界面据此加标注）。
bool isZenRoute(String? route) =>
    (route ?? '').startsWith('${ZenChannel.providerId}/');
