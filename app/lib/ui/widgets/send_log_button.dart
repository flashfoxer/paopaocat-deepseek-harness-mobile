import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../app_version.dart';
import '../../data/api_error_text.dart';
import '../../data/configured_models.dart';
import '../../data/developer_contact.dart';
import '../../local/diagnostics_log.dart';
import '../../local/local_model_server.dart';
import '../../local/dsh_runtime.dart';
import '../../state/provider_keys.dart';
import '../theme/dsh_tokens.dart';

import '../../i18n/dsh_i18n.dart';
import 'common.dart';

/// 「运行日志」入口：**自包含** widget —— 生成日志 → 导出到文件 / 分享出去。
///
/// 用户原话：「设置页面增加一个按钮，用户点击以后会生成一个日志并发送…这个日志主要
/// 是能看到运行中哪里出错了方便分析」。后来明确：「那就光做导出日志到文件/分享」。
///
/// ## 为什么不做"静默发邮件"
///
/// Android 上没有任何凭证的 App **没法自己发邮件**。可选只有两条：
///   * (A) 走系统：把日志交给系统界面（保存文件 / 分享面板），用户自己选落点 —— 本文件就是这条；
///   * (B) App 内置一个发件账号：要把邮箱密码/授权码打进 APK，**泄漏风险 + 用户改密码就废**，绝对不做。
///
/// 所以这里给两个出口，**都不需要任何服务器和密码**：
///   1. 「导出运行日志」→ 系统「保存文件」选择器（SAF，`ACTION_CREATE_DOCUMENT`），
///      文件名已预填，用户自己选保存位置（通常是"下载"）；
///   2. 「分享运行日志」→ 系统分享面板（复用 `DshHost.shareFile`），
///      微信 / QQ / 文件传输助手 / 邮件应用都行 —— **分享面板里选邮件就等价于发邮件**，
///      功能一点没少，只是不再由 App 内置收件人。
///
/// 两个出口都拉不起来时（[no_app]）不留死路：弹出日志的**绝对路径** + 一键复制。
///
/// ## 隐私（用户会逐字核对，别放松）
///
/// * 说明层**先说清楚**日志里有什么、没有什么，再动手；
/// * 日志正文里的 `sk-…` / `Bearer …` / `api_key|apiKey|token|password|AGNES_API_KEY=`
///   一律由 [DiagnosticsLog.redact] 替换成 `***已脱敏***`；
/// * 头部只写"厂家 id / 名字 / 模型数 / 有没有 Key（true/false）"，
///   **从不**读取安全区里的 Key 本体（只查 `containsKey`，连值都不碰）。
///
/// 插入设置页：`const SendLogButton()` 一行即可（它自己就是完整的卡片块）。
class SendLogButton extends StatefulWidget {
  const SendLogButton({super.key});

  @override
  State<SendLogButton> createState() => _SendLogButtonState();
}

class _SendLogButtonState extends State<SendLogButton> {
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  /// 固定收件人**不存在**（用户明确要求不做内置邮件）：分享面板里自己选。
  bool _busy = false;
  String _busyText = '';

  /// 最近一次生成的报告文件绝对路径（失败时的退路要用）。
  String? _lastReportPath;

  // ---------------------------------------------------------------- 两个出口

  /// [share] = true 走分享面板，false 走"保存文件"选择器。
  Future<void> _run({required bool share}) async {
    if (_busy) return;

    final agreed = await _confirmDialog(share: share);
    if (agreed != true) return;
    // ⚠️ 对话框是 await —— 用户可能在等它的时候把页面切走/关掉
    // （审计列的 4 处缺失 mounted 守卫之一）。dispose 之后 setState 会抛，
    // 后面的"生成日志/分享"流程也跟着一起乱。
    if (!mounted) return;

    setState(() {
      _busy = true;
      _busyText = context.tr('正在生成日志…');
    });
    String? path;
    try {
      path = await _generateReport();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _toast(context.tr('生成日志失败：{0}', [translateException(e).zh]),
            error: true);
      }
      return;
    }
    if (!mounted) return;
    if (path == null) {
      setState(() => _busy = false);
      _toast(context.tr('生成日志失败：拿不到 App 私有目录，无法落盘。'), error: true);
      return;
    }
    _lastReportPath = path;

