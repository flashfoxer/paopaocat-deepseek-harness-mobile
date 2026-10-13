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

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_mobile/i18n/app_language.dart';
import 'package:dsh_mobile/i18n/dsh_i18n.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/state/app_settings.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/state/model_store.dart';
import 'package:dsh_mobile/data/workspace_store.dart';
import 'package:dsh_mobile/local/schedule_runner.dart';
import 'package:dsh_mobile/data/schedule_store.dart';
import 'package:dsh_mobile/ui/pages/media_page.dart';
import 'package:dsh_mobile/ui/pages/clip_page.dart';
import 'package:dsh_mobile/ui/pages/creation_guide_page.dart';
import 'package:dsh_mobile/ui/pages/ai_role_page.dart';
import 'package:dsh_mobile/ui/pages/task_home_view.dart';
import 'package:dsh_mobile/ui/pages/library_page.dart';
import 'package:dsh_mobile/ui/pages/scheduled_page.dart';
import 'package:dsh_mobile/ui/pages/expert_page.dart';
import 'package:dsh_mobile/ui/pages/memory_page.dart';
import 'package:dsh_mobile/ui/pages/release_notes_page.dart';
import 'package:dsh_mobile/ui/pages/workspace_page.dart';
import 'package:dsh_mobile/ui/pages/chat_page.dart';

/// 简中（含大部分日文汉字）。系统自带。
const String _fontSc = '/usr/share/fonts/truetype/notosc/NotoSansSC-VF.ttf';

/// CJK 合集（`fonts-noto-cjk` 装的）。日语假名 / 韩语谚文靠它。
/// 缺了就退回只有简中 —— 日韩截图会出现方块，所以下面会检查它存在。
const String _fontCjk =
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';

const String _fontFamily = 'DshCJK';
// 刻意放在 /tmp/dsh-shots（而不是 /tmp/dsh-app 里面）：构建前的 sync 会把
// /tmp/dsh-app 整个清空重建，图放在那儿会被删掉。
const String _outDir = '/tmp/dsh-shots';

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

