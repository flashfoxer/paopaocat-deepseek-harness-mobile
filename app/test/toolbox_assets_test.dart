/// 工具箱（`assets/toolbox/`）的两道**资产门禁**。
///
/// ## 为什么需要它（2026-10-13，做本机离线配音时差点又踩）
///
/// Flutter 的 assets **不进子目录**：`pubspec.yaml` 里写 `- assets/toolbox/`
/// 只会把**顶层**文件打进包。这次为了在 node 里解 `.tar.bz2`，
/// 在 toolbox 下建了 `vendor/seek-bzip/lib/…` —— 只要忘了逐个声明，
/// 结果就是：**本地测试全绿**（测试读的是磁盘）、**analyze 全绿**、
/// 到了手机上 `require('./vendor/...')` 才失败，而且现场只有一行
/// "Cannot find module"，很难归因。
///
/// 这个坑项目里踩过一次（技能那边，见 `builtin_skills_assets_test.dart`），
/// 现在给工具箱也补上，并且**多查一道**：不光要"进包"，
/// 还要"在复制表里"（进包只是第一步，真正上设备靠 `AndroidToolbox.assets`）。
library;

import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/local/android_toolbox.dart';

/// 磁盘上 `assets/toolbox/` 下的所有文件（含子目录），路径形如 `assets/toolbox/...`。
List<String> toolboxFilesOnDisk() {
  final dir = Directory('assets/toolbox');
  if (!dir.existsSync()) return const <String>[];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path.replaceAll('\\', '/'))
      .toList()
    ..sort();
}

void main() {
  // 读 AssetManifest 要先初始化测试 binding（否则 rootBundle 会抛
  // "Binding has not yet been initialized"）—— 这不是被测代码的问题。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('磁盘上的工具箱文件必须都在 AssetManifest 里（子目录也不例外）', () async {
    final onDisk = toolboxFilesOnDisk();
    expect(onDisk, isNotEmpty, reason: '连 assets/toolbox 都没找到，测试的工作目录不对');

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final bundled = manifest.listAssets().toSet();
    final missing = onDisk.where((p) => !bundled.contains(p)).toList();

    expect(missing, isEmpty,
        reason: '这些文件没进包（Flutter 的 assets 不递归子目录，'
            '必须在 pubspec.yaml 里逐个目录声明）：\n  ${missing.join('\n  ')}');
  });

  test('磁盘上的工具箱文件必须都在复制表里（否则不会落到设备上）', () {
    final onDisk = toolboxFilesOnDisk();
    const map = AndroidToolbox.assets;
    final missing = onDisk.where((p) => !map.containsKey(p)).toList();

    expect(missing, isEmpty,
        reason: '这些文件没有登记进 `AndroidToolbox.assets`，'
            '虽然进了包但不会出现在设备的 toolbox 目录里：\n  ${missing.join('\n  ')}');
  });

  test('复制表里落进 toolbox/ 的目标路径必须**镜像**相对路径', () {
    // 为什么这条重要：`untar-bz2.mjs` 里是 `require('./vendor/seek-bzip/lib/index.js')`
    // 这种**相对脚本自身**的引用（node 的 ESM/CJS 相对路径都相对文件，不相对 cwd）。
    // 摆错一层 → 手机上起不来；而"镜像"这个约束能让它永远摆不错。
    final bad = <String>[];
    AndroidToolbox.assets.forEach((from, to) {
      if (!to.startsWith('toolbox/')) return; // 例如 exec shim 落在 shims/
      final rel = from.replaceFirst('assets/toolbox/', '');
      if (to != 'toolbox/$rel') bad.add('$from → $to（应为 toolbox/$rel）');
    });
    expect(bad, isEmpty, reason: '这些条目的目标路径没有镜像相对路径：\n  ${bad.join('\n  ')}');
  });

  test('复制表里不许出现磁盘上不存在的文件（那是死条目）', () {
    final onDisk = toolboxFilesOnDisk().toSet();
    final dead = AndroidToolbox.assets.keys
        .where((k) => k.startsWith('assets/toolbox/'))
        .where((k) => !onDisk.contains(k))
        .toList();
    expect(dead, isEmpty, reason: '这些条目在磁盘上不存在了：\n  ${dead.join('\n  ')}');
  });
}
