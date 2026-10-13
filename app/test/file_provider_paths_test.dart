/// **FileProvider 白名单覆盖** + 「分享 / 外部打开失败必须留日志」的门禁。
///
/// ## 为什么要有这两条（都是真踩出来的）
///
/// 用户 2026-10-12 在手机上（0.69）让模型做了一个单文件游戏 `shooter.html`，
/// 点「分享」**分享不出去**；而同一份诊断报告里写着「错误 0 条」、明细里
/// 一个字都没有。那是**两个独立的缺陷叠在一起**：
///
///   ① **白名单漏了默认工作区**。`WorkspaceStore._defaultPath` 是
///      `<filesDir>/workspace`（**单数**），用户自己建的工作区才在
///      `<filesDir>/workspaces`（**复数**）下 —— 而 `res/xml/file_paths.xml`
///      里当时**只有复数**那条。于是 `FileProvider.getUriForFile` 直接抛
///      `IllegalArgumentException`，用户看到的是
///      「这个文件所在的位置不允许对外分享」。默认工作区恰恰装着绝大多数用户的
///      **全部**东西（会话产物、模型刚做好的游戏都在这里）。
///   ② **失败路径不写日志**。`_share()` / `ArtifactOpener.share()` 只在
///      `await` **成功返回后**才 `debugPrint`，异常分支只弹一个 SnackBar ——
///      一闪而过，诊断报告里就"什么都没有"，排查只能靠猜。
///
/// 这两条都**不会**让编译 / 测试 / 启动报错（①只有真机点分享才暴露，②只有
/// 去翻日志才发现），所以必须专门钉住：
///
///   * 第 1 条：白名单必须覆盖"代码里真的会交给 Intent 的目录"。这条测试会
///     **去源码里找锚点**（`$filesDir/workspace'` 这种），目录哪天改名/搬走，
///     它会跟着报错 —— 不是一张可以过期的死清单。
///   * 第 2 条：原生拒绝时日志里必须有 `[dsh-library] 分享失败` /
///     `[dsh-artifact] 分享失败` 这样一行（**带真实路径与原生原因**），
///     否则下一次用户再报"分享不出去"，报告里还是一片空白。
library;

import 'dart:io';

import 'package:dsh_mobile/data/artifact_opener.dart';
import 'package:dsh_mobile/data/artifacts.dart';
import 'package:dsh_mobile/data/library_store.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/ui/pages/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 逐行截住 `debugPrint`（[DiagnosticsLog.installDebugPrintTee] 抓的是同一个东西）。
///
/// ⚠️ 必须在**用例体内**用 `try / finally` 还原，**不能**放 `addTearDown`：
/// `flutter_test` 会在用例体结束时（tearDown 之前）断言"foundation 的调试变量
/// 没被改过"，放 tearDown 还原会直接报
/// "The value of a foundation debug variable was changed by the test."
void Function() _captureDebugPrint(List<String> out) {
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null && message.isNotEmpty) out.add(message);
  };
  return () => debugPrint = original;
}

