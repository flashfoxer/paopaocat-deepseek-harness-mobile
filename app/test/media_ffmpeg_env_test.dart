/// 随包 ffmpeg 的**接线**测试（`local/dsh_runtime.dart`）。
///
/// ## 为什么单独钉这几条
///
/// ffmpeg 在 Android 上只能以 `<nativeLibraryDir>/libffmpeg.so` 的形式被打包
/// （数据目录不许执行文件、Gradle 只收 `lib*.so`），于是"它到底有没有被正确
/// 暴露给技能脚本"完全取决于**几个字符串**：
///   * `ffmpegBinary` 拼得对不对；
///   * 三个环境变量（`DSH_ANDROID_FFMPEG` / `DSH_ANDROID_FFPROBE` / `AGNES_FFMPEG`）
///     有没有注入 —— `AGNES_FFMPEG` 是**桌面端影视工具插件认的名字**，对齐了
///     两边的技能脚本才不用分平台改；
///   * 以及一条**反向**约束：**绝不能**把 ffmpeg 放进 `AndroidToolbox.assets`
///     （那是会被复制到数据目录的资源，放进去**不能执行**，只会得到 EACCES）。
library;

import 'package:dsh_mobile/local/android_toolbox.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DshRuntime rt({String nativeLibDir = '/data/app/lib'}) =>
      DshRuntime(<String, dynamic>{
        'nativeLibDir': nativeLibDir,
        'filesDir': '/data/files',
        'nodeHome': '/data/files/dshhome',
        'toolboxDir': '/data/files/toolbox',
        'nodeBinary': '$nativeLibDir/libnode.so',
      });

  group('ffmpeg / ffprobe 的路径', () {
    test('与 node 同目录、同命名规则（都是 lib*.so）', () {
      final r = rt();
      expect(r.ffmpegBinary, '/data/app/lib/libffmpeg.so');
      expect(r.ffprobeBinary, '/data/app/lib/libffprobe.so');
      // 与 node 一致 —— 这三者必须同目录，否则 LD_LIBRARY_PATH 那套不成立
      expect(r.ffmpegBinary.split('/').sublist(0, 4).join('/'),
          r.nodeBinary.split('/').sublist(0, 4).join('/'));
    });

    test('nativeLibDir 为空时给空串（而不是一个错的路径）', () {
      final r = rt(nativeLibDir: '');
      expect(r.ffmpegBinary, '');
      expect(r.ffprobeBinary, '');
    });
  });

  group('注入给技能脚本的环境变量', () {
    test('三个变量都要在：DSH_ANDROID_FFMPEG / DSH_ANDROID_FFPROBE / AGNES_FFMPEG', () {
      final env = rt().environment;
      expect(env['DSH_ANDROID_FFMPEG'], '/data/app/lib/libffmpeg.so');
      expect(env['DSH_ANDROID_FFPROBE'], '/data/app/lib/libffprobe.so');
      expect(env['AGNES_FFMPEG'], '/data/app/lib/libffmpeg.so',
          reason: '桌面插件按这个变量名找 ffmpeg（它优先看 AGNES_FFMPEG），必须对齐');
    });

    test('没有 nativeLibDir 时不注入（宁可"没有"，也不要指向空的路径）', () {
      final env = rt(nativeLibDir: '').environment;
      expect(env.containsKey('DSH_ANDROID_FFMPEG'), isFalse);
      expect(env.containsKey('DSH_ANDROID_FFPROBE'), isFalse);
      expect(env.containsKey('AGNES_FFMPEG'), isFalse);
    });

    test('原有的四项 DSH_ANDROID_* 不能被这次改动挤掉（shim 靠它们才生效）', () {
      final env = rt().environment;
      for (final k in <String>[
        'DSH_ANDROID_NODE_BIN',
        'DSH_ANDROID_FS_SHIM',
        'DSH_ANDROID_EXEC_SHIM',
        'DSH_ANDROID_TMPDIR',
        'DSH_ANDROID_TOOLBOX',
      ]) {
        expect(env.containsKey(k), isTrue, reason: '$k 缺了会让 exec shim 完全不改写');
      }
    });
  });

  group('反向约束（防止"好心"改成不能执行的形式）', () {
    test('⚠️ ffmpeg **不能**放进工具箱资产表（放那儿不可执行，只会 EACCES）', () {
      final keys = AndroidToolbox.assets.keys.join(' ').toLowerCase();
      expect(keys.contains('ffmpeg'), isFalse,
          reason: '资产会被复制到 filesDir —— Android 不许从那里执行文件。'
              'ffmpeg 只能作为 jniLibs 里的 libffmpeg.so 打包。');
      expect(keys.contains('ffprobe'), isFalse);
    });
  });
}
