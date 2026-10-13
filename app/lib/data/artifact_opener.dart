import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../local/dsh_runtime.dart';
import '../ui/pages/library_page.dart' show FilePreviewPage;
import 'artifacts.dart';
import 'library_store.dart';

import '../i18n/dsh_i18n.dart';

/// 产物 → 真实文件 → 打开（App 内预览）或分享。
///
/// ## 路径从哪来
///
/// 产物在**进列表之前**就已经核实过：文件真的在工作区里、而且是这次会话写出来的
/// （见 `artifacts.dart` 的 [verifyProducedArtifacts]）。所以正常情况下
/// [Artifact.path] 就是**真实绝对路径**，打开时直接用它 —— 不再"按名字重扫一遍
/// 整个工作区"，同名多份也不会再拿错。
///
/// 只有当 [Artifact.path] 为空（老数据 / 候选没核实成）时，才退回按文件名扫工作区。
///
/// ## 为什么跳 [FilePreviewPage] 而不是直接调系统
///
/// 这样"对话产物"和"资料库文件"**行为完全一致**：文本/图片在 App 内预览，
/// 其它格式才交给系统"打开方式"。直接调系统的话，最常见的 `.md` 产物
/// 在多数手机上根本没有应用能接（只会弹一句"没有可用应用"）。
class ArtifactOpener {
  const ArtifactOpener._();

  /// 打开产物：优先用**核实过的路径**，没有路径才按文件名扫工作区。
  static Future<void> open(
    BuildContext context,
    Artifact artifact, {
    String? cwd,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final entry = await resolve(artifact, cwd: cwd);
    if (entry == null) {
      // 失败也要留一行日志：SnackBar 一闪而过，诊断报告里就什么都没了。
      debugPrint('[dsh-artifact] 打开失败：解析不到 ${artifact.fullName}（cwd=$cwd）');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('找不到这个文件：「{0}」——可能还没生成出来，或被改名/删除了', [artifact.fullName]),
          ),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => FilePreviewPage(entry: entry)),
    );
  }

  /// 分享产物：**先解析出真实文件**，再交给原生分享面板（ACTION_SEND）。
  ///
  /// 为什么必须解析：原生侧要的是**绝对路径** —— 拿假路径去分享，
  /// 原生会抛"文件不存在"，等于骗用户。
  ///
  /// 三种结果都如实说：
  ///   * 解析不到 → 「找不到这个文件」（可能还没生成 / 被改名 / 被删）；
  ///   * `'no_app'` → 「这台设备没有能接收分享的应用」（环境事实）；
  ///   * PlatformException → 「分享失败：<原生给的中文原因>」。
  /// 其余情况（分享面板已拉起）不弹提示：面板是系统弹的，我们不知道用户选了谁。
  static Future<void> share(
    BuildContext context,
    Artifact artifact, {
    String? cwd,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final entry = await resolve(artifact, cwd: cwd);
    if (entry == null) {
      debugPrint('[dsh-artifact] 分享失败：解析不到 ${artifact.fullName}（cwd=$cwd）');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('找不到这个文件：「{0}」——可能还没生成出来，或被改名/删除了', [artifact.fullName]),
          ),
        ),
      );
      return;
    }
    try {
      final r =
          await DshHost.shareFile(entry.absolutePath, subject: entry.name);
      debugPrint(
          '[dsh-artifact] 分享 ${artifact.fullName} -> $r（${entry.absolutePath}）');
      if (r == 'no_app') {
        messenger.showSnackBar(
          SnackBar(content: Text(tr('这台设备没有能接收分享的应用'))),
        );
      }
    } on PlatformException catch (e) {
      // ⚠️ **失败必须留一行日志**（含原生给的中文原因与真实路径）。
      // 以前这里只有 SnackBar：用户报"分享不出去"时，诊断报告里
      // 既不写失败、也不写路径，只能靠猜（2026-10-12 真踩过）。
      debugPrint('[dsh-artifact] 分享失败 ${entry.absolutePath}'
          '（${e.code}）：${e.message}');
      messenger.showSnackBar(
        SnackBar(content: Text(tr('分享失败：{0}', [e.message ?? e.code]))),
      );
    } catch (e) {
      debugPrint('[dsh-artifact] 分享异常 ${entry.absolutePath}：$e');
      messenger.showSnackBar(SnackBar(content: Text(tr('分享失败：{0}', [e]))));
    }
  }

  /// 产物 → [LibraryEntry]（预览页要的形态）。
  ///
  /// 有核实过的路径 → 直接按路径造一条（只 stat 一个文件，不扫目录）；
  /// 那条路径万一读不到了（被删/被移走），退回按文件名扫一次工作区，
  /// 扫不到就返回 null（调用方如实说"找不到"）。
  static Future<LibraryEntry?> resolve(
    Artifact artifact, {
    String? cwd,
  }) async {
    final path = artifact.path;
    if (path != null && path.isNotEmpty) {
      final hit = LibraryEntry.probe(path, root: cwd ?? '');
      if (hit != null) {
        debugPrint('[dsh-artifact] 直接按核实过的路径打开 ${artifact.fullName} -> $path');
        return hit;
      }
      debugPrint('[dsh-artifact] 核实过的路径已读不到：$path（退回按名字扫工作区）');
    }
    return resolveEntry(artifact.fullName, cwd: cwd);
  }

  /// 在工作区里找 [fullName]（含扩展名的文件名）对应的文件条目。
  ///
  /// 只在"产物没有核实过的路径"时用。同名多份时取**最近修改**的那一份。
  /// 找不到 / 出异常都返回 null。
  static Future<LibraryEntry?> resolveEntry(
    String fullName, {
    String? cwd,
  }) async {
    try {
      var root = cwd ?? '';
      if (root.isEmpty) {
        final paths = await DshHost.getPaths();
        final filesDir = (paths['filesDir'] as String?) ?? '';
        if (filesDir.isEmpty) return null;
        root = resolveWorkspaceFromFilesDir(filesDir).path;
      }
      final scan = await LibraryScanner.scan(root);
      LibraryEntry? hit;
      for (final e in scan.entries) {
        if (e.name != fullName) continue;
        if (hit == null || e.modified.isAfter(hit.modified)) hit = e;
      }
      if (hit != null) {
        debugPrint('[dsh-artifact] 解析到 $fullName -> ${hit.absolutePath}');
      } else {
        debugPrint(
            '[dsh-artifact] 工作区里没找到 $fullName（扫了 ${scan.entries.length} 个文件）');
      }
      return hit;
    } catch (e) {
      debugPrint('[dsh-artifact] 解析产物路径失败 $fullName：$e');
      return null;
    }
  }
}
