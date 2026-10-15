import 'dart:io';

/// 「会话里能用什么」—— 把**出厂运行时里已经装好、但要由 App 的 overlay 去激活**的能力，
/// 生成成 cordis patch 片段（YAML）。
///
/// 为什么要有这一层：App 的 overlay（`model.overlay.yml`）是**唯一**由 App 掌控的
/// 配置层（`--patch`），而这两件事都属于"运行时里有、但要按用户的选择改钉"：
///
///   ① **联网搜索的后端**：出厂 `dsh-base` 那一层把 `web` 这行的 `searchProvider`
///      钉死在 `deepseek-official`（那家要 `DEEPSEEK_API_KEY`）。运行时里若带了
///      `@deepseek-ai/dsh-web-search-anysearch`，就改钉到 `anysearch`
///      —— **免 Key（匿名层可用）**，这正是「不用填 Key 也能搜」的实现。
///      ⚠️ **老运行包里没有这个插件** —— 那时**绝不能**写这几行：插件名解析不到，
///      会让整个会话起不来。所以调用方必须先 [runtimeHasAnysearchPlugin]。
///
///   ② **子智能体**：出厂是开着的（`dsh-tool-subagent` / `-fork` / `-control`）。
///      用户关掉时按 id 覆盖成 `disabled: true`；指定了模型时覆盖 `tool-subagent`
///      的 `config`（⚠️ patch 是**整段 config 替换**、不是合并，所以必须写全）。
///
/// ⚠️ **所有字符串值都要加引号**（`_q`）：YAML 会把裸写的纯数字当整数，
/// 而 DSH 校验这些字段必须是字符串 —— 2026-10-10 那次"纯数字模型名炸掉全部模型"
/// 就是漏了引号（见 `writeOverlayFromConfig` 的长注释）。
class SessionCapabilities {
  SessionCapabilities._();

  /// 运行时里那个搜索后端插件的相对路径（相对于解包根 `filesDir/dsh`）。
  ///
  /// 打包链把 `runtime-plugins/dsh-web-search-anysearch` 放进运行时压缩包的
  /// `app/node_modules/@deepseek-ai/` 下，解包后就是这个位置。
  static const String anysearchPluginRelPath =
      'node_modules/@deepseek-ai/dsh-web-search-anysearch';

  /// 运行时里有没有这个插件（有才敢在 overlay 里引用它）。
  ///
  /// [runtimeRoot] = 解包根（App 里是 `<filesDir>/dsh`）。
  static bool runtimeHasAnysearchPlugin(String runtimeRoot) {
    if (runtimeRoot.trim().isEmpty) return false;
    return Directory('$runtimeRoot/$anysearchPluginRelPath').existsSync();
  }

  /// 「会话里的联网搜索走 AnySearch（免 Key）」的 patch 片段。
  ///
  /// 两行缺一不可：
  ///   * 覆盖 `web` 这一行的 `searchProvider`（**整段 config 替换**，所以
  ///     `fetchProvider` 必须一起重写，否则抓网页那半边会退化）；
  ///   * `- insert:` 把后端插件挂进组合（出厂的 `web-search-deepseek` 仍留着，
  ///     但钉到 anysearch 之后它不会被选中）。
  static String nativeWebSearchPatch() {
    final b = StringBuffer();
    b.writeln();
    b.writeln('# ── 会话联网搜索：换用 AnySearch 后端（免 Key，匿名可用）───────────');
    b.writeln('# 出厂的 web 行钉的是 deepseek-official（要 DEEPSEEK_API_KEY）；');
    b.writeln('# 这里改钉到 anysearch —— 没有 Key 时就是匿名层（限流低，但能用）。');
    b.writeln('- id: web');
    b.writeln('  name: "@deepseek-ai/dsh-web"');
    b.writeln('  config:');
    b.writeln('    searchProvider: anysearch');
    b.writeln('    fetchProvider: http');
    b.writeln('- insert:');
    b.writeln('    - id: web-search-anysearch');
    b.writeln('      name: "@deepseek-ai/dsh-web-search-anysearch"');
    b.writeln('      config:');
    b.writeln('        apiKeyEnv: "ANYSEARCH_API_KEY"');
    return b.toString();
  }

  /// 子智能体相关的 patch 片段。返回空串 = 保持出厂（开着、跟随父会话的模型）。
  ///
  /// [enabled]=false：把这几个 id 覆盖成 `disabled: true`（服务与工具一起关，
  /// 避免留下"半个还活着"的状态）。
  ///
  /// [provider]/[model] 两个都给了才有意义：给 `tool-subagent`（后台可续那个）
  /// 指定子会话用哪家哪模型；`tool-subagent-fork` 刻意**不动** —— 它的语义是
  /// "继承父会话的历史"，换模型会让 KV 缓存失效、也就失去 fork 的意义。
  static String subagentPatch({
    required bool enabled,
    String? provider,
    String? model,
  }) {
    final b = StringBuffer();
    if (!enabled) {
      b.writeln();
      b.writeln('# ── 子智能体：按用户选择关闭 ──────────────────────────');
      b.writeln('# 工具与服务一起 disabled（见 data/session_capabilities.dart）。');
      for (final id in <String>[
        'tool-subagent',
        'tool-subagent-fork',
        'tool-subagent-control',
        'tool-subagent-list-agents',
        'subagent-spawn-in-process',
        'subagent-fork-in-process',
      ]) {
        b.writeln('- id: $id');
        b.writeln('  disabled: true');
      }
      return b.toString();
    }
    final p = (provider ?? '').trim();
    final m = (model ?? '').trim();
    if (p.isEmpty || m.isEmpty) return '';
    b.writeln();
    b.writeln('# ── 子智能体：指定子会话用哪家/哪个模型 ────────────────');
    b.writeln('# ⚠️ patch 是**整段 config 替换**，所以这里要把出厂那几项一起写全。');
    b.writeln('- id: tool-subagent');
    b.writeln('  name: "@deepseek-ai/dsh-tool-subagent"');
    b.writeln('  config:');
    b.writeln('    provider: spawn');
    b.writeln('    toolName: subagent');
    b.writeln('    backgroundMode: continuable');
    b.writeln('    agentOptions:');
    b.writeln('      provider: ${_q(p)}');
    b.writeln('      model: ${_q(m)}');
    return b.toString();
  }

  /// YAML 字符串一律加双引号（数字型名字不加引号会被解析成整数，见类注释）。
  static String _q(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}
