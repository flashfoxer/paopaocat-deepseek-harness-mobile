/// 界面截图 —— 给公众号 / README 用的**真实 UI 渲染**，不靠真机。
///
/// 为什么需要它：本机没有 Android 设备，APK 装不上、截不了图。但 Flutter 能在
/// **真实渲染管线**里画出界面并导出 PNG —— 拿到的是 App 代码渲染出来的东西，
/// 不是另画一张示意图。
///
/// 用法：`flutter test test/screenshot_test.dart`
/// 产物：`/tmp/dsh-app/test/shots/*.png`（3 倍分辨率）
///
/// ⚠️ 四个必要条件：
///   1. **加载真实字体** —— 测试环境默认字体是 Ahem，所有字都是方块；
///      中日韩三语要各有着落，所以同时挂 `NotoSansCJK-Regular.ttc`（含 JP/KR
///      face）与 `NotoSansSC-VF.ttf`（简中兜底），同族多字体由引擎按序回退；
///   2. **把字体族塞进 ThemeData** —— App 自己的 TextStyle 大多没写 fontFamily，靠继承；
///   3. **喂一次皮肤** —— 配色是全局静态（`DshColors.applySkin`），main.dart 里会喂，
///      测试里必须自己喂，否则用默认皮肤；
///   4. **喂一次语言** —— `DshStrings.setCurrent` 管 data 层，`DshI18n` 管 UI 层，
///      两个都要给，否则切了语言截图里还是中文。
///
/// 为什么不用 `matchesGoldenFile`：它按**逻辑尺寸**出图（412×915），给公众号偏小。
/// 这里用 `RepaintBoundary.toImage(pixelRatio: 3)` 直接拿物理像素。
library;


import 'package:dsh_mobile/i18n/app_language.dart';
import 'package:dsh_mobile/i18n/dsh_i18n.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/state/app_settings.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/ui/pages/media_page.dart';
import 'package:dsh_mobile/ui/pages/library_page.dart';

/// 简中（含大部分日文汉字）。系统自带。
const String _fontSc = '/usr/share/fonts/truetype/notosc/NotoSansSC-VF.ttf';

/// CJK 合集（`fonts-noto-cjk` 装的）。日语假名 / 韩语谚文靠它。
/// 缺了就退回只有简中 —— 日韩截图会出现方块，所以下面会检查它存在。
const String _fontCjk =
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';

const String _fontFamily = 'DshCJK';

/// 截图用的逻辑尺寸（真机常见：412×915 逻辑像素）。
const Size _logical = Size(412, 915);
const double _pixelRatio = 3.0;

/// 要截的那棵子树的 key（`RepaintBoundary` 必须包在它外面）。
const ValueKey<String> _shotKey = ValueKey<String>('shot');

Future<ByteData> _bytesOf(String path) async {
  final bytes = File(path).readAsBytesSync();
  return ByteData.view(bytes.buffer);
}

Future<void> _loadFonts() async {
  final loader = FontLoader(_fontFamily);
  // 顺序即优先级：合集在前（覆盖日韩），简中在后兜底。
  if (File(_fontCjk).existsSync()) {
    loader.addFont(_bytesOf(_fontCjk));
  } else {
    // ignore: avoid_print
    print('[shot] ⚠️ 缺少 $_fontCjk —— 日/韩截图会出现方块。'
        '装法：apt-get install -y fonts-noto-cjk');
  }
  loader.addFont(_bytesOf(_fontSc));
  await loader.load();
}

/// 造一个假的运行时路径表 —— `DshRuntime` 只要这个 Map 就能构造，
/// 所以不用真设备、也不用真目录。
DshRuntime _fakeRuntime() => DshRuntime(<String, dynamic>{
      'nodeBinary': '/data/app/lib/arm64-v8a/libnode.so',
      'nativeLibDir': '/data/app/lib/arm64-v8a',
      'filesDir': '/data/user/0/com.dshmobile.dsh_mobile/files',
      'dshBin': '/data/user/0/com.dshmobile.dsh_mobile/files/dsh/lib/bin.js',
      'nodeHome': '/data/user/0/com.dshmobile.dsh_mobile/files/dshhome',
      'fsShim':
          '/data/user/0/com.dshmobile.dsh_mobile/files/shims/android-fs-shim.cjs',
    });

void _mockNativeChannel() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(DshHost.channel, (MethodCall call) async {
    switch (call.method) {
      case 'permissionStatus':
        return <String, String>{
          'microphone': 'granted',
          'location': 'denied',
          'photos': 'permanently-denied',
          'notifications': 'granted',
        };
      case 'speechSupport':
        return <String, Object>{
          'sdkInt': 34,
          'recognitionAvailable': true,
          'onDeviceAvailable': true,
          'intentHandlers': 3,
          'language': 'zh-CN',
        };
      default:
        return null;
    }
  });
}

Widget _wrap(Widget child, AppLanguage lang) {
  final base = buildDshTheme();
  return DshI18n(
    language: lang,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _shotTheme(base, _fontFamily),      home: RepaintBoundary(
        key: _shotKey,
        child: Scaffold(
          // App 里底色由最底层 DshGridBackground 铺（见 main.dart），
          // 截图时手动铺一层，免得截成纯黑。
          backgroundColor: DshColors.bg,
          body: child,
        ),
      ),
    ),
  );
}


