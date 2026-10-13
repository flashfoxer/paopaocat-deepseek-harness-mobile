/// 「影视」执行层的测试（`local/media_service.dart`）。
///
/// ## 最要紧的一条：Dart ↔ 脚本的**接口约定**
///
/// 脚本里写着「⚠ 这一行是 Dart 侧识别的成功标记，格式不要改」——
/// 也就是说这条约定是**跨语言**的、靠人记住的。人一定会忘，所以这里用**真 node**
/// 跑一个**桩脚本**，把"打印标记 → Dart 认出文件路径"整条路验一遍。
/// （桩脚本而不是真脚本：真脚本要打网络、要 Key、要几分钟，不适合做单元测试。）
///
/// 覆盖三种结局：
///   * 退出码 0 + 有标记 → 成功，且路径/字节数解析正确（**路径里有空格**也要对）；
///   * 退出码 1 + `错误：…` → 失败，且错误原因被挑出来给用户看；
///   * 退出码 0 + **没有**标记 → 必须当失败（绝不假装成功）。
library;

import 'dart:io';

import 'package:dsh_mobile/data/media_models.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/local/media_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本机 node（找不到就跳过"真跑"那几条 —— 它们需要一个真解释器）。
String? _findNode() {
  for (final p in <String>[
    '/usr/local/bin/node',
    '/usr/bin/node',
    '/opt/homebrew/bin/node',
  ]) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

void main() {
  group('生成物 vs 工作区文件（剪辑选片那句"来源"就靠它）', () {
    test('media/ 下的是**生成物**（作品库）', () {
      expect(isGeneratedMediaPath('/data/user/0/app/files/media/video/a.mp4'), isTrue);
      expect(isGeneratedMediaPath('/data/user/0/app/files/media/image/a.png'), isTrue);
      expect(isGeneratedMediaPath('/data/user/0/app/files/media/narration/run-1/f0.png'), isTrue);
    });

    test('工作区里的文件**不是**生成物 —— 这一点必须为假，否则标签就会骗人', () {
      // ⚠️ 这条正是 2026-10-13 自查发现的 bug 的反面：
      //    当时用 `MediaSource` 判断，而**工作区文件也是 session**，
      //    于是"会话里生成的一段视频"被标成「工作区」。
      expect(isGeneratedMediaPath('/data/user/0/app/files/workspace/shooter.html'), isFalse);
      expect(isGeneratedMediaPath('/data/user/0/app/files/workspaces/我的项目/a.mp4'), isFalse);
      expect(isGeneratedMediaPath('/data/user/0/app/files/tts/vits-icefall-zh-aishell3/model.onnx'),
          isFalse);
    });

    test('Windows 风格的反斜杠也认（路径规范化）', () {
      expect(isGeneratedMediaPath(r'C:\x\files\media\video\a.mp4'), isTrue);
    });
  });

  // 服务会去读安全区里的 Key（拿不到就按空处理）——先初始化绑定，
  // 免得日志里刷一片 "Binding has not yet been initialized"。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory toolbox;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsh-media-test-');
    toolbox = Directory('${tmp.path}/toolbox')..createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  DshRuntime runtimeFor(String? node) => DshRuntime(<String, dynamic>{
        'filesDir': tmp.path,
        'nodeHome': '${tmp.path}/dshhome',
        'toolboxDir': toolbox.path,
        if (node != null) 'nodeBinary': node,
      });

  /// 写一个桩脚本（模拟真实脚本的输入/输出形状）。
  void stub(String name, String body) {
    File('${toolbox.path}/$name').writeAsStringSync(body);
  }

  group('产物清单与展示（纯逻辑）', () {
    test('默认文件名是 ASCII 时间戳（分享目标对中文文件名处理不一，故意不用中文）', () {
      final n = MediaService.defaultName('img', 'png');
      expect(n, matches(RegExp(r'^img-\d{8}-\d{6}\.png$')));
      expect(MediaService.defaultName('vid', 'mp4'), endsWith('.mp4'));
    });

    test('体积显示给人看（B / KB / MB）', () {
      MediaItem at(int bytes) => MediaItem(
          path: '/x/a.png',
          kind: MediaKind.image,
          bytes: bytes,
          modified: DateTime.now(),
          source: MediaSource.studio);
      expect(at(512).sizeLabel, '512 B');
      expect(at(2048).sizeLabel, '2 KB');
      expect(at(3 * 1024 * 1024).sizeLabel, '3.0 MB');
    });

    test('作品库：图片与视频分别归类，按时间从新到旧，跳过隐藏文件', () async {
      final svc = MediaService(runtimeFor(null));
      await svc.ensureDirs();
      File('${svc.imageDir.path}/a.png').writeAsBytesSync(<int>[1]);
      File('${svc.videoDir.path}/b.mp4').writeAsBytesSync(<int>[2]);
      // 半成品/临时文件（脚本可能会留）不该出现在作品库里
      File('${svc.imageDir.path}/.tmp-part').writeAsBytesSync(<int>[3]);

      final items = svc.listItems();
      expect(items.length, 2);
      expect(items.map((i) => i.fileName).toSet(), <String>{'a.png', 'b.mp4'});
      expect(
          items.firstWhere((i) => i.fileName == 'b.mp4').kind, MediaKind.video);
      expect(items.firstWhere((i) => i.fileName == 'a.png').kind,
          MediaKind.image);
      expect(items.first.timeLabel, isNotEmpty,
          reason: '时间标签复用 data/relative_time.dart 那份唯一实现');
    });

    test('失败原因：从脚本输出里挑最后一条「错误：…」（给用户看的就是它）', () {
      const r = MediaResult(
        ok: false,
        exitCode: 2,
        log: '提示：检查参数\n'
            '错误：没有配置 Agnes 的 API Key，无法生成图片。\n'
            '提示：这只说明配置缺失\n',
      );
      expect(r.error, '没有配置 Agnes 的 API Key，无法生成图片。');
    });
  });

  group('统一总库（影视产物 + 会话产物收在一起）', () {
    test('会话产物（workspace/）也会进作品库，并标成「来自会话」', () async {
      final svc = MediaService(runtimeFor(null));
      await svc.ensureDirs();
      final ws = Directory('${tmp.path}/workspace')..createSync(recursive: true);
      File('${ws.path}/图.png').writeAsBytesSync(<int>[1]);
      File('${tmp.path}/media/image/图.png').writeAsBytesSync(<int>[2]);

      final items = svc.listItems();
      expect(items.length, 2);
      expect(items.where((i) => i.source == MediaSource.session).length, 1);
      expect(items.where((i) => i.source == MediaSource.studio).length, 1);
    });

    test('用户建的工作区（workspaces/<名字>/）也扫得到', () async {
      final svc = MediaService(runtimeFor(null));
      await svc.ensureDirs();
      final ws = Directory('${tmp.path}/workspaces/陵川那些事')..createSync(recursive: true);
      File('${ws.path}/a.mp4').writeAsBytesSync(<int>[1]);
      final items = svc.listItems();
      expect(items.length, 1);
      expect(items.first.kind, MediaKind.video);
      expect(items.first.source, MediaSource.session);
    });

    test('⚠️ node_modules 里的图片**绝不能**进作品库（否则被别人的图标灌满）', () async {
      final svc = MediaService(runtimeFor(null));
      await svc.ensureDirs();
      final ws = Directory('${tmp.path}/workspace')..createSync(recursive: true);
      final nm = Directory('${ws.path}/node_modules/some-pkg/icons')
        ..createSync(recursive: true);
      File('${nm.path}/icon.png').writeAsBytesSync(<int>[1]);
      File('${ws.path}/真作品.png').writeAsBytesSync(<int>[2]);
      final items = svc.listItems();
      expect(items.length, 1, reason: '只该有那张真作品');
      expect(items.first.fileName, '真作品.png');
    });

    test('非媒体文件不进作品库（工作区里有代码、文档、临时文件）', () async {
      final svc = MediaService(runtimeFor(null));
      await svc.ensureDirs();
      final ws = Directory('${tmp.path}/workspace')..createSync(recursive: true);
      for (final n in <String>['a.md', 'b.dart', 'c.json', 'd.zip', 'e.txt']) {
        File('${ws.path}/$n').writeAsStringSync('x');
      }
      File('${ws.path}/.tmp-part.png').writeAsBytesSync(<int>[1]); // 隐藏文件
      expect(svc.listItems(), isEmpty);
    });

    test('两个来源按时间混排（最新的在前，不分来源）', () async {
      final svc = MediaService(runtimeFor(null));
      await svc.ensureDirs();
      final ws = Directory('${tmp.path}/workspace')..createSync(recursive: true);
      final oldF = File('${svc.imageDir.path}/old.png')..writeAsBytesSync(<int>[1]);
      final newF = File('${ws.path}/new.png')..writeAsBytesSync(<int>[2]);
      // 把"旧"那个的 mtime 调到过去
      oldF.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 5)));
      newF.setLastModifiedSync(DateTime.now());

      final items = svc.listItems();
      expect(items.first.fileName, 'new.png');
      expect(items.last.fileName, 'old.png');
    });

    test('条数到上限时如实标记（界面据此提示"只显示最新的 N 个"）', () async {
      final svc = MediaService(runtimeFor(null));
      await svc.ensureDirs();
      for (var i = 0; i < MediaService.maxItems + 5; i++) {
        File('${svc.imageDir.path}/p$i.png').writeAsBytesSync(<int>[1]);
      }
      final items = svc.listItems();
      expect(items.length, MediaService.maxItems);
      expect(svc.listItemsTruncated, isTrue);
    });
  });

  group('真跑桩脚本：Dart ↔ 脚本的约定', () {
    test('退出码 0 + 成功标记 → 解析出路径（路径含空格也要对）', () async {
      final node = _findNode();
      if (node == null) {
        markTestSkipped('本机没有 node，跳过这条（它需要一个真解释器）');
        return;
      }
      final svc = MediaService(runtimeFor(node));
      await svc.ensureDirs();
      final out = '${svc.imageDir.path}/a b c.png';
      stub(
        'make-image.mjs',
        'process.stdout.write("[agnes-image] ok file=$out bytes=1234 model=m\\n");\n',
      );
      final r = await svc.generateImage(prompt: '一只猫', outPath: out);
      expect(r.ok, isTrue, reason: '有标记就该成功：${r.log}');
      expect(r.file, out, reason: '非贪婪匹配要能吃下带空格的路径');
      expect(r.bytes, 1234);
    });

    test('退出码 1 + 错误：… → 失败，且原因能直接显示给用户', () async {
      final node = _findNode();
      if (node == null) {
        markTestSkipped('本机没有 node，跳过');
        return;
      }
      final svc = MediaService(runtimeFor(node));
      await svc.ensureDirs();
      stub('make-image.mjs',
          'process.stderr.write("错误：没有配置 Agnes 的 API Key，无法生成图片。\\n");\nprocess.exit(2);\n');
      final r = await svc.generateImage(prompt: '一只猫');
      expect(r.ok, isFalse);
      expect(r.exitCode, 2);
      expect(r.error, contains('没有配置 Agnes'));
    });

    test('⚠️ 退出码 0 但**没有**成功标记 → 必须当失败（绝不假装成功）', () async {
      final node = _findNode();
      if (node == null) {
        markTestSkipped('本机没有 node，跳过');
        return;
      }
      final svc = MediaService(runtimeFor(node));
      await svc.ensureDirs();
      // 模拟"有人改了脚本的标记行"或"脚本走了异常分支却没报错"
      stub('make-image.mjs', 'process.stdout.write("一切都好\\n");\n');
      final r = await svc.generateImage(prompt: '一只猫');
      expect(r.ok, isFalse, reason: '没有标记就不许当成功');
      expect(r.file, isNull);
      expect(r.log, contains('约定被改坏'));
    });

    test('⚠️ 选中的图像模型要用 --model 传下去（否则用户换了模型却是白换）', () async {
      final node = _findNode();
      if (node == null) {
        markTestSkipped('本机没有 node，跳过');
        return;
      }
      final svc = MediaService(runtimeFor(node));
      await svc.ensureDirs();
      stub(
        'make-image.mjs',
        'const out = process.argv[3];\n'
            'process.stdout.write("ARGV " + process.argv.slice(2).join("|") + "\\n");\n'
            'process.stdout.write("[agnes-image] ok file=" + out + " bytes=12 model=x\\n");\n'
            'import { writeFileSync } from "node:fs";\n'
            'writeFileSync(out, Buffer.alloc(12, 7));\n',
      );
      final r = await svc.generateImage(
        prompt: '一只猫',
        model: const MediaModelSpec(
          provider: 'myvendor',
          id: 'my-image-1',
          baseUrl: 'https://api.example.com/v1',
          kind: 'image',
        ),
      );
      expect(r.ok, isTrue, reason: r.log);
      expect(r.log, contains('--model|my-image-1'),
          reason: '模型名必须显式传参，不能只靠环境变量');
      expect(r.log, contains('--size|1K'));
      // 没给模型时不加 --model（脚本自己用内置默认）
      final r2 = await svc.generateImage(prompt: '一只猫');
      expect(r2.log, isNot(contains('--model')));
    });

    test('脚本不在 → 如实报"工具箱没落盘"，而不是崩', () async {
      final svc = MediaService(runtimeFor(_findNode()));
      final r = await svc.generateImage(prompt: '一只猫');
      expect(r.ok, isFalse);
      expect(r.log, contains('工具箱脚本不在'));
    });

    test('⚠️ narration 的成功标记也要认（不认的话口播/短剧会被当成失败）', () async {
      final node = _findNode();
      if (node == null) {
        markTestSkipped('本机没有 node，跳过');
        return;
      }
      final svc = MediaService(runtimeFor(node));
      await svc.ensureDirs();
      // 桩脚本：把收到的参数回显，并打**口播/短剧那种**成功标记
      stub(
        'make-narration.mjs',
        'const out = process.argv[3];\n'
            'process.stdout.write("ARGV " + process.argv.slice(2).join("|") + "\\n");\n'
            'process.stdout.write("[narration] ok file=" + out + " bytes=4321 shots=3\\n");\n'
            // ⚠️ .mjs 是 ES 模块，桩脚本里**不能**用 require（会 ReferenceError）
            'import { writeFileSync } from "node:fs";\n'
            'writeFileSync(out, Buffer.alloc(4321, 7));\n',
      );
      final r = await svc.composeNarration(specJson: '{"size":"1080x1920","shots":[]}');
      expect(r.ok, isTrue, reason: '标记没被认出来就会被当失败：\n${r.log}');
      expect(r.file, isNotNull);
      expect(r.file!.endsWith('.mp4'), isTrue);
      // 第一个参数是它自己写出来的 spec.json 路径
      expect(r.log, contains('spec-'));
      expect(r.bytes, 4321);
    });

    test('⚠️ edit-image 的成功标记也要认（不认的话修图会被当成失败）', () async {
      final node = _findNode();
      if (node == null) {
        markTestSkipped('本机没有 node，跳过');
        return;
      }
      final svc = MediaService(runtimeFor(node));
      await svc.ensureDirs();
      final src = File('${tmp.path}/src.png')..writeAsBytesSync(<int>[1, 2, 3]);
      // 桩脚本：回显参数，并打**修图脚本那种**成功标记
      stub(
        'edit-image.mjs',
        'process.stdout.write("ARGV " + process.argv.slice(2).join("|") + "\\n");\n'
            'const out = process.argv[3];\n'
            'process.stdout.write("[edit-image] ok file=" + out + " bytes=777 ops=美化:fresh(60)+去水印:1,2,8x6\\n");\n'
            'import { writeFileSync } from "node:fs";\n'
            'writeFileSync(out, Buffer.alloc(777, 7));\n',
      );
      final r = await svc.editImage(
        source: src.path,
        preset: 'fresh',
        strength: 60,
        delogo: '1:2:8:6',
      );
      expect(r.ok, isTrue, reason: '标记没被认出来就会被当失败：\n${r.log}');
      expect(r.file, isNotNull);
      expect(r.bytes, 777);
      // 参数要真的传下去：源图、输出、档位、强度、框
      expect(r.log, contains(src.path));
      expect(r.log, contains('--preset|fresh'));
      expect(r.log, contains('--strength|60'));
      expect(r.log, contains('--delogo|1:2:8:6'));
      // 不给框时就不该有这个参数（脚本自己会按"没框"处理）
      final r2 = await svc.editImage(source: src.path, preset: 'none');
      expect(r2.log, isNot(contains('--delogo')));
      expect(r2.log, contains('--preset|none'));
    });

    test('生成视频会把时长/画幅/首帧正确拼成命令行参数', () async {
      final node = _findNode();
      if (node == null) {
        markTestSkipped('本机没有 node，跳过');
        return;
      }
      final svc = MediaService(runtimeFor(node));
      await svc.ensureDirs();
      final first = File('${tmp.path}/f.png')..writeAsBytesSync(<int>[1]);
      // 桩脚本把收到的 argv 原样回显到日志里，方便断言
      stub(
        'make-video.mjs',
        'const out = process.argv[2];\n'
            'process.stdout.write("ARGV " + process.argv.slice(2).join("|") + "\\n");\n'
            'process.stdout.write("[agnes-video] ok file=" + out + " bytes=9 seconds=8\\n");\n',
      );
      final r = await svc.generateVideo(
          prompt: '跳下桌子',
          seconds: '8',
          ratio: '9:16',
          firstFrame: first.path);
      expect(r.ok, isTrue, reason: r.log);
      expect(r.log, contains('跳下桌子'));
      expect(r.log, contains('--seconds|8'));
      expect(r.log, contains('--ratio|9:16'));
      expect(r.log, contains('--mode|keyframe'));
      expect(r.log, contains('--first-frame|${first.path}'));
    });
  });
}
