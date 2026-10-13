/// 应用内更新的**安装侧**：问环境、验签名、交给系统安装器。
///
/// 三件事都在原生做（Dart 拿不到"已装应用的签名"，也拉不起安装界面），
/// 本文件只负责把原生给的键值对**翻成强类型 + 中文人话**，让界面能如实显示。
///
/// ## 安全底线（别在这里松口）
///
/// 覆盖安装 = 用新包替换旧包，**只有同一签名的包才换得动**。所以
/// [verifyDownloadedApk] 是"更新包没被人换成别的"的唯一防线：
///   * 读不出签名 → **不通过**（不是"那就算它过吧"）；
///   * 包没签名 → 不通过；
///   * 签名对不上 → 不通过，并且要**如实说清**"只能卸载重装、数据会丢"，
///     而不是给用户一个"重试"按钮让他白试。
///
/// ## 一件必须写明做不到的事
///
/// Android 不允许普通应用静默安装，[installDownloadedApk] 只能**拉起系统安装界面**。
/// 用户点不点、装成没装成，**这里拿不到结果** —— 所以界面不能显示"安装成功"，
/// 只能说"已经交给你了，装完回到 App"。
library;

import 'package:flutter/foundation.dart' show debugPrint;

import '../i18n/dsh_i18n.dart';
import 'dsh_runtime.dart';

/// 这台设备当前的安装环境。
class InstallEnv {
  const InstallEnv({
    required this.canInstall,
    this.installedSignature,
    this.versionCode,
    this.versionName,
    this.sdkInt,
  });

  /// 用户是否已允许"安装未知应用"（Android 8+ 才需要）。false 时要先引导去设置。
  final bool canInstall;

  /// 已装应用的签名证书 sha256（小写 hex）；读不到为 null。
  final String? installedSignature;
  final int? versionCode;
  final String? versionName;
  final int? sdkInt;

  /// 原生读不到时的兜底值。**刻意把 `canInstall` 设成 false**：
  /// 宁可让用户多点一次"去允许安装"，也不要在状态未知时假装可以装。
  static const InstallEnv unknown = InstallEnv(canInstall: false);

  static InstallEnv fromMap(Map<String, Object?>? m) {
    if (m == null) return unknown;
    final sig = m['installedSignature'];
    return InstallEnv(
      canInstall: m['canInstall'] == true,
      installedSignature:
          (sig is String && sig.trim().isNotEmpty) ? sig.trim() : null,
      versionCode: m['versionCode'] is num
          ? (m['versionCode']! as num).toInt()
          : null,
      versionName: m['versionName'] is String ? m['versionName'] as String : null,
      sdkInt: m['sdkInt'] is num ? (m['sdkInt']! as num).toInt() : null,
    );
  }
}

/// 签名比对结果。
class SignatureCheck {
  const SignatureCheck({
    required this.matched,
    this.apkSignature,
    this.installedSignature,
    this.reason,
    this.detail,
  });

  final bool matched;
  final String? apkSignature;
  final String? installedSignature;

  /// 机器可读原因（见 [message] 的映射）。
  final String? reason;
  final String? detail;

  /// 给人看的一句话。失败时说明**为什么**，不是干巴巴一句"校验失败"。
  String get message {
    if (matched) return tr('签名与当前应用一致，可以安装。');
    switch (reason) {
      case 'not_an_apk':
        return tr('这个文件不是一个能识别的安装包。');
      case 'apk_unsigned':
        return tr('这个安装包里没有签名 —— 正规发布的包一定有签名，所以不装它。');
      case 'installed_unknown':
        return tr('读不到当前应用的签名，没法确认新包是不是同一家签的；出于安全，这次不装。');
      case 'signature_mismatch':
        return tr('这个包与当前应用的**签名不一致**，不能覆盖安装 —— 它可能不是同一个来源发的。'
            '如果你确实换了签名钥匙，唯一的办法是卸载重装（数据会丢）。');
      case 'read_failed':
        return tr('读取安装包签名时出错了。');
      default:
        return tr('签名校验没通过。');
    }
  }

  static SignatureCheck fromMap(Map<String, Object?>? m) {
    if (m == null) {
      // 原生没回话 = 拿不到结论 = **不通过**。这一条不能松。
      return const SignatureCheck(matched: false, reason: 'read_failed');
    }
    String? str(Object? v) =>
        (v is String && v.trim().isNotEmpty) ? v.trim() : null;
    return SignatureCheck(
      matched: m['matched'] == true,
      apkSignature: str(m['apkSignature']),
      installedSignature: str(m['installedSignature']),
      reason: str(m['reason']),
      detail: str(m['detail']),
    );
  }
}

/// 拉起系统安装器的结果。
enum InstallOutcome {
  /// 安装界面已拉起（**装成没装成拿不到**）。
  started,

  /// 还差"允许安装未知应用"这一步，要先引导去系统设置。
  needPermission,

  /// 系统里没有能处理安装 Intent 的应用。
  noInstaller,

  /// 路径不在 FileProvider 白名单里（配置问题）。
  badPath,

  /// 其它失败。
  failed,
}

/// 读安装环境。原生通道出错时返回 [InstallEnv.unknown]（**不抛**给界面）。
Future<InstallEnv> readInstallEnv() async {
  try {
    return InstallEnv.fromMap(await DshHost.updateInfo());
  } catch (e) {
    debugPrint('[dsh-update] 读安装环境失败：$e');
    return InstallEnv.unknown;
  }
}

/// 校验下载好的 APK：签名是否与当前 App 同一家。
///
/// 任何异常都变成"不通过"，**绝不**变成"通过"（安全底线只有这一条）。
Future<SignatureCheck> verifyDownloadedApk(String path) async {
  try {
    return SignatureCheck.fromMap(await DshHost.verifyApk(path));
  } catch (e) {
    debugPrint('[dsh-update] 校验 APK 签名失败：$e');
    return SignatureCheck(
        matched: false, reason: 'read_failed', detail: e.toString());
  }
}

/// 把下载好的 APK 交给系统安装器。
///
/// 返回 `(outcome, 给人看的一句话)`。
Future<({InstallOutcome outcome, String message})> installDownloadedApk(
    String path) async {
  try {
    final r = await DshHost.installApk(path);
    switch (r) {
      case 'ok':
        return (
          outcome: InstallOutcome.started,
          message: tr('已经交给系统安装界面了 —— 在那上面点「安装」即可覆盖安装，数据不会丢。'
              '装完回到这里就是新版。'),
        );
      case 'need_permission':
        return (
          outcome: InstallOutcome.needPermission,
          message: tr('还差一步：系统里要允许本应用「安装未知应用」。点下面的按钮去打开，回来再点「安装」。'),
        );
      case 'no_app':
        return (
          outcome: InstallOutcome.noInstaller,
          message: tr('这台设备上找不到能处理安装的应用（一般是定制系统裁掉了安装器），装不了。'),
        );
      case 'bad_path':
        return (
          outcome: InstallOutcome.badPath,
          message: tr('安装包所在的位置没有对系统开放（这是应用自身的配置问题，请把运行日志发给开发者）。'),
        );
      default:
        return (outcome: InstallOutcome.failed, message: tr('拉起安装界面失败。'));
    }
  } catch (e) {
    debugPrint('[dsh-update] 拉起安装界面失败：$e');
    return (outcome: InstallOutcome.failed, message: tr('拉起安装界面失败：{0}', [e]));
  }
}