/// 把 `_shotKey` 那棵子树按 3 倍像素导出成 PNG。
Future<void> _save(WidgetTester tester, String name) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
  final image = await boundary.toImage(pixelRatio: _pixelRatio);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = Directory(_outDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final file = File('$_outDir/$name');
  file.writeAsBytesSync(data!.buffer.asUint8List());
  final w = image.width;
  final h = image.height;
  // ⚠️ 必须显式释放这张图。不释放时测试**收尾**会挂住 —— 实测每个 testWidgets
  //    末尾空等 10 分钟才抛 TimeoutException，而 PNG 其实早就写完了
  //    （日志里 `[shot]` 已经打印）。看起来像"出图慢"，其实卡在测试结束。
  image.dispose();
  // ignore: avoid_print
  print('[shot] $name  ${w}x$h  '
      '${(file.lengthSync() / 1024).toStringAsFixed(0)}KB');
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

void main() {
  setUpAll(() async {
    await _loadFonts();
    _mockNativeChannel();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DshColors.applySkin(DshPalettes.dark);
    DshStrings.setCurrent(AppLanguage.zh);
  });

  /// 一块一张图：把 [page] 按 3 倍像素截下来。
  ///
  /// ⚠️ 刻意**不用 `pumpAndSettle`**（这些树里有循环动画/未完成的 future，会等到超时），
  ///    也**不主动卸树**——两个都是实测验证过的坑，见 screenshot_test.dart 的说明。
  Future<void> shotOf(WidgetTester tester, String name, Widget page) async {
    tester.view.physicalSize = _logical * _pixelRatio;
    tester.view.devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(page, AppLanguage.zh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _save(tester, name);
  }

  MediaPage workbench({int? seg}) => MediaPage(
        runtime: _fakeRuntime(),
        settings: AppSettings(),
        onOpenSettings: () {},
        initialSeg: seg,
      );

  // ───────────────────────────── 五个 Tab

  testWidgets('块-首页', (tester) async {
    await shotOf(
      tester,
      'block-01-home.png',
      TaskHomeView(
        onOpenChat: ({String? initialText}) {},
        onOpenWorkspace: () {},
        workspaceName: '默认工作区',
        models: ModelStore(),
        onOpenModelSettings: () {},
      ),
    );
  });

  testWidgets('块-工作台入口页', (tester) async {
    await shotOf(tester, 'block-02-workbench.png', workbench());
  });

  testWidgets('块-资料库', (tester) async {
    await shotOf(tester, 'block-03-library.png', const LibraryPage());
  });

  testWidgets('块-定时任务', (tester) async {
    final store = ScheduleStore(Directory.systemTemp.createTempSync('shot-sch-').path);
    final runner = ScheduleRunner(store: store, runtimeOf: () => _fakeRuntime());
    await shotOf(tester, 'block-04-scheduled.png',
        ScheduledPage(store: store, runner: runner));
  });

  // ───────────────────────────── 工作台的每个功能

  testWidgets('块-生图', (tester) async {
    await shotOf(tester, 'block-05-image.png', workbench(seg: 0));
  });
  testWidgets('块-生视频', (tester) async {
    await shotOf(tester, 'block-06-video.png', workbench(seg: 1));
  });
  testWidgets('块-修图', (tester) async {
    await shotOf(tester, 'block-07-edit.png', workbench(seg: 2));
  });
  testWidgets('块-口播（默认系统配音）', (tester) async {
    await shotOf(tester, 'block-08-talk.png', workbench(seg: 3));
  });
  testWidgets('块-口播·切到本机离线（模型未装的状态卡）', (tester) async {
    tester.view.physicalSize = _logical * _pixelRatio;
    tester.view.devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(workbench(seg: 3), AppLanguage.zh));
    await tester.pump();
    await tester.tap(find.text('本机离线（零 Key）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _save(tester, 'block-09-talk-local-tts.png');
  });
  testWidgets('块-短剧', (tester) async {
    await shotOf(tester, 'block-10-drama.png', workbench(seg: 4));
  });
  testWidgets('块-作品库（已挪进资料库的那张九宫格）', (tester) async {
    await shotOf(tester, 'block-11-works.png', workbench(seg: 5));
  });
  testWidgets('块-剪辑', (tester) async {
    await shotOf(tester, 'block-12-clip.png', ClipPage(runtime: _fakeRuntime()));
  });
  testWidgets('块-画图表（弹层）', (tester) async {
    tester.view.physicalSize = _logical * _pixelRatio;
    tester.view.devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(workbench(), AppLanguage.zh));
    await tester.pump();
    await tester.tap(find.text('画图表'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _save(tester, 'block-13-diagram.png');
  });
  testWidgets('块-创作·小说改游戏', (tester) async {
    await shotOf(tester, 'block-14-novel-to-game.png', const CreationGuidePage());
  });
  testWidgets('块-AI 角色', (tester) async {
    await shotOf(tester, 'block-15-ai-role.png', const AiRolePage());
  });

  // ───────────────────────────── 其它功能块

  testWidgets('块-会话页', (tester) async {
    await shotOf(
      tester,
      'block-16-chat.png',
      ChatPage(runtime: _fakeRuntime(), models: ModelStore(), onOpenSettings: () {}),
    );
  });
  testWidgets('块-专家页', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('shot-exp-');
    await shotOf(
      tester,
      'block-17-experts.png',
      ExpertPage(
        dshHome: tmp.path,
        workspacePath: tmp.path,
        onOpenChatWithPrompt: (_) {},
      ),
    );
  });
  testWidgets('块-记忆页', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('shot-mem-');
    await shotOf(tester, 'block-18-memory.png', MemoryPage(dshHome: tmp.path));
  });
  testWidgets('块-更新说明', (tester) async {
    await shotOf(tester, 'block-19-release-notes.png', const ReleaseNotesPage());
  });
  testWidgets('块-工作区页', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('shot-ws-');
    final store = WorkspaceStore(tmp.path);
    await shotOf(
      tester,
      'block-20-workspace.png',
      WorkspacePage(
        store: store,
        onNewWorkspace: () async {},
        onOpenSession: (_, __) {},
        onRefreshIndex: () async {},
      ),
    );
  });
}
