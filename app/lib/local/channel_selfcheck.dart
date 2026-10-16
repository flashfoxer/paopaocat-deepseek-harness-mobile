/// 通道自检：各个模型通道跑一次**最小请求**，把失败**按状态码分类**成人话 + 下一步。
///
/// ## 为什么需要它（用户 2026-10-16 提的「探查机制」第 ① 层）
///
/// 真机上"模型用不了"有好几种完全不同的原因，但它们**表现出来的都是"失败了"**：
///   * **403**：上游把请求当成非官方客户端（zen 就明确这么干，见 zen-proxy 的实测表）；
///   * **404**：接口或**模型名已退役**（DeepSeek 的 V3/R1 名字就是这种）；
///   * **401**：Key 不对/过期；
///   * **429 / 5xx**：限流或上游自身问题；
///   * 连不上：手机网络 / 代理 / 本机服务没起来。
///
/// 用户看不出区别（都是一句英文报错），我也得靠猜。**分类之后**：既能当场告诉用户
/// 怎么办，也能一键把结果发给我，我拿着分类去社区核对（第 ② 层）。
///
/// ⚠️ 自检**只用公开端点 + 用户已存的 Key**，不做任何写操作、不上传任何东西。
/// 报告里 Key 由 `DiagnosticsLog` 统一脱敏。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../state/app_settings.dart';
import '../state/provider_keys.dart';

/// 一次探测的结论。
enum ChannelOutcome {
  /// 通。
  ok,

  /// 没配（没打开 / 没 Key）—— 不是故障。
  notConfigured,

  /// 连不上：超时 / DNS / 网络不通。
  network,

  /// 403：上游把请求当成非官方客户端。
  blocked,

  /// 404：接口或模型名已退役。
  gone,

  /// 401：Key 不行。
  auth,

  /// 429：限流。
  rateLimited,

  /// 5xx：上游自身问题。
  server,

  /// 其它（例如返回了但形状不认识）。
  unknown,
}

/// 一个通道的检查结果。
class ChannelCheck {
  const ChannelCheck({
    required this.id,
    required this.title,
    required this.outcome,
    required this.detail,
    required this.next,
  });

  /// 稳定 id（日志里用来区分）。
  final String id;

  /// 界面上的名字。
  final String title;

  final ChannelOutcome outcome;

  /// 事实：状态码/错误原文（**不含 Key**）。
  final String detail;

  /// 给用户看的下一步（人话）。
  final String next;

  bool get ok => outcome == ChannelOutcome.ok;

  /// 一句话结论（界面与日志共用）。
  String get label => switch (outcome) {
        ChannelOutcome.ok => '正常',
        ChannelOutcome.notConfigured => '未启用',
        ChannelOutcome.network => '连不上（网络）',
        ChannelOutcome.blocked => '被上游拒绝（403：当成非官方客户端）',
        ChannelOutcome.gone => '接口或模型名已退役（404）',
        ChannelOutcome.auth => 'Key 无效（401）',
        ChannelOutcome.rateLimited => '被限流（429）',
        ChannelOutcome.server => '上游自身故障（5xx）',
        ChannelOutcome.unknown => '未知（需要人工看）',
      };

  /// 日志/报告里的一行（**这是"一键发给开发者"的主要内容**）。
  String toLogLine() => '[$id] $title → $label ｜ $detail ｜ 下一步：$next';
}

class ChannelSelfCheck {
  ChannelSelfCheck._();

  /// 超时：自检要"快"，不能让人等半分钟。
  static const Duration timeout = Duration(seconds: 12);

  /// 跑全部检查。**不会抛**（单个通道失败就是一条结论）。
  static Future<List<ChannelCheck>> run({
    required AppSettings settings,
  }) async {
    final out = <ChannelCheck>[];

    // ① Pollinations（免 Key 通道；默认开）
    if (!settings.polliEnabled) {
      out.add(const ChannelCheck(
        id: 'polli',
        title: '免费模型（无需 Key）',
        outcome: ChannelOutcome.notConfigured,
        detail: '开关是关的',
        next: '要用就回「设置 → 模型」把「免费模型（无需 Key）」打开。',
      ));
    } else {
      out.add(await _probe(
        id: 'polli',
        title: '免费模型（无需 Key）',
        url: 'https://text.pollinations.ai/openai/models',
        key: null,
        onOk: (n) => '拿到 $n 个模型',
        nextOk: '直接就能用，不用填 Key。',
      ));
    }

    // ② OpenCode Zen（免 Key 通道；默认关，且经本地代理）
    if (!settings.zenEnabled) {
      out.add(const ChannelCheck(
        id: 'zen',
        title: 'OpenCode Zen（免 Key）',
        outcome: ChannelOutcome.notConfigured,
        detail: '开关是关的',
        next: '要用就回「设置 → 模型」把 Zen 那条打开（它经 App 内代理转发）。',
      ));
    } else {
      // ⚠️ Zen 的免费层**只认它自家 CLI 的形状**：User-Agent 里带 `deepseek-harness`
      //    一律 403（这是 zen-proxy.mjs 里实测出来的表）。自检必须用**同一个伪装**，
      //    否则会把"我们自己的探测被拒"误报成"用户这边坏了"。
      out.add(await _probe(
        id: 'zen',
        title: 'OpenCode Zen（免 Key）',
        url: 'https://opencode.ai/inference/v1/models',
        key: 'public',
        userAgent: 'opencode/1.18.0',
        onOk: (n) => '拿到 $n 个免费模型',
        nextOk: '这条通道是好的（模型清单随时会变，以「获取模型」拉到的为准）。',
      ));
    }

    // ③ 用户自己配了 Key 的厂家（逐一看，只探有 Key 的）
    for (final p in _customProviders) {
      final key = (await ProviderKeys.read(p.id))?.trim();
      if (key == null || key.isEmpty) {
        out.add(ChannelCheck(
          id: p.id,
          title: p.title,
          outcome: ChannelOutcome.notConfigured,
          detail: '没有存 Key',
          next: '要用就回「设置 → 模型」填上它的 API Key。',
        ));
        continue;
      }
      out.add(await _probe(
        id: p.id,
        title: p.title,
        url: '${p.baseUrl}/models',
        key: key,
        onOk: (n) => '拿到 $n 个模型',
        nextOk: '这条是好的。',
      ));
    }

    return out;
  }

