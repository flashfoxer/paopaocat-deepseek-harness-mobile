/// 「进程启动时到底吃进去了哪些配置」——切模型时**用它决定要不要重建会话**。
///
/// ## 为什么要有这个文件（用户 2026-10-15 第 1 条）
///
/// 用户原话：「切换模型不要重建会话，看看有没有这个问题发生」。
///
/// 老口径是"整份配置指纹变了就重建会话"。这太粗：用户改的是**别的厂家**
/// （或者只是勾了一个新模型），跟当前这条路由毫无关系，却会让正在聊的会话
/// 重启进程 —— 而真机日志里那种"提示说没重建、实际换了会话"就是这么来的。
///
/// 正确的判据是**这条路由自己的管路**：
///   * 它属于哪个 provider（`api` / `baseUrl` / `apiKeyEnv`）；
///   * 那个 provider 的 **Key 现在的值**（Key 变了必须重建，否则进程还拿着旧 Key
///     —— 这正是老注释里"切一下看起来成功、请求却带旧 Key"那个坑）；
///   * 这条路由对应的模型条目（`context` 之类）；
///   * 如果它是**轮换组**，还有成员清单。
///
/// 这些东西没变 → 运行时的注册表跟配置仍然对得上 → **会话内直接切模型**
/// （`session/set_config_option`），一个进程都不用重启。
///
/// ## 为什么是纯函数
///
/// 这条逻辑的三种输入（配置 / Key / 选中的路由）在界面层很难构造，
/// 抽成纯函数才能直接测：见 `test/spawn_signature_test.dart`。
library;

import '../data/configured_models.dart';

/// 某个 provider 的"管路指纹"。
///
/// 看不到这个 provider 时返回 `''`（调用方据此判"这条路由没注册过"）。
String providerPlumbing({
  required ConfiguredConfig cfg,
  required Map<String, String> keys,
  required String providerId,
}) {
  final id = providerId.trim();
  if (id.isEmpty) return '';

  final buf = StringBuffer()..writeln('v${cfg.version}');

  // ⚠️ 轮换组必须**先处理**：`rotate` 是个**虚拟厂家**，它不出现在
  // `cfg.providers` 里 —— 走下面的"查不到就返回空串"，整组信息会被吞掉
  // （自测当场抓到：改了组里的成员，管路却一动不动 = 新成员没进过进程）。
  if (id == ConfiguredModels.rotateProviderId) {
    final groups = cfg.groups.toList()
      ..sort((a, b) => a.route.compareTo(b.route));
    for (final g in groups) {
      buf.writeln('g:${g.route}|${g.members.join(',')}');
      // 组里每个成员**各自的管路**也算进来：成员的 Key/端点变了，这条组的转发同样要重建。
      for (final mem in g.members) {
        final mp = providerOfRoute(mem);
        if (mp.isEmpty || mp == ConfiguredModels.rotateProviderId) continue;
        buf.writeln(
            'gm:$mem|<${providerPlumbing(cfg: cfg, keys: keys, providerId: mp)}>');
      }
    }
    return buf.toString();
  }

  ProviderSpec? p;
  for (final x in cfg.providers) {
    if (x.id == id) {
      p = x;
      break;
    }
  }
  if (p == null) return '';

  buf.writeln('p:${p.id}|${p.api}|${p.baseUrl}|${p.apiKeyEnv}');
  // Key 的**值**也算进来（只用于本地比较，绝不落日志）：
  // 同厂家只改了 Key 时，overlay 文本一模一样、只有环境变量变了。
  //
  // ⚠️ 取的是"这个 provider 声明的环境变量名"对应的值；`ProviderKeys.envFor`
  // 对 zen/local 这类"App 自己提供凭据"的厂家会注入占位值，所以这里也拿得到。
  buf.writeln('k:${p.apiKeyEnv}=${keys[p.apiKeyEnv] ?? ''}');

  // 这个厂家的模型条目（模型清单变了 = 进程里的注册表过期了）
  final models = cfg.models.where((m) => m.provider == id).toList()
    ..sort((a, b) => a.route.compareTo(b.route));
  for (final m in models) {
    buf.writeln('m:${m.route}|${m.context ?? 0}');
  }

  return buf.toString();
}

/// 从 route（`provider/model` 或 `rotate/组名`）取出 provider 段。
String providerOfRoute(String route) {
  final i = route.indexOf('/');
  return i <= 0 ? '' : route.substring(0, i);
}

/// 当前选中路由的"管路指纹"；取不到（没选 / 没注册）返回空串。
String selectedRoutePlumbing({
  required ConfiguredConfig cfg,
  required Map<String, String> keys,
  required String route,
  required String legacyKey,
}) {
  final provider = providerOfRoute(route);
  final body = providerPlumbing(
    cfg: cfg,
    keys: keys,
    providerId: provider,
  );
  // 老键（对话页齿轮那个 v1 设置页写的是它，会被注入成 COM_/DEEPSEEK_/OPENAI_API_KEY）
  // 只放"变没变"的标记 + 值（仅本地比较，不落日志）。
  return '$body legacy:$legacyKey';
}
