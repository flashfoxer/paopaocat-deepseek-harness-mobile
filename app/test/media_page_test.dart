/// 「影视」页的界面测试（`ui/pages/media_page.dart`）。
///
/// 这里**不**测真实生成（那要打网络、要 Key、要几分钟）—— 那部分是
/// `test/media_service_test.dart` 用桩脚本验的。这里只管**界面行为**：
/// 三个分段在不在、空状态说什么、没写提示词就点生成会不会乱跑、
/// 以及"生视频"那一栏该有的选项齐不齐。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/state/app_settings.dart';
import 'package:dsh_mobile/state/model_store.dart';
import 'package:dsh_mobile/ui/pages/media_page.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    DshColors.applySkin(DshPalettes.dark);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('dsh-media-page-');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester,
      {VoidCallback? onOpenSettings,
      int refreshTick = 0,
      String? enter = '生图',
      int? initialSeg,
      ModelStore? models}) async {
    // ⚠️ 视口设成"高一点的手机"（1080x2400 @1x）而不是默认的 800x600：
    //    影视页现在是长表单（生图/口播/短剧各自的选项都很多），默认尺寸下
    //    **列表懒加载**会让下半部分的控件（比如"生成短剧视频"按钮）根本没被构建，
    //    于是断言会莫名其妙找不到 —— 那不是页面的 bug，是测试视口太小。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final rt = DshRuntime(<String, dynamic>{
      'filesDir': tmp.path,
      'nodeHome': '${tmp.path}/dshhome',
      'toolboxDir': '${tmp.path}/toolbox',
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildDshTheme(),
      home: MediaPage(
        runtime: rt,
        settings: AppSettings(),
        onOpenSettings: onOpenSettings ?? () {},
        refreshTick: refreshTick,
        initialSeg: initialSeg,
        models: models,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    // 2026-10-12（用户提议）：这一页现在**先给一屏功能入口**（创作台），
    // 点进去才是那个功能。默认帮调用方进「生图」—— 这样各条断言写的
    // "一进来就能看到生图的东西"仍然成立；要测入口屏本身的传 `enter: null`。
    if (initialSeg == null && enter != null) {
      // ⚠️ `pumpWidget` 对**同一类型**的 widget 会复用 State（例如一个测试里
      //    第二次 pump 只为改 refreshTick）—— 那时可能已经停在某个详情页，
      //    所以要**先回创作台**再点入口。
      if (find.byTooltip('回创作台').evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip('回创作台'));
        await tester.pumpAndSettle();
      }
      final entry = find.ancestor(
          of: find.text(enter), matching: find.byType(InkWell));
      expect(entry, findsWidgets, reason: '创作台上找不到入口「$enter」');
      await tester.tap(entry.first);
      await tester.pumpAndSettle();
    }
  }

  /// 预置 `media-models.json`（**必须在 pump 之前**写：页面在 initState 里读盘）。
  ///
  /// ⚠️ 用**同步**写：`testWidgets` 的时钟是假的，`await File.writeAsString(...)`
  /// 这种真实 I/O 在里面**永远不完成**（测试会挂住而不是报错，真踩过）。
  void writeMediaModels(Map<String, dynamic> json) {
    File('${tmp.path}/media-models.json').writeAsStringSync(jsonEncode(json));
  }

  /// 一条自定义模型（图像或视频）。
  Map<String, dynamic> model({
    required String provider,
    required String id,
    required String baseUrl,
    String kind = 'image',
  }) =>
      <String, dynamic>{
        'provider': provider,
        'id': id,
        'baseUrl': baseUrl,
        'kind': kind,
      };

  /// 切模式：点**整个 ChoiceChip**（而不是 chip 里的那段文字）。
  ///
  /// 点文字在 5 个 chip 之后变得不可靠（命中点可能落在 chip 的内边距上而不是字形上），
  /// 而"用户点的是 chip"这件事本身才是我们要测的。
  /// 点一个东西 —— 它可能是两类控件：
  ///
  ///   ① **详情页里的选项**（例如口播页的「配音来源」）仍然是 `ChoiceChip`；
  ///   ② **创作台上的功能入口**（生图/生视频/…）现在是一行卡片（`InkWell`），
  ///      不再是模式 chip（2026-10-12 用户提议改成"入口屏 + 详情页"）。
  ///
  /// 所以先按 chip 找，找不到就**先回创作台再点那个入口** —— 这样各条测试的
  /// 调用点不用改。
  Future<void> tapMode(WidgetTester tester, String label) async {
    var target = find.ancestor(
        of: find.text(label), matching: find.byType(ChoiceChip));
    if (target.evaluate().isEmpty) {
      final back = find.byTooltip('回创作台');
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back);
        await tester.pumpAndSettle();
      }
      target = find.ancestor(
          of: find.text(label), matching: find.byType(InkWell));
    }
    expect(target, findsWidgets, reason: '找不到「$label」（既不是选项，也不是创作台入口）');
    final t = target.first;
    await tester.ensureVisible(t);
    await tester.tap(t);
    await tester.pumpAndSettle();
  }

  testWidgets('创作台入口屏：六个生成模式 + 三条创作线都在，且各带一句说明', (tester) async {
    // 用户 2026-10-12 提议：这一页先给一屏功能入口，点进去才是详情。
    await pump(tester, enter: null);
    expect(find.text('创作台'), findsOneWidget, reason: '入口屏的标题');
    // 六个"生成模式"（走 _openFunction 的表单）……
    for (final m in <String>['生图', '生视频', '修图', '口播', '短剧']) {
      expect(find.text(m), findsOneWidget, reason: '创作台上缺了「$m」入口');
    }
    // 「作品」**2026-10-12 起不在创作台**了（用户反馈第 4 条：挪进「资料库」）——
    // 所以这里反向断言，防止以后有人"顺手"又把它加回入口屏。
    expect(find.text('作品'), findsNothing,
        reason: '「作品」已挪到「资料库」右上角，不该再出现在创作台入口屏');
    // ……再加三条**不是表单**的创作线：画图表（弹层）、小说改游戏（说明页）、
    // AI 角色（说明页）。它们的形状和上面六个不一样，混在一起容易在改版时被漏掉。
    for (final m in <String>['剪辑', '画图表', '创作 · 小说改游戏', 'AI 角色（实验）']) {
      expect(find.text(m), findsOneWidget, reason: '创作台上缺了「$m」入口');
    }
    // 每个入口都要写清"点进去能干什么"（不许只给一个名字让人猜）
    expect(find.textContaining('一句话或一张参考图'), findsOneWidget);
    expect(find.textContaining('本机处理，不联网'), findsOneWidget);
    expect(find.textContaining('选一个功能开始'), findsOneWidget);
    expect(find.textContaining('每局都有目标和结束条件'), findsOneWidget,
        reason: 'AI 角色那一格要说清"有目标"，否则会被当成又一个聊天入口');
    // 入口屏上不该有"回创作台"（我们就在创作台）
    expect(find.byTooltip('回创作台'), findsNothing);
  });

  testWidgets('点「AI 角色（实验）」进的是开局牌说明页，不是又一个表单', (tester) async {
    await pump(tester, enter: null);
    final entry = find.ancestor(
        of: find.text('AI 角色（实验）'), matching: find.byType(InkWell));
    await tester.tap(entry.first);
    await tester.pumpAndSettle();

    expect(find.text('选一张开局牌'), findsOneWidget, reason: '进到 AI 角色页了');
    expect(find.text('审讯室'), findsOneWidget, reason: '三张开局牌要都在');
    expect(find.text('断电的太空舱'), findsOneWidget);
    expect(find.text('深夜电台'), findsOneWidget);
    // 边界要写在页面上（不许把"不能朗读回复"这种事实藏起来）
    expect(find.text('边界（如实说）'), findsOneWidget);
    // 这一页是**推入**的：原路能回创作台
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('创作台'), findsOneWidget);
  });

  testWidgets('点入口进详情页：标题变成「创作台 · 生图」，且有一条回创作台的路',
      (tester) async {
    await pump(tester, enter: null);
    await tapMode(tester, '生图');
    expect(find.text('创作台 · 生图'), findsOneWidget);
    expect(find.text('生成图片'), findsOneWidget, reason: '进到生图页了');
    // 回创作台 → 又看到那一屏入口
    await tester.tap(find.byTooltip('回创作台'));
    await tester.pumpAndSettle();
    expect(find.text('创作台'), findsOneWidget);
    expect(find.text('生视频'), findsOneWidget, reason: '回到入口屏，六个入口都在');
  });

  testWidgets('生图页有输入框、清晰度与比例选项、生成按钮', (tester) async {
    await pump(tester);
    expect(find.byType(TextField), findsOneWidget);
    for (final s in <String>['1K', '2K', '3K', '4K']) {
      expect(find.text(s), findsOneWidget, reason: '清晰度缺了 $s');
    }
    for (final r in <String>['1:1', '3:4', '4:3', '16:9', '9:16']) {
      expect(find.text(r), findsOneWidget, reason: '比例缺了 $r');
    }
    expect(find.text('生成图片'), findsOneWidget);
    // 「少打字」的核心入口
    expect(find.text('写专业点（一句话也行）'), findsOneWidget);
  });

  testWidgets('⚠️ 没写提示词就点生成 → 只提示，不乱起进程', (tester) async {
    await pump(tester);
    await tester.tap(find.text('生成图片'));
    await tester.pump(); // 让 SnackBar 出来
    expect(find.text('先写一句你想要的画面。'), findsOneWidget);
    // 不该出现"生成中"的进度卡片
    expect(find.textContaining('已等'), findsNothing);
  });

  testWidgets('切到「生视频」：分辨率 / 时长 / 画幅选项齐（档位来自厂家矩阵）', (tester) async {
    await pump(tester);
    await tapMode(tester, '生视频');
    // Agnes 的档位：分辨率只认 720P，时长 1–10 秒，画幅三选一
    expect(find.text('分辨率'), findsOneWidget);
    expect(find.text('720P'), findsOneWidget);
    for (final s in <String>['1', '3', '5', '7', '9', '10']) {
      expect(find.text(s), findsOneWidget, reason: '时长缺了 $s');
    }
    expect(find.text('16:9'), findsOneWidget);
    expect(find.text('9:16'), findsOneWidget);
    expect(find.text('1:1'), findsOneWidget);
    expect(find.text('生成视频'), findsOneWidget);
    expect(find.text('选首帧图'), findsOneWidget);
    expect(find.text('时长（秒）'), findsOneWidget);
    // 小字如实说明这一家的档位（Agnes 只认 720P）
    expect(find.textContaining('Agnes 的分辨率只认 720P'), findsOneWidget);
  });

  // ── 2026-10-11 用户纠正：「影视这个工具实际是可以使用多个厂家」──────
  // 下面这一组证明**界面上只给这家能接受的档位**（不是写死 Agnes 那一套）。

  testWidgets('⚠️ 生图档位按厂家换：Agnes 是 1K/2K 档位，万相换成像素尺寸且**没有比例**',
      (tester) async {
    // 先在 Agnes（内置默认）下看一眼：档位 1K/2K/3K/4K + 比例五选一
    await pump(tester);
    expect(find.text('清晰度'), findsOneWidget);
    for (final s in <String>['1K', '2K', '3K', '4K']) {
      expect(find.text(s), findsOneWidget, reason: 'Agnes 的档位缺了 $s');
    }
    expect(find.text('画面比例'), findsOneWidget);

    // 换成万相（走的是"选中另一条模型"这条路：页面重读配置 →
    // `_syncVendorOptions` 把不支持的档位拉回来）
    writeMediaModels(<String, dynamic>{
      'version': 1,
      'custom': <Map<String, dynamic>>[
        model(
            provider: 'dashscope',
            id: 'wanx2.1-t2i-turbo',
            baseUrl: 'https://dashscope.aliyuncs.com'),
      ],
      'selectedImage': 'dashscope/wanx2.1-t2i-turbo',
    });
    // refreshTick 变了 → didUpdateWidget → 重读配置（真实 App 里就是从设置页回来）
    await pump(tester, refreshTick: 1);

    // 万相：size 是像素值（标签也从"清晰度"变成"尺寸"）、**没有比例这一行**
    expect(find.text('尺寸'), findsOneWidget);
    expect(find.text('1024x1024'), findsOneWidget);
    expect(find.text('1K'), findsNothing, reason: '万相不吃 1K/2K 档位');
    expect(find.text('画面比例'), findsNothing,
        reason: '万相没有 ratio 参数，给了就是发一个上游不认的字段');
    expect(find.text('16:9'), findsNothing);
    // 回落**不静默**：小字里说清改成了什么
    expect(find.textContaining('已按这家支持的档位改成'), findsOneWidget);
    expect(find.textContaining('1024x1024'), findsWidgets);
    expect(find.textContaining('万相没有比例参数'), findsOneWidget);
  });

  testWidgets('⚠️ MiniMax 图像：没有尺寸行、没有参考图行（它只吃 aspect_ratio）',
      (tester) async {
    writeMediaModels(<String, dynamic>{
      'version': 1,
      'custom': <Map<String, dynamic>>[
        model(
            provider: 'minimax',
            id: 'image-01',
            baseUrl: 'https://api.minimax.cn/v1'),
      ],
      'selectedImage': 'minimax/image-01',
    });
    await pump(tester);
    expect(find.text('清晰度'), findsNothing);
    expect(find.text('尺寸'), findsNothing);
    expect(find.text('画面比例'), findsOneWidget);
    expect(find.text('16:9'), findsOneWidget);
    expect(find.text('参考图（可选，最多 4 张）'), findsNothing,
        reason: 'MiniMax 图像不吃参考图，给了就是必然失败');
    expect(find.textContaining('MiniMax 吃 aspect_ratio'), findsOneWidget);
  });

  testWidgets('⚠️ 硅基流动视频：**不显示时长**（这家没有时长参数），并如实说明为什么',
      (tester) async {
    writeMediaModels(<String, dynamic>{
      'version': 1,
      'custom': <Map<String, dynamic>>[
        model(
            provider: 'siliconflow',
            id: 'Wan-AI/Wan2.2-T2V-A14B',
            baseUrl: 'https://api.siliconflow.cn/v1',
            kind: 'video'),
      ],
      'selectedVideo': 'siliconflow/Wan-AI/Wan2.2-T2V-A14B',
    });
    await pump(tester);
    await tapMode(tester, '生视频');
    expect(find.text('时长（秒）'), findsNothing,
        reason: '这家没有时长参数，给一个必然被忽略的选项比不给更糟');
    expect(find.text('分辨率'), findsNothing, reason: '它按比例换算 image_size');
    expect(find.text('画幅'), findsOneWidget);
    expect(find.text('16:9'), findsOneWidget);
    expect(find.textContaining('硅基流动没有时长参数'), findsOneWidget,
        reason: '不显示某一项时必须如实说为什么');
    expect(find.text('生成视频'), findsOneWidget);
  });

  testWidgets('⚠️ 豆包 Seedance 视频：**不显示分辨率**（请求里不发），时长取宽到 30 秒',
      (tester) async {
    writeMediaModels(<String, dynamic>{
      'version': 1,
      'custom': <Map<String, dynamic>>[
        model(
            provider: 'doubao',
            id: 'doubao-seedance-1-0-pro',
            baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
            kind: 'video'),
      ],
      'selectedVideo': 'doubao/doubao-seedance-1-0-pro',
    });
    await pump(tester);
    await tapMode(tester, '生视频');
    expect(find.text('分辨率'), findsNothing,
        reason: '豆包 Seedance 这份请求不发分辨率');
    expect(find.text('720P'), findsNothing);
    expect(find.text('时长（秒）'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('30'), findsOneWidget, reason: '2.5 支持到 30 秒，取宽的');
    expect(find.text('画幅'), findsOneWidget);
    expect(find.text('21:9'), findsOneWidget, reason: 'Seedance 支持 21:9');
    expect(find.textContaining('豆包 Seedance 的分辨率由模型与比例决定'), findsOneWidget);
  });

  testWidgets('⚠️ 选了不支持视频的厂家（OpenAI）：不给必然失败的按钮，明确说"没接视频"',
      (tester) async {
    writeMediaModels(<String, dynamic>{
      'version': 1,
      'custom': <Map<String, dynamic>>[
        model(
            provider: 'openai',
            id: 'some-video-model',
            baseUrl: 'https://api.openai.com/v1',
            kind: 'video'),
      ],
      'selectedVideo': 'openai/some-video-model',
    });
    await pump(tester);
    await tapMode(tester, '生视频');
    expect(find.text('生成视频'), findsNothing, reason: '必然失败的按钮不如不给');
    expect(find.textContaining('这家在本 App 里没接视频'), findsOneWidget);
    expect(find.text('换一个'), findsOneWidget, reason: '要留一条换回支持视频的厂家的路');
    expect(find.text('时长（秒）'), findsNothing);
  });

  // （原「六个模式都在」那条已并入上面新写的**创作台入口屏**测试：
  //   现在六个功能是入口屏上的六行卡片，不是详情页顶上的六个 chip，
  //   断言点也换了 —— 入口屏要连"每个入口带一句说明"一起查。）

  testWidgets('生图 / 生视频页顶部有模型行（默认是内置 Agnes，来自「设置 → 图像 / 视频模型」）', (tester) async {
    await pump(tester);
    expect(find.text('生图模型'), findsOneWidget);
    expect(find.text('换一个'), findsWidgets);
    expect(find.textContaining('agnes-image'), findsWidgets,
        reason: '默认该是内置的 Agnes 图像模型');
    await tapMode(tester, '生视频');
    expect(find.text('生视频模型'), findsOneWidget);
    expect(find.textContaining('agnes-video'), findsWidgets,
        reason: '默认该是内置的 Agnes 视频模型');
    // 点「换一个」要真的弹出候选（而不是个死按钮）
    await tester.tap(find.text('换一个').first);
    await tester.pumpAndSettle();
    expect(find.text('用哪个视频模型？'), findsOneWidget);
  });

  testWidgets('修图页：选图入口 / 六个美化档位 / 强度滑杆 / 去水印开关 / 开始按钮', (tester) async {
    await pump(tester);
    await tapMode(tester, '修图');
    expect(find.text('要修的图'), findsOneWidget);
    expect(find.text('还没选图。可以从相册选，也可以直接用「作品」里已经生成的那张。'),
        findsOneWidget);
    expect(find.text('选一张图'), findsOneWidget);
    expect(find.text('从「作品」里选'), findsOneWidget);
    expect(find.text('一键美化'), findsOneWidget);
    for (final p in <String>['通透', '电影感', '人像', '暖调', '冷调', '不美化']) {
      expect(find.text(p), findsOneWidget, reason: '缺了档位「$p」');
    }
    expect(find.text('强度'), findsNothing, reason: '强度是滑杆标签，写成「强度：60」整句');
    expect(find.textContaining('强度'), findsWidgets);
    expect(find.byType(Slider), findsOneWidget, reason: '只该有强度滑杆（还没开擦除）');
    // 2026-10-11 用户口径：这一项改名「擦除」（去水印是其中一种用法，不是全部）。
    expect(find.text('擦除（去水印 / 去杂物）'), findsOneWidget);
    expect(find.text('开始修图'), findsOneWidget);
  });

  testWidgets('⚠️ 修图：没选图就点「开始修图」→ 只提示，不乱起进程', (tester) async {
    await pump(tester);
    await tapMode(tester, '修图');
    await tester.tap(find.text('开始修图'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('先选一张要修的图。'), findsOneWidget);
  });

  testWidgets('⚠️ 修图：选「不美化」后强度滑杆消失（没有可调的强度）', (tester) async {
    await pump(tester);
    await tapMode(tester, '修图');
    expect(find.byType(Slider), findsOneWidget);
    await tester.tap(find.text('不美化'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing, reason: '不美化就不该再显示强度滑杆');
  });

  testWidgets('口播页：文稿框 / 形象图 / 画幅 / 生成按钮都在', (tester) async {
    await pump(tester);
    await tapMode(tester, '口播');
    expect(find.byType(TextField), findsOneWidget, reason: '口播要有文稿输入框');
    expect(find.text('选一张图'), findsOneWidget, reason: '要能选形象图');
    for (final r in <String>['9:16', '16:9', '1:1']) {
      expect(find.text(r), findsOneWidget, reason: '画幅缺了 $r');
    }
    expect(find.text('生成口播视频'), findsOneWidget);
  });

  testWidgets('⚠️ 口播默认用「系统配音」（不是 MiMo）—— 网友不一定注册过 MiMo', (tester) async {
    await pump(tester);
    await tapMode(tester, '口播');
    expect(find.text('系统配音（零配置）'), findsOneWidget);
    expect(find.text('MiMo（更自然·需 Key）'), findsOneWidget);
    // 默认选中系统配音，而且说明**必须如实**：零配置、但**不能承诺"任何设备都能用"**
    // （2026-10-12 真机反馈第 2/3 条：用户的手机一个 TTS 引擎都没有）。
    expect(find.textContaining('零配置、免费、可离线'), findsOneWidget,
        reason: '默认仍是系统配音，但说明要如实');
    expect(find.textContaining('任何设备都能用'), findsNothing,
        reason: '不能再写"任何设备都能用" —— 真机上就是没有引擎');
    expect(find.textContaining('不是每台手机都装了语音引擎'), findsOneWidget,
        reason: '必须把"可能没引擎"写在明面上');
    // 一步走到"改用 MiMo"的那条路
    expect(find.text('这台手机没有语音引擎？改用 MiMo（需 Key）'), findsOneWidget);
    // 切到 MiMo 后，说明里必须写清"需要 Key"
    await tester.tap(find.text('MiMo（更自然·需 Key）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('先填一个 API Key'), findsOneWidget);
  });

  testWidgets('⚠️ 口播：文稿为空就点生成 → 只提示，不乱跑（不配音、不合成）', (tester) async {
    await pump(tester);
    await tapMode(tester, '口播');
    await tester.tap(find.text('生成口播视频'));
    await tester.pump();
    expect(find.text('先把要念的稿子写进来。'), findsOneWidget);
    expect(find.textContaining('已等'), findsNothing, reason: '不该进入"正在生成"状态');
  });

  testWidgets('短剧页：每镜一行的输入框 + 「每镜生成新画面」开关 + 生成按钮', (tester) async {
    await pump(tester);
    await tapMode(tester, '短剧');
    expect(find.text('每镜生成一张新画面（按该行文本用生图）'), findsOneWidget);
    expect(find.text('统一形象图（可选）'), findsOneWidget);
    expect(find.text('生成短剧视频'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsOneWidget);
  });

  testWidgets('⚠️ 短剧：没写镜头就点生成 → 只提示', (tester) async {
    await pump(tester);
    await tapMode(tester, '短剧');
    await tester.tap(find.text('生成短剧视频'));
    await tester.pump();
    expect(find.text('先写几个镜头（一行一个）。'), findsOneWidget);
    expect(find.textContaining('已等'), findsNothing);
  });

  testWidgets('作品页：没有作品时给明确的空状态（而不是一片空白）', (tester) async {
    await pump(tester, initialSeg: 5);
    expect(find.text('还没有作品'), findsOneWidget);
    expect(find.textContaining('它会自动出现在这里'), findsOneWidget);
  });

  testWidgets('作品页：已生成的图片会以缩略图出现（作品库真的读目录）', (tester) async {
    // 先按服务的约定把产物放好
    final imgDir = Directory('${tmp.path}/media/image')
      ..createSync(recursive: true);
    File('${imgDir.path}/a.png').writeAsBytesSync(<int>[137, 80, 78, 71]);
    await pump(tester, initialSeg: 5);
    expect(find.text('还没有作品'), findsNothing);
    // 网格里那一项的说明文字（时间标签）；大小也在
    expect(find.textContaining('B'), findsWidgets);
    // 统一总库：每张卡片都标来源（"这张是哪来的"是用户第一个疑问）
    expect(find.text('来自影视'), findsOneWidget);
    // 页面上那句"汇集了所有生成过的图片和视频"（解释为什么这里会有会话生成的）
    expect(find.textContaining('这里汇集了'), findsOneWidget);
  });

  testWidgets('右上角是「三个模型」而不是小钥匙；「去设置配 Key」并进了那张菜单', (tester) async {
    // 2026-10-12 真机反馈第 9 条：把「小钥匙」换成文本/图形/视频三个模型的选择。
    var opened = false;
    await pump(tester, onOpenSettings: () => opened = true);
    expect(find.byIcon(Icons.key_outlined), findsNothing,
        reason: '小钥匙应该已经被「三个模型」那个按钮取代');
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    // 三行都在（文本那一行要传 models 才显示 —— 这里没传，所以只断言图形/视频）
    expect(find.text('图形模型'), findsOneWidget);
    expect(find.text('视频模型'), findsOneWidget);
    // 「去设置里配 Key」点下去必须走回调（必须由壳层切页 —— 写死下标就是老毛病）
    await tester.tap(find.text('去设置里配 Key'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
  });

  testWidgets('配音来源有「本机离线」，选中后给出"还没装模型"的状态与下载入口', (tester) async {
    await pump(tester);
    await tapMode(tester, '口播');
    // 它是**零 Key**的那条路，放在最前（用户 2026-10-13 要求）。
    expect(find.text('本机离线（零 Key）'), findsOneWidget);
    await tester.tap(find.text('本机离线（零 Key）'));
    await tester.pumpAndSettle();
    // 未装模型时：状态 + 下载按钮 + 手动放置的目录（不能只给一个点了没反应的按钮）
    expect(find.textContaining('还没装模型'), findsOneWidget);
    expect(find.text('下载模型（31.5 MB）'), findsOneWidget);
    expect(find.textContaining('也可以手动装'), findsOneWidget);
    // 说明里必须**如实**写清代价（音色更机械 / 速度未实测）
    expect(find.textContaining('比云端机械'), findsOneWidget);
    expect(find.textContaining('还没在真机上量过'), findsOneWidget);
    // 这时候不该再显示云端那两家的音色/语速控件（它们对离线模型没有意义）
    expect(find.text('MiMo 的音色更自然'), findsNothing);
  });

  testWidgets('「三个模型」菜单：文本那一行在，没配模型时给的是明确空态', (tester) async {
    // ⚠️ **刻意不 load()** —— `ModelStore.load` 会走安全存储那条平台通道，
    //    在 widget 测试里会挂住（这一条就是这么踩出来的）。空清单正好用来
    //    断言"没模型时说什么"：不能只给一个点不开的列表。
    final store = ModelStore();
    await pump(tester, models: store);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('文本模型'), findsOneWidget);
    expect(find.text('（还没选 —— 去设置里选一个）'), findsOneWidget);
    await tester.tap(find.text('文本模型'));
    await tester.pumpAndSettle();
    expect(find.text('用哪个文本模型？'), findsOneWidget);
    expect(find.text('还没有任何模型 —— 先去「设置 → 模型」加一个。'), findsOneWidget,
        reason: '空清单必须说清下一步，而不是给一个空白列表');
  });

  // ───────────────────────────────────────────── 配音（口播 / 短剧）
  //
  // 这三家是**落盘偏好**，而且两家云厂商的"音色"含义不同：
  //   * MiMo 的音色是官方文档那 9 个（含中文词本身当 id）；
  //   * MiniMax 的音色跟着账号走，界面上只能"拉取"（我们不写死清单）。
  // 这里只钉界面行为（哪个控件在、显示的是哪一家的东西）；
  // 真发请求那条路在 `tts_providers_test.dart` 里按契约测。
  group('配音：三家可选，音色与语速随来源切换', () {
    /// 打开音色下拉并选中某一项（下拉项很多，用文本片段定位）。
    Future<void> pickVoice(WidgetTester tester, String fragment) async {
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(fragment).last);
      await tester.pumpAndSettle();
    }

    testWidgets('口播页有三家 chip；默认是系统配音（人人可用那家）', (tester) async {
      await pump(tester);
      await tapMode(tester, '口播');
      expect(find.text('系统配音（零配置）'), findsOneWidget);
      expect(find.text('MiMo（更自然·需 Key）'), findsOneWidget);
      expect(find.text('MiniMax（多音色·需 Key）'), findsOneWidget);
      // 系统配音没有音色/语速可选（它走原生参数），别摆一个空下拉骗人
      expect(find.text('音色'), findsNothing);
      expect(find.text('拉取音色'), findsNothing);
    });

    testWidgets('切到 MiMo：有音色下拉 + 三档语速 chip（不是滑杆）', (tester) async {
      await pump(tester);
      await tapMode(tester, '口播');
      await tapMode(tester, 'MiMo（更自然·需 Key）');
      expect(find.text('音色'), findsOneWidget);
      // 默认音色（官方 `mimo_default` → 国内集群是「冰糖」）
      expect(find.textContaining('默认（跟随集群）'), findsOneWidget);
      // 三档语速：MiMo 官方没有数值语速参数，所以给档位而不是滑杆
      for (final label in <String>['慢一点', '正常', '快一点']) {
        expect(find.text(label), findsOneWidget, reason: '语速档位缺了「$label」');
      }
      expect(find.byType(Slider), findsNothing,
          reason: 'MiMo 没有数值语速参数，给滑杆就是假的');
      // 这句如实说明必须在场上（"效果由模型理解"）
      expect(find.textContaining('没有数值语速参数'), findsOneWidget);
    });

    testWidgets('切到 MiniMax：能拉取音色、语速是滑杆、默认音色是官方 CLI 那个', (tester) async {
      await pump(tester);
      await tapMode(tester, '口播');
      await tapMode(tester, 'MiniMax（多音色·需 Key）');
      expect(find.text('音色'), findsOneWidget);
      expect(find.text('拉取音色'), findsOneWidget);
      expect(find.textContaining('MiniMax 默认（英文叙事）'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget, reason: 'MiniMax 有真正的倍率参数');
      expect(find.textContaining('1.00×'), findsWidgets);
    });

    testWidgets('⚠️ 换来源时音色下拉必须跟着换（不许还显示上一家的）', (tester) async {
      await pump(tester);
      await tapMode(tester, '口播');

      // 在 MiMo 下挑一个**非默认**音色
      await tapMode(tester, 'MiMo（更自然·需 Key）');
      await pickVoice(tester, '冰糖');
      expect(find.textContaining('冰糖 ·'), findsOneWidget,
          reason: '选了就该显示选中的那个');

      // 换到 MiniMax：显示必须是 MiniMax 的默认音色，**不能**还是「冰糖」
      await tapMode(tester, 'MiniMax（多音色·需 Key）');
      expect(find.textContaining('MiniMax 默认（英文叙事）'), findsOneWidget);
      expect(find.textContaining('冰糖 ·'), findsNothing,
          reason: '下拉如果还显示上一家的音色，界面与真实状态就不一致了'
              '（这正是 `DropdownButtonFormField.initialValue` 的那个坑）');

      // 换回 MiMo：上次挑的还在（按家分开存）
      await tapMode(tester, 'MiMo（更自然·需 Key）');
      expect(find.textContaining('冰糖 ·'), findsOneWidget,
          reason: '按家分开存的音色，换走再换回来应该还在');
    });
  });
}
