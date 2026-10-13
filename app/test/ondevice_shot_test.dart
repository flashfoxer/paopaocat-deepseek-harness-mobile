/// 「本地大模型」页的截图 —— 用来**自己检查排版**，不靠真机。
///
/// 为什么单独一个文件：这一页是用户反复说"乱"的地方（"下载好后没有模型名了，
/// 排版太乱"），而纯粹靠对话描述很难定位。这个测试把页面在**真实渲染管线**里
/// 画出来，产物在 `/tmp/dsh-shots/`，我（或用户）能直接看图。
///
/// 用法：`flutter test test/ondevice_shot_test.dart`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_mobile/i18n/app_language.dart';
import 'package:dsh_mobile/i18n/dsh_i18n.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/state/app_settings.dart';
import 'package:dsh_mobile/ui/pages/ondevice_models_page.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _fontSc = '/usr/share/fonts/truetype/notosc/NotoSansSC-VF.ttf';
const String _fontCjk =
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
const String _fontFamily = 'DshCJK';
const String _outDir = '/tmp/dsh-shots';
const Size _logical = Size(412, 915);
const double _pixelRatio = 3.0;
const ValueKey<String> _shotKey = ValueKey<String>('shot');

Future<ByteData> _bytesOf(String path) async =>
    ByteData.view(File(path).readAsBytesSync().buffer);

Future<void> _loadFonts() async {
  final loader = FontLoader(_fontFamily);
  if (File(_fontCjk).existsSync()) loader.addFont(_bytesOf(_fontCjk));
  loader.addFont(_bytesOf(_fontSc));
  await loader.load();
}

DshRuntime _fakeRuntime(String root) => DshRuntime(<String, dynamic>{
      'nodeBinary': '$root/libnode.so',
      // 故意指向不存在的目录：这样 `hasVulkan` 会走"探测失败"路径，
      // 正好覆盖"引擎不在本机"这一支，不需要真设备。
      'nativeLibDir': '$root/nativelib',
      'filesDir': root,
      'dshBin': '$root/lib/bin.js',
      'nodeHome': '$root/dshhome',
      'fsShim': '$root/shims/android-fs-shim.cjs',
    });

Future<void> _save(WidgetTester tester, String name) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
  final image = await boundary.toImage(pixelRatio: _pixelRatio);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = Directory(_outDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  File('$_outDir/$name').writeAsBytesSync(data!.buffer.asUint8List());
  // ignore: avoid_print
  print('[shot] $name  ${image.width}x${image.height}');
  image.dispose();
}

Widget _wrap(Widget child, AppLanguage lang) {
  final base = buildDshTheme();
  return DshI18n(
    language: lang,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        textTheme: base.textTheme.apply(fontFamily: _fontFamily),
        primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _fontFamily),
      ),
      home: RepaintBoundary(
        key: _shotKey,
        child: Scaffold(backgroundColor: DshColors.bg, body: child),
      ),
    ),
  );
}

void main() {
  late Directory tmp;
  late List<String> installedFiles;

  setUpAll(() async {
    await _loadFonts();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DshColors.applySkin(DshPalettes.dark);
    DshStrings.setCurrent(AppLanguage.zh);

    tmp = Directory.systemTemp.createTempSync('dsh-shot-models');
    final models = Directory('${tmp.path}/dshhome/models')
      ..createSync(recursive: true);

    // 造两个"已下载好"的模型（registry + 占位文件，大小与登记一致，免得被判"文件已丢失"）。
    installedFiles = <String>[];
    final entries = <Map<String, dynamic>>[];
    for (final spec in <List<Object>>[
      <Object>[
        'qwen2.5-1.5b-instruct-q4_k_m',
        'qwen2.5-1.5b',
        'Qwen2.5-1.5B（推荐档）',
        'qwen2.5-1.5b-instruct-q4_k_m.gguf',
        1117
      ],
      // ⚠️ 刻意用**空名字**：真机上那些行就是这么来的（早期版本写进登记表的 name
      // 是空字符串）。这张图就是「兜底到底有没有生效」的证据 —— 用户口径是
      // 「下载前能看到模型名，下载后就看不到了」（下载前读清单、下载后读登记表）。
      <Object>[
        'gemma-3-1b-it-q4_k_m',
        'gemma-3-1b',
        '',
        'gemma-3-1b-it-Q4_K_M.gguf',
        806
      ],
    ]) {
      final id = spec[0] as String;
      final fileName = spec[3] as String;
      final bytes = (spec[4] as int) * 1024 * 1024;
      File('${models.path}/$fileName')
          .writeAsBytesSync(List<int>.filled(bytes, 0));
      installedFiles.add(fileName);
      entries.add(<String, dynamic>{
        'id': id,
        'family': spec[1] as String,
        'name': spec[2] as String,
        'fileName': fileName,
        'bytes': bytes,
        'installedAt': '2026-10-07T01:00:00.000Z',
        'kind': 'text',
        'engine': 'llama.cpp',
        'format': 'gguf',
        'quant': 'Q4_K_M',
        'license': 'apache-2.0',
        'sourceLabel': 'ModelScope',
        'sha256': null,
        'companions': <dynamic>[],
      });
    }
    File('${models.path}/registry.json')
        .writeAsStringSync(jsonEncode(<String, dynamic>{'models': entries}));

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DshHost.channel,
        (MethodCall call) async {
      switch (call.method) {
        case 'getPaths':
          return <String, String>{
            'nodeHome': '${tmp.path}/dshhome',
            'filesDir': tmp.path,
            'nativeLibDir': '${tmp.path}/nativelib',
          };
        case 'deviceInfo':
          return <String, Object>{
            'totalRamGb': 12,
            'soc': 'Qualcomm SM8750',
            'model': 'SM-S9280',
            'abis': <String>['arm64-v8a'],
            'sdkInt': 35,
          };
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DshHost.channel, null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('本地大模型页 · 已装两个模型', (tester) async {
    tester.view.physicalSize = _logical * _pixelRatio;
    tester.view.devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);

    // ⚠️ 关键：这一页要**读真实文件**（registry.json / 清单）。
    //    `testWidgets` 默认跑在 FakeAsync 里，**真实 I/O 永远不会推进** ——
    //    页面会一直停在转圈，图里只有一个 loading 指示器（第一次就栽在这），
    //    而且转圈动画不停会让测试收尾空等 10 分钟。所以连 pumpWidget 都放进
    //    `runAsync`，并反复 pump 让真实异步逐步推进。
    await tester.runAsync(() async {
      await tester.pumpWidget(_wrap(
        OnDeviceModelsPage(
          runtime: _fakeRuntime(tmp.path),
          onModelChanged: () async {},
          // 面板偏好（推理后端 / 上下文）现在走它落盘；截图只关心渲染。
          settings: AppSettings(),
        ),
        AppLanguage.zh,
      ));
      for (var k = 0; k < 25; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await tester.pump();
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 默认只有服务卡/结果卡是展开的；把「文本」那组也展开，才能看到模型行。
    for (final label in <String>['文本', '多模态']) {
      final f = find.textContaining(label);
      if (f.evaluate().isNotEmpty) {
        await tester.tap(f.first, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    await tester.pump(const Duration(milliseconds: 300));
    await _save(tester, 'ondevice-installed.png');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