/// 给截图用的主题**盖上字体族**（本机测试环境的默认字体是 Ahem —— 一个字一个方块）。
///
/// ## 为什么光改 textTheme 不够（2026-10-13 体检踩到，实测截图里标题/芯片是 `口口口`）
///
/// `ThemeData` 构建时，**各组件主题会从 textTheme 派生出自己的样式**（chip 的 labelStyle、
/// button 的 textStyle、appBar 的 titleTextStyle…）。之后再 `copyWith(textTheme: …)`
/// **追不回那些已经派生好的引用** —— 它们仍然指着"没有 fontFamily"的那份，
/// 于是用它们渲染的文字（AppBar 标题、ChoiceChip 标签、按钮文字…）回退到 Ahem。
/// 所以这里逐个盖一遍。**设备上没这个问题**（回退到系统字体），
/// 所以这纯粹是**截图底座**的活，不是 App 的问题。
ThemeData _shotTheme(ThemeData base, String family) {
  TextStyle? f(TextStyle? s) => s?.copyWith(fontFamily: family);
  return base.copyWith(
    // ⚠️ **还得盖 typography**（2026-10-13 诊断出来的最后一层）：
    //    App 的 textTheme **没有定义 labelLarge / labelMedium 这些**，
    //    运行时它们来自 `Typography`（字体族 null）—— 而 `TextTheme.apply`
    //    **盖不到 null 字段**（实测 `labelLarge.family` 一直是 null）。
    //    芯片标签、输入框提示走的正是这些 label* 样式，所以它们一直是方块。
    typography: Typography(
      englishLike: base.typography.englishLike.apply(fontFamily: family),
      dense: base.typography.dense.apply(fontFamily: family),
      tall: base.typography.tall.apply(fontFamily: family),
    ),
    textTheme: base.textTheme.apply(fontFamily: family),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: family),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: f(base.appBarTheme.titleTextStyle),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: f(base.chipTheme.labelStyle),
      secondaryLabelStyle: f(base.chipTheme.secondaryLabelStyle),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          f(base.filledButtonTheme.style?.textStyle?.resolve(<WidgetState>{})),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          f(base.textButtonTheme.style?.textStyle?.resolve(<WidgetState>{})),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          f(base.outlinedButtonTheme.style?.textStyle?.resolve(<WidgetState>{})),
        ),
      ),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      hintStyle: f(base.inputDecorationTheme.hintStyle),
      labelStyle: f(base.inputDecorationTheme.labelStyle),
    ),
    tabBarTheme: base.tabBarTheme.copyWith(
      labelStyle: f(base.tabBarTheme.labelStyle),
      unselectedLabelStyle: f(base.tabBarTheme.unselectedLabelStyle),
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      contentTextStyle: f(base.snackBarTheme.contentTextStyle),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: f(base.dialogTheme.titleTextStyle),
      contentTextStyle: f(base.dialogTheme.contentTextStyle),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: f(base.listTileTheme.titleTextStyle),
      subtitleTextStyle: f(base.listTileTheme.subtitleTextStyle),
    ),
  );
}

/// 创作台那一页（`seg` 为空 = 入口屏；0–4 = 生图/生视频/修图/口播/短剧；5 = 作品库）。
MediaPage workbench({int? seg}) => MediaPage(
      runtime: _fakeRuntime(),
      settings: AppSettings(),
      onOpenSettings: () {},
      initialSeg: seg,
    );

void main() {
  // 与采集文件同一套前置：真字体 + 皮肤 + 语言。少了字体，断言会"因为方块全红"，
  // 那样测的是环境不是夹具，所以这几行是门禁成立的前提。
  setUpAll(() async {
    await _loadFonts();
    _mockNativeChannel();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DshColors.applySkin(DshPalettes.dark);
    DshStrings.setCurrent(AppLanguage.zh);
  });


  // ───────────────────────────── 截图夹具的**自己检查自己**

  /// 收集这棵树上**没有字体族**的文字段（= 截图里会是方块的那批）。
  ///
  /// 为什么要有这条门禁（2026-10-13 体检踩到）：本机测试环境的默认字体是 **Ahem**
  /// （一个字一个方块），而 App 主题里很多 TextStyle 没写 fontFamily（设备上回退到
  /// 系统字体，所以设备没问题）。截图夹具靠"盖上字体族"来解决，可是**盖不全会静默
  /// 出现方块** —— 我最初只盖了 textTheme，结果 AppBar 标题、芯片标签、输入框提示
  /// 全是方块，而 `flutter test` **一声不响**（图照样出、测试照样绿）。
  /// 所以这里直接查"每段文字的最终字体族"，缺一段就红。
  List<String> textsWithoutFontFamily(WidgetTester tester) {
    final missing = <String>[];
    for (final e in find.byType(RichText).evaluate()) {
      final rp = e.renderObject as RenderParagraph;
      final txt = rp.text.toPlainText().replaceAll('\n', ' ').trim();
      if (txt.isEmpty) continue;
      if (rp.text.style?.fontFamily == null) {
        missing.add(txt.length > 24 ? '${txt.substring(0, 24)}…' : txt);
      }
    }
    return missing;
  }

  testWidgets('夹具自检：口播页（含本机离线那块）每段文字都有字体族，否则会是方块', (tester) async {
    tester.view.physicalSize = _logical * _pixelRatio;
    tester.view.devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(workbench(seg: 3), AppLanguage.zh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('本机离线（零 Key）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final missing = textsWithoutFontFamily(tester);
    expect(missing, isEmpty,
        reason: '这些文字在截图里会渲染成方块（缺字体族）：\n  ${missing.join('\n  ')}');
  });

  testWidgets('夹具自检：创作台入口页与资料库页也一样（没有方块）', (tester) async {
    tester.view.physicalSize = _logical * _pixelRatio;
    tester.view.devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);
    for (final page in <Widget>[workbench(), const LibraryPage()]) {
      await tester.pumpWidget(_wrap(page, AppLanguage.zh));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final missing = textsWithoutFontFamily(tester);
      expect(missing, isEmpty, reason: '缺字体族（会是方块）：\n  ${missing.join('\n  ')}');
    }
  });
}