void main() {
  group('FileProvider 白名单（res/xml/file_paths.xml）', () {
    test('覆盖代码里真实会交给 Intent 的目录（含默认工作区**单数** workspace/）', () {
      final xmlFile = File('android/app/src/main/res/xml/file_paths.xml');
      expect(xmlFile.existsSync(), isTrue,
          reason: '找不到 ${xmlFile.path}（测试的工作目录应当是 app/）');
      final xml = xmlFile.readAsStringSync();

      final whitelisted = RegExp(r'<files-path\b[^>]*\bpath="([^"]*)"')
          .allMatches(xml)
          .map((m) => m.group(1)!)
          .toSet();
      expect(whitelisted, isNotEmpty, reason: 'file_paths.xml 里一条 files-path 都没有？');

      // 白名单里的 path → 「这个目录真的会被交给 Intent」的源码锚点 [文件, 片段]。
      final need = <String, List<String>>{
        // 默认工作区（**单数**）—— 漏了它，默认工作区里的文件分享不出去
        'workspace/': <String>[
          'lib/data/workspace_store.dart',
          r"$filesDir/workspace'",
        ],
        // 用户自己建的工作区（复数）
        'workspaces/': <String>[
          'lib/data/workspace_store.dart',
          r"$filesDir/workspaces'",
        ],
        // 运行日志的导出与分享
        'logs/': <String>[
          'lib/local/diagnostics_log.dart',
          r"$filesDir/logs'",
        ],
        // 拍照：照片写这里，再把 content URI 交给相机应用
        'attachments/': <String>[
          'android/app/src/main/kotlin/com/dshmobile/dsh_mobile/MainActivity.kt',
          'File(filesDir, "attachments")',
        ],
        // DSH_HOME：知识库包（kb/）在其中，要能打开/分享
        'dshhome/': <String>[
          'android/app/src/main/kotlin/com/dshmobile/dsh_mobile/MainActivity.kt',
          'File(filesDir, "dshhome")',
        ],
        // 影视产物：分享 / 保存到相册
        'media/': <String>[
          'lib/local/media_service.dart',
          'filesDir}/media',
        ],
      };

      for (final e in need.entries) {
        expect(whitelisted, contains(e.key),
            reason: '${e.key} 不在 file_paths.xml 里 —— ${e.value[0]} 里的 '
                '「${e.value[1]}」会把该目录下的文件交给分享 / 外部打开，'
                'FileProvider 找不到 root 就抛 IllegalArgumentException，'
                '用户看到的是「这个文件所在的位置不允许对外分享」');

        final src = File(e.value[0]);
        expect(src.existsSync(), isTrue, reason: '锚点文件不见了：${e.value[0]}');
        expect(src.readAsStringSync(), contains(e.value[1]),
            reason: '${e.value[0]} 里找不到锚点「${e.value[1]}」—— 目录可能改名或搬走了。'
                '请核对白名单是否还对应**当前**的真实路径（别直接删掉这条断言）');
      }

      // 审计 P2：白名单**不能**退回整个私有目录（`path="."` 会把
      // .dsh-runtime-* 标记、runtime.zip 这类内部文件也放出去）。
      expect(whitelisted, isNot(contains('.')),
          reason: 'file_paths.xml 里有 path="." —— 那等于放开整个私有目录（审计 P2）');
    });
  });

  group('分享 / 外部打开：失败必须留一行诊断日志', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('dsh-handoff-'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// 让原生分享**失败**，模拟"路径不在 FileProvider 白名单里"那条真实报错。
    void mockShareFails(File f) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(DshHost.channel, (MethodCall call) async {
        if (call.method == 'shareFile') {
          throw PlatformException(
            code: 'NOT_SHAREABLE',
            message: '这个文件所在的位置不允许对外分享：${f.path}',
          );
        }
        return null;
      });
      addTearDown(
          () => messenger.setMockMethodCallHandler(DshHost.channel, null));
    }

    testWidgets('资料库的文件详情页：分享被原生拒绝 → 日志里有失败原因与真实路径',
        (tester) async {
      final f = File('${tmp.path}/笔记.md')..writeAsStringSync('# 标题\n');
      final entry = LibraryEntry(
        name: '笔记.md',
        relativePath: '笔记.md',
        absolutePath: f.path,
        size: f.lengthSync(),
        modified: DateTime.now(),
      );

      final logs = <String>[];
      final restore = _captureDebugPrint(logs);
      mockShareFails(f);
      try {
        await tester.pumpWidget(MaterialApp(home: FilePreviewPage(entry: entry)));
        // `_load()` 走的是**真 dart:io**（读文件）—— fake async 推不动它，
        // 必须用 runAsync 放真事件循环跑一会儿，否则 `_loading` 永远是 true、
        // 界面停在转圈上（`pumpAndSettle` 会一直超时）。
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 120)));
        await tester.pump();

        await tester.tap(find.byTooltip('分享'));
        await tester.pump(); // 让 _share 起步（原生的 Future 抛错后走到 catch）
        await tester.pump(); // 让 SnackBar 进场

        expect(
          logs.any((l) =>
              l.contains('[dsh-library] 分享失败') && l.contains(f.path)),
          isTrue,
          reason: '原生拒绝时**必须**留一行带路径的日志，否则报告里又是"错误 0 条"。'
              '实际日志：$logs',
        );
        // 用户看到的那句也要在（如实说原因，不是"分享成功"）
        expect(find.textContaining('分享失败：'), findsOneWidget);

        // 收尾：把 SnackBar 那个 4 秒定时器放掉 —— 用例结束时还留着 pending timer
        // 会被 flutter_test 判为失败。
        await tester.pump(const Duration(seconds: 5));
      } finally {
        restore();
        await tester.pump();
      }
    });

    testWidgets('会话产物行：分享被原生拒绝 → 日志里有失败原因与真实路径',
        (tester) async {
      final f = File('${tmp.path}/shooter.html')
        ..writeAsStringSync('<html></html>');
      final artifact = Artifact(
        name: 'shooter',
        extension: 'html',
        path: f.path,
      );

      final logs = <String>[];
      final restore = _captureDebugPrint(logs);
      mockShareFails(f);
      try {
        late BuildContext ctx;
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Builder(builder: (c) {
              ctx = c;
              return const SizedBox();
            }),
          ),
        ));

        await ArtifactOpener.share(ctx, artifact);
        await tester.pump();

        expect(
          logs.any((l) =>
              l.contains('[dsh-artifact] 分享失败') && l.contains(f.path)),
          isTrue,
          reason: '产物分享失败也必须留日志（同一个原生出口）。实际日志：$logs',
        );
      } finally {
        restore();
        await tester.pump();
      }
    });
  });
}