  /// 有 Key 才需要自检的厂家（内置那几张卡的固定端点）。
  static const List<({String id, String title, String baseUrl})> _customProviders =
      <({String id, String title, String baseUrl})>[
    (id: 'deepseek', title: 'DeepSeek 官方', baseUrl: 'https://api.deepseek.com'),
    (id: 'agnes', title: 'Agnes', baseUrl: 'https://api.agnes-ai.cn/v1'),
    (id: 'mimo', title: 'MiMo（小米）', baseUrl: 'https://api.mimo.ai/v1'),
  ];

  /// 一次 `GET <url>/…` 探测 → 结论。
  static Future<ChannelCheck> _probe({
    required String id,
    required String title,
    required String url,
    required String? key,
    required String Function(int models) onOk,
    required String nextOk,
    String? userAgent,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (userAgent != null) {
        req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      }
      if (key != null && key.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      }
      final res = await req.close().timeout(timeout);
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final code = res.statusCode;

      if (code == 200) {
        // 数一下有几个模型（形状不认识也不当失败：能 200 就说明通道是通的）
        var n = 0;
        try {
          final j = jsonDecode(body);
          final data = (j is Map) ? j['data'] : null;
          if (data is List) n = data.length;
        } catch (_) {}
        return ChannelCheck(
          id: id,
          title: title,
          outcome: ChannelOutcome.ok,
          detail: 'HTTP 200，${onOk(n)}',
          next: nextOk,
        );
      }
      return ChannelCheck(
        id: id,
        title: title,
        outcome: _classify(code),
        detail: 'HTTP $code',
        next: _nextFor(_classify(code)),
      );
    } on TimeoutException {
      return ChannelCheck(
        id: id,
        title: title,
        outcome: ChannelOutcome.network,
        detail: '超时（${timeout.inSeconds}s 没响应）',
        next: _nextFor(ChannelOutcome.network),
      );
    } on SocketException catch (e) {
      return ChannelCheck(
        id: id,
        title: title,
        outcome: ChannelOutcome.network,
        detail: '连不上：${e.osError?.message ?? e.message}',
        next: _nextFor(ChannelOutcome.network),
      );
    } catch (e) {
      debugPrint('[selfcheck] $id 探测异常：$e');
      return ChannelCheck(
        id: id,
        title: title,
        outcome: ChannelOutcome.unknown,
        detail: '$e',
        next: _nextFor(ChannelOutcome.unknown),
      );
    } finally {
      client.close(force: true);
    }
  }

  static ChannelOutcome _classify(int code) => switch (code) {
        401 => ChannelOutcome.auth,
        403 => ChannelOutcome.blocked,
        404 => ChannelOutcome.gone,
        429 => ChannelOutcome.rateLimited,
        >= 500 => ChannelOutcome.server,
        _ => ChannelOutcome.unknown,
      };

  /// 每种结论给一句**能照着做**的下一步（不写"请检查配置"这种空话）。
  static String _nextFor(ChannelOutcome o) => switch (o) {
        ChannelOutcome.network =>
          '先确认手机能上网（换 WiFi/流量试一下）；如果用代理，看代理是否在跑。',
        ChannelOutcome.blocked =>
          '上游把请求当成"非官方客户端"拒了。这条通道可能已经变了，把自检结果发给开发者核对。',
        ChannelOutcome.gone =>
          '接口或**模型名已经退役**（名字换了就会这样）：回「设置 → 模型」点「获取模型」拉一份新的清单，重新勾选保存。',
        ChannelOutcome.auth => 'Key 不对或过期了 —— 回「设置 → 模型」重新填一把再点「测试并保存」。',
        ChannelOutcome.rateLimited => '被限流了：等一会儿再试，或换一个模型。',
        ChannelOutcome.server => '上游自己出问题了，过一会儿再试（不是你的配置问题）。',
        _ => '把自检结果发给开发者看一下（里面没有 Key）。',
      };
}
