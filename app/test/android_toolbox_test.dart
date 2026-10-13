/// 工具箱「落盘表」的完整性门禁。
///
/// ## 为什么值得一条测试
///
/// `assets/toolbox/` 下的脚本是**给模型用的命令**，而技能文件（`assets/skills/*`)
/// 会照着脚本名写死调用方式，例如：
///
/// ```
/// ```
///
/// 这句话要成立，必须**两件事同时成立**：
///   ① 脚本在 APK 里（pubspec 声明 `assets/toolbox/` 目录 → 自动包含，一般不会漏）；
///   ② 它被写进 `AndroidToolbox.assets` 那张表 → 运行时落盘到 `filesDir/toolbox/`。
///
/// **②漏了不会报任何错**：App 照常启动、测试照常通过，只是模型运行时那句命令
/// `No such file or directory`。真机上模型不会立刻说"文件不存在"，它会**先怀疑自己**——
/// 2026-10-09 的报告里它就这么绕了 **14 分钟**（翻目录 → 找 HTTP 端点 → 猜参数名
/// → 最后把一轮 prompt 拖到 `TimeoutException: ACP 请求超时`）。
///
/// 也就是说：这是一类**只会在真机上以"模型犯傻"的形式暴露出来**的缺陷。
/// 所以用一条本体测试把它挡住，别再靠人去记得改这张表。
library;

import 'dart:io';

import 'package:dsh_mobile/local/android_toolbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('工具箱落盘表（assets/toolbox → filesDir）', () {
    test('目录里每个脚本都在落盘表里（漏一个 = 技能里那条命令是死的）', () {
      final dir = Directory('assets/toolbox');
      expect(dir.existsSync(), isTrue, reason: 'assets/toolbox 不在当前目录');

      final onDisk = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => !n.startsWith('.'))
          .toList()
        ..sort();
      expect(onDisk, isNotEmpty, reason: '工具箱目录是空的？');

      final declared = AndroidToolbox.assets.keys
          .map((k) => k.split('/').last)
          .toSet();

      final missing = onDisk.where((n) => !declared.contains(n)).toList();
      expect(missing, isEmpty,
          reason: '这些脚本在 assets/toolbox/ 里，但**没有**被写进 '
              'AndroidToolbox.assets —— 运行时不会落盘，而技能文件会照名字去调它：\n'
              '  ${missing.join('、')}\n'
              '（补一行 `\'assets/toolbox/<名字>\': \'toolbox/<名字>\'` 即可）');

      // 反向也查一下：表里写了、磁盘上没有 → 落盘时 loadString 会抛（被 catch 掉只剩日志），
      // 同样是"静默失效"，也该挡。
      final ghost = AndroidToolbox.assets.keys
          .where((k) => !File(k).existsSync())
          .toList();
      expect(ghost, isEmpty,
          reason: '落盘表里写了这些资源，但磁盘上不存在：${ghost.join('、')}');
    });

    test('目标路径都在 toolbox/ 或 shims/ 下，不会写到别处', () {
      for (final entry in AndroidToolbox.assets.entries) {
        expect(
          entry.value.startsWith('toolbox/') ||
              entry.value.startsWith('shims/'),
          isTrue,
          reason: '${entry.key} 落到 ${entry.value} —— '
              '落盘只允许 toolbox/ 与 shims/ 两个子目录（保持 App 私有目录干净）',
        );
      }
    });
  });
}
