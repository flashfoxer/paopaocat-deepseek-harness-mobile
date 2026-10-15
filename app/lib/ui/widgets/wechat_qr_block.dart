import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, rootBundle;

import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart' show DshHost;
import '../theme/dsh_tokens.dart';

/// 公众号二维码（**长按出三条动作**）。
///
/// ## 为什么要有这个组件（原 `settings_tab.dart` 里的私有 `_QrBlock` 已被它取代）
///
/// 原来的长按只有一件事：调 `openWechatScan()`，然后弹一句"已打开微信扫一扫"。
/// **那句话现在是假的**：`weixin://dl/scan` 是微信的**内部** scheme，微信已经拒绝
/// 外部调用 —— 本机实测长按后弹出来的是微信自己的错误页「对不起，当前页面无法访问」
/// （社区实证一致："以前可以，现在不行了"）。原生侧以前"只要 Intent 被任何应用接住
/// 就返回 ok"，于是变成了"说谎的成功"：页面是微信画的错误页，App 却在道贺。
///
/// 所以这里给用户**两条真的走得通的路**，把"唤起微信"降级成第三选项：
///
///   1. **复制公众号 ID**（`paopaocat888`）—— 去微信搜索框粘贴，一定能关注；
///   2. **把二维码存到相册** —— 走「微信 → 扫一扫 → 右上角相册 → 选这张图」，
///      这条路不依赖任何 scheme；
///   3. **仍然试一次唤起微信扫一扫** —— 试可以试，但**结果如实说**：
///      拉起来了就说"只是把微信拉起来了"，并提醒它可能显示"页面无法访问"。
///
/// ## 硬约束
///
///   * 卡片外观与原 `_QrBlock` **逐字保留**（白底 / 圆角 / 1px 边 / 156×156 的图
///     与占位文案）—— 不要重画、不要改尺寸；
///   * **任何情况下都不许说"已打开微信扫一扫"**，也不许说"已进入公众号"；
///   * 每个分支的提示都要与原生返回码一一对应（`ok` / `bad_path` / `no_wechat` /
///     `failed:…`），存没存进去、拉没拉起来都是用户看得见的事实。
class WechatQrBlock extends StatelessWidget {
  const WechatQrBlock({super.key, required this.filesDir});

  /// App 私有目录（`DshHost.filesDir`）：asset 先落成这里的真实文件，
  /// 才有路径可以交给原生去写系统相册。
  final String filesDir;

  /// 二维码资源（与原 `_QrBlock.assetPath` 同一个）。
  static const String assetPath = 'assets/images/wechat_qr.png';