    setState(() =>
        _busyText = share ? context.tr('正在打开分享面板…') : context.tr('正在打开保存界面…'));
    try {
      if (share) {
        await _share(path);
      } else {
        await _export(path);
      }
    } catch (e) {
      if (mounted) _toast(translateException(e).zh, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 出口 ①：系统「保存文件」选择器（SAF）。
  Future<void> _export(String path) async {
    // 预填的文件名只算一次：既交给选择器，也用在成功提示里
    // （SAF 回来的是 `.../document/3` 这种**没有文件名**的 uri，直接显示它用户看不懂）。
    final name = _friendlyFileName();
    final r = await DshHost.exportTextFile(fileName: name, sourcePath: path);
    if (!mounted) return;
    if (r.startsWith('ok:')) {
      // 成功要说清"存到哪儿了"：文件名 + 系统给的位置 uri。
      final uri = Uri.decodeFull(r.substring(3));
      _toast(context.tr('已保存：{0}\n系统位置：{1}', [name, uri]));
      return;
    }
    if (r == 'cancel') {
      // 取消不是错误：如实说，并给出退路（文件还在，可以复制路径或分享）。
      await _fallbackSheet(
        path,
        context.tr('你取消了保存 —— 日志文件已经生成好了，但还没有存到你选的位置。'),
      );
      return;
    }
    await _fallbackSheet(
      path,
      context.tr('这台手机没有可用的「保存文件」界面（系统返回 {0}）。', [r]),
    );
  }

  /// 出口 ②：系统分享面板（微信 / QQ / 文件传输助手 / 邮件…）。
  ///
  /// ⚠️ 这里以前**没有 try/catch**：原生抛异常（例如路径不在 FileProvider
  /// 白名单里）会直接冒到 Flutter 的未处理异常通道，用户只看到"没反应"。
  /// 现在失败也留一行日志，并给退路（复制路径 / 改用保存）。
  Future<void> _share(String path) async {
    final String r;
    try {
      r = await DshHost.shareFile(
        path,
        subject: context.tr('泡泡猫的DSH 运行日志 v{0}', [kAppVersion]),
      );
    } catch (e) {
      debugPrint('[dsh-log-ui] 分享失败 $path：$e');
      if (!mounted) return;
      await _fallbackSheet(path, context.tr('分享失败：{0}', <Object?>['$e']));
      return;
    }
    if (!mounted) return;
    if (r == 'ok') {
      debugPrint('[dsh-log-ui] 分享 $path -> ok');
      _toast(context.tr('已打开分享面板，选一个应用发出去即可。'));
      return;
    }
    debugPrint('[dsh-log-ui] 分享 $path -> $r（没有可接收的应用，给退路）');
    await _fallbackSheet(
      path,
      context.tr('这台手机没有可接收分享的应用（系统返回 {0}）。', [r]),
    );
  }

  // ------------------------------------------------------------ 生成日志文件

  /// 引擎可执行文件是否真的在包里（看 nativeLibraryDir）。
  bool _enginePresent(String name) {
    final dir = _nativeLibDir;
    if (dir == null || dir.isEmpty) return false;
    return File('$dir/$name').existsSync();
  }

  String? _nativeLibDir;

  /// 组装报告（头部 + 环形缓冲快照），返回报告文件的绝对路径。
  Future<String?> _generateReport() async {
    Map<String, dynamic> paths = <String, dynamic>{};
    try {
      paths = await DshHost.getPaths();
    } catch (e) {
      debugPrint('[dsh-log-ui] 读私有目录失败：$e');
    }
    final filesDir = paths['filesDir'] as String? ?? '';
    _nativeLibDir = paths['nativeLibDir'] as String?;

    // 兜底：万一 main.dart 那一步没跑成（例如原生通道异常），这里再补一次初始化，
    // 否则报告根本写不出来。
    if (DiagnosticsLog.logFilePath == null && filesDir.isNotEmpty) {
      await DiagnosticsLog.init(filesDir: filesDir);
    }

    final info = await DshHost.deviceInfo();
    final cfg = filesDir.isEmpty
        ? ConfiguredConfig.empty
        : ConfiguredModels.readConfig(filesDir);
    final keyFlags = await _keyFlags(cfg);

    final header = <String>[
      tr('App 名：泡泡猫的DSH（本地 DSH 运行时）'),
      tr('App 版本：v{0}{1}', [
        kAppVersion,
        info['versionName'] == null
            ? ''
            : '（安装包 versionName=${info['versionName']}）'
      ]),
      'versionCode：${info['versionCode'] ?? '未知'}',
      tr('包名：{0}', [info['packageName'] ?? '未知']),
      tr('构建类型：{0}', [info['isDebug'] == true ? 'debug（调试包）' : 'release']),
      // 芯片与内存：判断"这台机器该跑多大模型"的第一依据。
      if ((info['soc'] as String?)?.isNotEmpty ?? false)
        tr('芯片：{0}', [info['soc']]),
      if ((info['totalRamGb'] as num?) != null)
        tr('内存：{0} GB', ['${info['totalRamGb']}']),
      // 引擎到底在不在包里 —— 以前报告里没有这一行，排查时得先问用户"你那包带引擎吗"。
      //
      // ⚠️ 现在包里**只该有 LiteRT-LM**：
      //   * llama.cpp 自 0.47 起**有意不再随包**（"路线 A"；真机实证它在 Armv9.2 上
      //     处理长请求必然段错误）；
      //   * stable-diffusion 已于 2026-10-11 **整条删除**（纯死重，压缩后约 15.4 MiB）。
      // 这两项都保留在报告里、且都显示"无" —— 是**有意**如此，不是这个包缺东西；
      // 万一哪天它们变成"有"，反而说明出包配置被改动过（这才是排查要看的信号）。
      tr('引擎：LiteRT-LM {0} · stable-diffusion（已删除）{1} · llama（已下线）{2}', [
        _enginePresent('liblitertlm_jni.so') ? '有' : '无',
        _enginePresent('libsdserver.so') ? '有' : '无',
        _enginePresent('libllamaserver.so') ? '有' : '无',
      ]),
      // 服务此刻在跑什么参数（上下文/后端/端口）—— 上下文是近期最常见故障点。
      // ⚠️ 必须**调用**：漏掉括号时报告里会打印
      // `Closure: () => String from Function 'statusText':.`（真机日志抓到过）。
      tr('本地模型服务：{0}', [LocalModelServer.instance.statusText()]),
      tr('机型：{0} {1}（brand={2}, device={3}）', [
        info['manufacturer'] ?? '?',
        info['model'] ?? '?',
        info['brand'] ?? '?',
        info['device'] ?? '?'
      ]),
      'Android：${info['androidRelease'] ?? '?'}（SDK ${info['sdkInt'] ?? '?'}）',
      'ABI：${_listText(info['abis'])}',
      tr('屏幕：{0}x{1} px，密度 {2}（{3} dpi）', [
        info['screenWidthPx'] ?? '?',
        info['screenHeightPx'] ?? '?',
        info['density'] ?? '?',
        info['densityDpi'] ?? '?'
      ]),
      tr('系统语言：{0}', [info['locale'] ?? '?']),
      tr('当前选中 route：{0}', [cfg.selected ?? '（未设置）']),
      tr('已有模型数（models.json）：{0}', [cfg.models.length]),
      tr('启动次数：{0}', [DiagnosticsLog.launchCount]),
      tr('落盘日志文件：{0}', [DiagnosticsLog.logFilePath ?? '（未初始化）']),
      '',
      // 这份报告是 **.txt**（见 _suggestedName 的 `...日志-...txt`），
      // 里面的 `**` 只会被当成字面星号 —— 纯文本文档不需要强调标记。
      tr('已配置厂家（只列 id / 名字 / 模型数 / 有没有 Key，绝不列 Key 本身）：'),
    ];
    if (cfg.providers.isEmpty) {
      header.add(tr('  （没有配置任何厂家）'));
    } else {
      for (final p in cfg.providers) {
        final count = cfg.models.where((m) => m.provider == p.id).length;
        header.add(
          tr('  - {0}（{1}）· 模型 {2} 个 · Key：{3}',
              [p.id, p.label, count, keyFlags[p.id] == true ? '有' : '没有']),
        );
      }
    }
    if (cfg.groups.isNotEmpty) {
      header.add(tr('轮换组：'));
      for (final g in cfg.groups) {
        header.add(tr('  - {0}（{1} 个成员）', [g.name, g.members.length]));
      }
    }

    // 本地模型的**崩溃记录**（用户 2026-10-12：「本地大模型使用，经常性的发生闪退」）。
    // 这份记录 0.26 起就在（用于"崩过就自动换后端"），但**报告里一直没有它** ——
    // 于是"经常闪退"的反馈对不上账：哪个模型、哪个后端、崩过几次，全在盘上没人看。
    final crashes = await DiagnosticsLog.crashRecordLines();
    if (crashes.isNotEmpty) {
      header.add('');
      header.add(tr('本地模型崩溃记录（模型 | 后端：次数）—— 用于"闪退"定位：'));
      header.addAll(crashes);
    }

    DiagnosticsLog.hintAppVersion(kAppVersion);
    final path = await DiagnosticsLog.writeToFile(headerLines: header);
    if (path == null) return null;
    debugPrint('[dsh-log-ui] 已生成运行日志报告：$path');
    return path;
  }

  /// 每个厂家"到底有没有 Key"。
  ///
  /// ⚠️ **这里连 Key 的值都不读**：只用 `containsKey`，所以安全区里的凭据永远
  /// 没有机会被写进日志。`dsh_model_provider` 那一个读的是"厂家 id"（不是凭据），
  /// 用来兼容 v1 时代只有一把 Key 的老用户。
  Future<Map<String, bool>> _keyFlags(ConfiguredConfig cfg) async {
    final flags = <String, bool>{};
    String? legacyProvider;
    bool legacyKeyExists = false;
    try {
      legacyProvider = await _secure.read(key: ProviderKeys.legacyProviderKey);
      legacyKeyExists =
          await _secure.containsKey(key: ProviderKeys.legacyApiKeyKey);
    } catch (_) {
      // 安全区读不到（例如桌面/测试环境没有插件）：当成"没有 Key"，不瞎猜。
    }
    for (final p in cfg.providers) {
      var has = false;
      try {
        has = await _secure.containsKey(key: ProviderKeys.secureKeyFor(p.id));
      } catch (_) {}
      if (!has && legacyKeyExists) {
        final lp = (legacyProvider ?? '').trim();
        final same = lp.isEmpty ||
            ConfiguredModels.sanitizeProviderId(lp) ==
                ConfiguredModels.sanitizeProviderId(p.id);
        if (same) has = true;
      }
      flags[p.id] = has;
    }
    return flags;
  }

  /// 选择器里预填的文件名：`泡泡猫的DSH-日志-v0.11-20261004-1900.txt`。
  String _friendlyFileName() {
    final t = DateTime.now();
    String two(int v) => v < 10 ? '0$v' : '$v';
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
    return context.tr('泡泡猫的DSH-日志-v{0}-{1}.txt', [kAppVersion, stamp]);
  }

  static String _listText(Object? v) {
    if (v is List) {
      final parts =
          v.map((e) => '$e').where((e) => e.trim().isNotEmpty).toList();
      return parts.isEmpty ? tr('未知') : parts.join(', ');
    }
    return v?.toString() ?? tr('未知');
  }

  // ---------------------------------------------------------------- 交互层

  /// 说明层：**先说清楚再动手**（用户要求"诚实告知"）。
  Future<bool?> _confirmDialog({required bool share}) {
    final action = share ? context.tr('分享') : context.tr('保存');
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(share ? context.tr('分享运行日志') : context.tr('导出运行日志')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.tr('这份日志是为了让开发者看出"运行中哪里出错了"。它会包含：'),
                style:
                    TextStyle(color: DshColors.text, fontSize: 13, height: 1.6),
              ),
              const SizedBox(height: 8),
              _bullet(context.tr('App 版本、机型、系统版本、屏幕与语言')),
              _bullet(context.tr('最近的运行输出与错误信息（含 DSH 运行时的输出）')),
              _bullet(context.tr('你配置了哪些厂家（只写名字和"有没有 Key"）')),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: DshColors.panel(
                  radius: DshMetrics.controlRadius,
                  color: DshColors.accentDim,
                  glow: false,
                ),
                child: DshRichText(
                  context.tr('API Key 已自动脱敏（会变成 ***已脱敏***），**不会**包含你的 Key。'),
                  style: TextStyle(
                    color: DshColors.text,
                    fontSize: 12.5,
                    height: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                share
                    ? context.tr(
                        '点下面按钮后会打开系统的分享面板：发给微信 / QQ / 文件传输助手 / 邮件都行，发给谁由你决定。')
                    : context.tr('点下面按钮后会打开系统的「保存文件」界面：存到哪儿由你决定（一般是"下载"目录）。'),
                style: TextStyle(
                    color: DshColors.textDim, fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 10),
              // 用户 2026-10-04 明确要求：弹窗里写上开发者邮箱。
              // 为什么要写出来：日志本身不会替用户发送，用户得知道**发给谁**才有意义。
              // 地址是可选中文本，方便在手机上长按复制（粘进邮件 / 微信）。
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr('开发者邮箱：'),
                    style: TextStyle(
                      color: DshColors.textDim,
                      fontSize: 12.5,
                      height: 1.6,
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      kDeveloperEmail,
                      style: TextStyle(
                        color: DshColors.accent,
                        fontSize: 12.5,
                        height: 1.6,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('生成并{0}', [action])),
          ),
        ],
      ),
    );
  }

  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('· ', style: TextStyle(color: DshColors.accent, fontSize: 13)),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                    color: DshColors.textDim, fontSize: 12.5, height: 1.5),
              ),
            ),
          ],
        ),
      );

  /// 退路：系统界面拉不起来 / 用户取消时，至少让日志路径可复制，不留死路。
  Future<void> _fallbackSheet(String path, String reason) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(16),
          decoration: DshColors.panel(
              radius: DshMetrics.panelRadius,
              // 弹层：不透明（见 dsh_tokens 里 bottomSheetTheme 的说明）
              color: DshColors.surfaceStrong),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr('日志已生成，但没能自动打开系统界面'),
                style: TextStyle(
                  color: DshColors.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(reason,
                  style: TextStyle(
                      color: DshColors.textDim, fontSize: 12.5, height: 1.6)),
              const SizedBox(height: 12),
              Text(context.tr('日志文件的完整路径（长按可选中）'),
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: DshColors.panel(
                  radius: DshMetrics.controlRadius,
                  color: DshColors.codeBg,
                  glow: false,
                ),
                child: SelectableText(
                  path,
                  style:
                      DshFonts.code(color: DshColors.codeText, fontSize: 11.5),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.tr('这个文件夹在 App 私有目录里，其它应用读不到；「分享」或「复制路径」都能把它交出去。'),
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 11, height: 1.5),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: path));
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        if (mounted) _toast(context.tr('已复制日志路径到剪贴板。'));
                      },
                      icon: const Icon(Icons.copy_all_outlined, size: 16),
                      label: Text(context.tr('复制日志路径')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        // 退路里也给一次"分享"：很多机型 ACTION_CREATE_DOCUMENT 不响应，
                        // 但分享面板是有响应的，用户照样能把日志发出去。
                        await _share(path);
                      },
                      icon: const Icon(Icons.ios_share, size: 16),
                      label: Text(context.tr('改用它分享')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toast(String message, {bool error = false}) {
    // 顺手记进诊断日志：用户导出/分享的结果（成功、取消、失败原因）也是"运行到哪
    // 一步出了什么问题"的一部分，而 SnackBar 一关掉就没证据了。
    debugPrint('[dsh-log-ui] ${error ? '失败' : '结果'}：$message');
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? DshColors.err : null,
      ),
    );
  }

  // ------------------------------------------------------------------ 外观

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _tile(
          icon: Icons.save_alt,
          title: context.tr('导出运行日志'),
          note: context.tr('生成日志文件并选择保存位置（系统「保存文件」，零权限）'),
          onTap: () => _run(share: false),
        ),
        const SizedBox(height: 8),
        _tile(
          icon: Icons.ios_share,
          title: context.tr('分享运行日志'),
          note: context.tr('生成后打开系统分享面板（微信 / QQ / 文件传输助手 / 邮件都行）'),
          onTap: () => _run(share: true),
        ),
        if (_busy) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: DshColors.accent,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  _busyText,
                  style: TextStyle(color: DshColors.textDim, fontSize: 12),
                ),
              ),
            ],
          ),
        ],
        if (!_busy && _lastReportPath != null) ...[
          const SizedBox(height: 8),
          Text(
            context.tr('最近生成的日志：{0}', [_lastReportPath]),
            style: DshFonts.code(
                color: DshColors.textFaint, fontSize: 10.5, height: 1.5),
          ),
        ],
      ],
    );
  }

  /// 一个可点条目（图标 + 标题 + 说明 + 右箭头）。
  ///
  /// 刻意与设置页「关于」里那些条目的观感一致（玻璃面板 + 1px 细边 + 整行可点），
  /// 这样插进设置页之后不会显得是"另一个 App 的控件"。
  Widget _tile({
    required IconData icon,
    required String title,
    required String note,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      container: true,
      label: '$title：$note',
      child: InkWell(
        onTap: _busy ? null : onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          decoration: BoxDecoration(
            color: DshColors.surfaceHigh,
            borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
            border: Border.all(color: DshColors.line, width: 1),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: DshColors.accent),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: DshColors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      note,
                      style: TextStyle(
                        color: DshColors.textFaint,
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: DshColors.textDim),
            ],
          ),
        ),
      ),
    );
  }
}