  /// 公众号 ID —— 复制那一条用的原文。界面上的展示串在调用方那边，改这里不影响它。
  static const String publicAccountId = 'paopaocat888';

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 让整块（含白底内边距）都能长按，不用精确戳到图
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _showActions(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _qrCard(context),
          const SizedBox(height: 6),
          // 手势是隐式的，不写没人知道 —— 而且现在长按出来的是**三件事**，
          // 只说"唤起微信扫一扫"就把用户带偏了（那条路多半已经不通）。
          Text(
            context.tr('长按二维码：复制公众号 ID / 存到相册（微信扫一扫 → 相册选图）'),
            textAlign: TextAlign.center,
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 11, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// 长按 → 三项动作的底部弹层。
  ///
  /// ⚠️ `messenger` 与**全部文案**都在 `await` 之前取出来：await 之后再用
  /// `context` 会踩 `use_build_context_synchronously`（页面可能已经不在树上）。
  /// 与 settings_tab.dart 里原 `_QrBlock._longPress` 同一套写法。
  Future<void> _showActions(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    // 弹层里的三条标题/说明
    final copyTitle = context.tr('复制公众号 ID');
    final copySub = context.tr('去微信搜索框粘贴就能关注（ID：paopaocat888）。');
    final saveTitle = context.tr('把二维码存到相册');
    final saveSub = context.tr('存好后在微信「扫一扫 → 右上角相册」里选这张图。');
    final scanTitle = context.tr('仍然试一次唤起微信扫一扫');
    final scanSub =
        context.tr('只是试一下：微信已不响应这条指令时，它会显示「页面无法访问」。');
    // 点完之后的提示（每个返回码一条，不许混用）
    final copiedMsg = context.tr('公众号 ID 已复制。去微信搜索框粘贴就能关注。');
    final savedMsg =
        context.tr('二维码已存到系统相册。下一步：微信 → 扫一扫 → 右上角相册 → 选这张图。');
    final saveBadPathMsg = context.tr(
        '没找到要存的二维码图片（assets/images/wechat_qr.png 不在包里），存相册这一步跳过了。');
    final saveFailTemplate =
        context.tr('存相册没成功（{0}）。可以改用「复制公众号 ID」，或直接截屏这张二维码。');
    final scanOkMsg = context.tr(
        '已把微信拉起来。如果它显示「页面无法访问」，说明微信不响应这条指令 —— 请改用上面两种办法（复制 ID / 存相册）。');
    // `no_wechat` 现在**不只是**"没装微信"：原生侧改成先 resolveActivity 看接住的是不是
    // 微信本尊，所以"被浏览器之类的应用抢注了 weixin://"也走这个码 —— 文案得把
    // 这两种情况都覆盖，别把用户往"我明明装了微信"的死胡同里带。
    final scanNoWxMsg = context.tr(
        '没能唤起微信（可能是没装微信，或这条指令被别的应用接管了）—— 可以自己打开微信扫一扫再扫这张图。');
    final scanFailTemplate = context.tr('没能唤起微信（{0}），可以自己打开微信扫一扫。');

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            ListTile(
              leading: Icon(Icons.content_copy_outlined,
                  size: 20, color: DshColors.accent),
              title: Text(copyTitle,
                  style: TextStyle(color: DshColors.text, fontSize: 13)),
              subtitle: Text(copySub,
                  style: TextStyle(
                      color: DshColors.textFaint, fontSize: 11, height: 1.4)),
              onTap: () => Navigator.of(ctx).pop('copy'),
            ),
            ListTile(
              leading: Icon(Icons.download_outlined,
                  size: 20, color: DshColors.accent),
              title: Text(saveTitle,
                  style: TextStyle(color: DshColors.text, fontSize: 13)),
              subtitle: Text(saveSub,
                  style: TextStyle(
                      color: DshColors.textFaint, fontSize: 11, height: 1.4)),
              onTap: () => Navigator.of(ctx).pop('save'),
            ),
            ListTile(
              leading: Icon(Icons.qr_code_scanner_outlined,
                  size: 20, color: DshColors.textDim),
              title: Text(scanTitle,
                  style: TextStyle(color: DshColors.text, fontSize: 13)),
              subtitle: Text(scanSub,
                  style: TextStyle(
                      color: DshColors.textFaint, fontSize: 11, height: 1.4)),
              onTap: () => Navigator.of(ctx).pop('scan'),
            ),
          ],
        ),
      ),
    );

    // 用户是往下划掉的 → 什么都不说（弹层里没有"取消"这一项，别自作多情）。
    switch (action) {
      case 'copy':
        await _copyId(messenger, copiedMsg);
      case 'save':
        await _saveToGallery(
            messenger, savedMsg, saveBadPathMsg, saveFailTemplate);
      case 'scan':
        await _scanWechat(
            messenger, scanOkMsg, scanNoWxMsg, scanFailTemplate);
    }
  }

  /// 第 1 条：复制公众号 ID。**不依赖任何微信接口**，这条路一定通。
  Future<void> _copyId(ScaffoldMessengerState messenger, String okMsg) async {
    await Clipboard.setData(
        const ClipboardData(text: WechatQrBlock.publicAccountId));
    _toast(messenger, okMsg);
  }

  /// 第 2 条：asset → 私有目录的真实文件 → 系统相册。
  ///
  /// 三个返回码**分开说**（`ok` / `bad_path` / `failed:…`）；
  /// 连写盘或调原生本身抛了异常也如实报出来，不吞。
  Future<void> _saveToGallery(ScaffoldMessengerState messenger, String okMsg,
      String badPathMsg, String failTemplate) async {
    String msg;
    try {
      final data = await rootBundle.load(assetPath);
      final file = File('$filesDir/wechat_qr.png');
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      final r = await DshHost.saveImageToGallery(file.path);
      msg = r == 'ok'
          ? okMsg
          : r == 'bad_path'
              ? badPathMsg
              : _fill(failTemplate, r);
    } catch (e) {
      msg = _fill(failTemplate, '$e');
    }
    _toast(messenger, msg);
  }

  /// 第 3 条：仍然试一次唤起微信扫一扫 —— 但**只说"把微信拉起来了"**。
  Future<void> _scanWechat(ScaffoldMessengerState messenger, String okMsg,
      String noWxMsg, String failTemplate) async {
    String msg;
    try {
      final r = await DshHost.openWechatScan();
      msg = r == 'ok'
          ? okMsg
          : r == 'no_wechat'
              ? noWxMsg
              : _fill(failTemplate, r);
    } catch (e) {
      msg = _fill(failTemplate, '$e');
    }
    _toast(messenger, msg);
  }

  void _toast(ScaffoldMessengerState messenger, String msg) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 卡片外观：与原 `_QrBlock._qrCard` **逐字一致**（白底 / 圆角 / 0.8 边 / 156）。
  Widget _qrCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
        border: Border.all(color: DshColors.divider, width: 0.8),
      ),
      child: Image.asset(
        assetPath,
        width: 156,
        height: 156,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        errorBuilder: (context, error, stackTrace) => SizedBox(
          width: 156,
          height: 156,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              // 开发者会看到这个（用户正常看不到）：说明图该放哪儿。
              child: Text(
                context.tr('二维码待放入\nassets/images/wechat_qr.png\n放入后重新构建'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.black38, fontSize: 11, height: 1.6),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 把译文模板里的 `{0}` 换成实际值（与其它页面同一套规则）。
String _fill(String template, String v) => template.replaceAll('{0}', v);
