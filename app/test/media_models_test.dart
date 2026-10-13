/// 「图像 / 视频模型」清单（`data/media_models.dart`）。
///
/// ## 为什么值得单测
///
/// 用户 2026-10-11 提的设计问题（"设置好后能在影视工具里选图像/视频模型"）落地后，
/// 这份文件成了**影视页能不能生成**的前提：它读坏了 → 影视页一个模型都列不出来；
/// 它选错了 → 用户以为换了模型、其实还在用内置那条。所以下面把
/// 「内置兜底 / 往返存读 / 加与删 / 坏文件 / 死引用回落」逐条钉住。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/data/agnes_builtin.dart';
import 'package:dsh_mobile/data/media_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsh-media-models-');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('内置兜底', () {
    test('没配过时：候选里就有内置的图像与视频模型，且默认选中它', () {
      final cfg = MediaModels.read(tmp.path);
      final imgs = MediaModels.choices(cfg, 'image');
      final vids = MediaModels.choices(cfg, 'video');
      expect(imgs.length, 1);
      expect(vids.length, 1);
      expect(imgs.first.id, AgnesBuiltin.imageModel);
      expect(vids.first.id, AgnesBuiltin.videoModel);
      expect(imgs.first.builtin, isTrue);
      expect(File('${tmp.path}/media-models.json').existsSync(), isFalse,
          reason: '只读不该写盘');
      expect(MediaModels.selected(cfg, 'image').route,
          '${AgnesBuiltin.providerId}/${AgnesBuiltin.imageModel}');
      expect(MediaModels.selected(cfg, 'video').route,
          '${AgnesBuiltin.providerId}/${AgnesBuiltin.videoModel}');
    });
  });

  group('选择与增删', () {
    test('加一条自定义图像模型 → 进候选、并被选中（用户的意图很明确）', () async {
      await MediaModels.add(
        filesDir: tmp.path,
        model: const MediaModelSpec(
          provider: 'myvendor',
          id: 'my-image-1',
          baseUrl: 'https://api.example.com/v1',
          label: '我的图像模型',
          kind: 'image',
        ),
      );
      final cfg = MediaModels.read(tmp.path);
      final imgs = MediaModels.choices(cfg, 'image');
      expect(imgs.length, 2, reason: '内置 + 自定义');
      expect(imgs.first.builtin, isTrue, reason: '内置永远排最前');
      final sel = MediaModels.selected(cfg, 'image');
      expect(sel.route, 'myvendor/my-image-1');
      expect(sel.displayName, '我的图像模型');
      // 视频那边不受影响
      expect(MediaModels.selected(cfg, 'video').builtin, isTrue);
    });

    test('同 route 再加一次是覆盖（不是两条）', () async {
      const m = MediaModelSpec(
          provider: 'v', id: 'x', baseUrl: 'https://a/v1', label: 'A', kind: 'image');
      await MediaModels.add(filesDir: tmp.path, model: m);
      await MediaModels.add(
          filesDir: tmp.path,
          model: const MediaModelSpec(
              provider: 'v',
              id: 'x',
              baseUrl: 'https://a/v1',
              label: 'B',
              kind: 'image'));
      final list = MediaModels.choices(MediaModels.read(tmp.path), 'image');
      expect(list.length, 2, reason: '内置 + 1 条');
      expect(list.last.displayName, 'B');
    });

    test('删掉自定义项 → 候选少一条，且选中回到内置默认', () async {
      await MediaModels.add(
        filesDir: tmp.path,
        model: const MediaModelSpec(
            provider: 'v', id: 'x', baseUrl: 'https://a/v1', kind: 'image'),
      );
      await MediaModels.remove(filesDir: tmp.path, route: 'v/x');
      final cfg = MediaModels.read(tmp.path);
      expect(MediaModels.choices(cfg, 'image').length, 1);
      expect(MediaModels.selected(cfg, 'image').builtin, isTrue);
    });

    test('内置那两条删不掉（它们不在 custom 里）', () async {
      const builtinRoute =
          '${AgnesBuiltin.providerId}/${AgnesBuiltin.imageModel}';
      await MediaModels.remove(filesDir: tmp.path, route: builtinRoute);
      final cfg = MediaModels.read(tmp.path);
      expect(MediaModels.choices(cfg, 'image').length, 1);
      expect(MediaModels.selected(cfg, 'image').route, builtinRoute);
    });

    test('select 存的是 route，读写往返一致', () async {
      await MediaModels.add(
        filesDir: tmp.path,
        model: const MediaModelSpec(
            provider: 'v', id: 'v1', baseUrl: 'https://a/v1', kind: 'video'),
      );
      await MediaModels.select(
          filesDir: tmp.path, kind: 'video', route: 'v/v1');
      expect(MediaModels.selected(MediaModels.read(tmp.path), 'video').route,
          'v/v1');
      // 传 null = 回到内置默认
      await MediaModels.select(filesDir: tmp.path, kind: 'video', route: null);
      expect(MediaModels.selected(MediaModels.read(tmp.path), 'video').builtin,
          isTrue);
    });
  });

  group('坏文件与死引用（都不许把界面搞死）', () {
    test('坏 JSON → 返回内置兜底 + 挪到 .corrupt + 记下原因', () async {
      final f = File('${tmp.path}/media-models.json');
      await f.writeAsString('{这不是 JSON');
      final cfg = MediaModels.read(tmp.path);
      expect(MediaModels.choices(cfg, 'image').length, 1, reason: '仍要有内置兜底');
      expect(MediaModels.lastReadError, isNotNull, reason: '必须让界面能说出来');
      expect(File('${tmp.path}/media-models.json.corrupt').existsSync(), isTrue,
          reason: '用户的原始字节要保住，不能就这样被覆盖掉');
    });

    test('两处都不是对象（JSON 是数组）也算坏文件', () async {
      await File('${tmp.path}/media-models.json').writeAsString('[1,2,3]');
      final cfg = MediaModels.read(tmp.path);
      expect(MediaModels.choices(cfg, 'video').length, 1);
      expect(MediaModels.lastReadError, isNotNull);
    });

    test('选中项指向一个已经不存在的 route → 回落到内置默认（不留死引用）', () async {
      await File('${tmp.path}/media-models.json').writeAsString(jsonEncode(
          <String, dynamic>{'version': 1, 'custom': <dynamic>[], 'selectedImage': 'gone/x'}));
      final cfg = MediaModels.read(tmp.path);
      final sel = MediaModels.selected(cfg, 'image');
      expect(sel.builtin, isTrue);
      expect(sel.route, '${AgnesBuiltin.providerId}/${AgnesBuiltin.imageModel}');
    });

    test('custom 里的垃圾条目被跳过（不整份读不出来）', () async {
      await File('${tmp.path}/media-models.json').writeAsString(jsonEncode(<String, dynamic>{
        'version': 1,
        'custom': <dynamic>[
          <String, dynamic>{'nope': true},
          <String, dynamic>{'provider': 'v', 'id': 'ok', 'baseUrl': 'https://a/v1', 'kind': 'image'},
        ],
      }));
      final list = MediaModels.choices(MediaModels.read(tmp.path), 'image');
      expect(list.length, 2, reason: '内置 + 唯一一条合法自定义');
      expect(list.last.route, 'v/ok');
    });

    test('kind 写错（或缺失）时按图像处理，视频那条不会混进图像候选', () async {
      await File('${tmp.path}/media-models.json').writeAsString(jsonEncode(<String, dynamic>{
        'version': 1,
        'custom': <dynamic>[
          <String, dynamic>{'provider': 'v', 'id': 'weird', 'baseUrl': 'https://a/v1', 'kind': 'audio'},
        ],
      }));
      final cfg = MediaModels.read(tmp.path);
      expect(MediaModels.choices(cfg, 'image').map((m) => m.route), contains('v/weird'));
      expect(MediaModels.choices(cfg, 'video').map((m) => m.route), isNot(contains('v/weird')));
    });
  });

  // 用户 2026-10-11：「视频和图形大模型是可以添加外部厂商，这样吧直接内置外部厂商的端点」
  // —— 这一组钉住那张预设表本身没写错（写错了用户点了只会得到一条必然失败的模型，
  // 而且界面上看起来是"内置好了"）。
  group('内置外部厂商预设', () {
    test('每家都是 https 端点、模型名非空、厂家 id 已经是规范形态', () {
      const list = MediaModels.externalPresets;
      expect(list, isNotEmpty);
      for (final p in list) {
        expect(p.vendor.trim(), isNotEmpty);
        expect(p.baseUrl.startsWith('https://'), isTrue,
            reason: '${p.vendor} 的端点必须是 https（Key 会发到那里）');
        expect(p.model.trim(), isNotEmpty, reason: '${p.vendor} 没有建议模型名');
        expect(p.provider.trim(), isNotEmpty);
        // 厂家 id 决定"去哪读 Key"（ProviderKeys 用同一个 id），
        // 而 ConfiguredModels 落盘时会 sanitize —— 预设必须**已经**是那个形态，
        // 否则用户照着界面填的 id 和读 Key 用的 id 会差一个字符。
        expect(p.provider, p.provider.trim().toLowerCase(),
            reason: '${p.vendor} 的厂家 id 必须是小写');
        expect(RegExp(r'^[a-z0-9_.-]+$').hasMatch(p.provider), isTrue,
            reason: '${p.vendor} 的厂家 id 含非法字符：${p.provider}');
        // 不能撞内置的 agnes（撞了就是"读 Agnes 的 Key 去打别家"）。
        expect(p.provider, isNot(MediaModels.builtinProvider));
      }
    });

    test('厂家不重复（两个同名 chip 用户分不清点的是哪家）', () {
      final vendors = MediaModels.externalPresets.map((p) => p.vendor).toList();
      expect(vendors.toSet().length, vendors.length);
    });

    test('预设都是图像模型（视频另有一张表，见下面那组）', () {
      for (final p in MediaModels.externalPresets) {
        expect(p.model, isNot(contains('video')));
        expect(MediaVendors.ids, contains(p.provider),
            reason: '${p.vendor} 的厂家 id 不在形状表的厂家清单里');
      }
    });

    // 2026-10-11：视频也有内置外部厂商了 —— 0.61 那句"视频没有内置外部厂商"
    // 现在已经不对了，所以这一组钉住新的事实。
    test('视频也有内置外部厂商：豆包 Seedance / MiniMax / 万相 / 硅基流动', () {
      const list = MediaModels.externalVideoPresets;
      expect(list.length, 4);
      // 端点必须与脚本的形状表（media-vendors.mjs 的 base）**逐字一致** ——
      // 各写一份就会出现"界面填的是 A、脚本发的是 B"这种最难查的错。
      const wantBases = <String, String>{
        'doubao': 'https://ark.cn-beijing.volces.com/api/v3',
        'minimax': 'https://api.minimax.cn/v1',
        'dashscope': 'https://dashscope.aliyuncs.com',
        'siliconflow': 'https://api.siliconflow.cn/v1',
      };
      for (final p in list) {
        expect(p.vendor.trim(), isNotEmpty);
        expect(p.model.trim(), isNotEmpty, reason: '${p.vendor} 没有建议模型名');
        expect(wantBases.containsKey(p.provider), isTrue,
            reason: '${p.vendor} 的厂家 id 不是这四家之一：${p.provider}');
        expect(p.baseUrl, wantBases[p.provider],
            reason: '${p.vendor} 的端点与形状表不一致');
        expect(MediaVendors.supportsVideo(p.provider), isTrue,
            reason: '${p.vendor} 是视频预设，但矩阵里这家不支持视频');
        expect(p.provider, isNot(MediaModels.builtinProvider),
            reason: '内置那家（agnes）不该再作为"外部厂商"出现');
      }
      final ids = list.map((p) => p.provider).toList();
      expect(ids.toSet().length, ids.length, reason: '视频预设厂家不重复');
      // 豆包的模型名是**接入点 id**，用户要照控制台填（注释里也写了）
      expect(list.firstWhere((p) => p.provider == 'doubao').model,
          'doubao-seedance-1-0-pro');
    });
  });

  // 用户 2026-10-11 明确纠正：「影视这个工具实际是可以使用多个厂家」——
  // 脚本侧按厂家换请求形状（assets/toolbox/media-vendors.mjs，唯一来源），
  // Dart 侧这张矩阵决定**界面上给哪些档位**。两边对不上就会给出"必然失败"的选项。
  group('厂家参数矩阵', () {
    test('每个已知厂家都查得到矩阵（查不到就抛异常 = 界面直接崩）', () {
      for (final id in MediaVendors.ids) {
        final img = MediaVendors.imageOptions(id);
        expect(img.sizes.isNotEmpty || img.ratios.isNotEmpty, isTrue,
            reason: '$id 的图像档位全空，界面会一项都不显示');
        // 视频允许为 null（OpenAI / 自定义厂家在本 App 里没接视频）
        final vid = MediaVendors.videoOptions(id);
        if (vid != null) {
          expect(vid.ratios.isNotEmpty || vid.resolutions.isNotEmpty, isTrue,
              reason: '$id 的视频档位全空');
        }
        expect(MediaVendors.supportsVideo(id), vid != null);
        expect(MediaVendors.supportsImage(id), isTrue);
      }
      // 厂家清单与形状表的 key 一致（多一个/少一个都是漂移）
      expect(MediaVendors.ids, <String>[
        'agnes', 'openai', 'zhipu', 'dashscope',
        'doubao', 'minimax', 'siliconflow', 'unknown',
      ]);
    });

    test('⚠️ 万相图像：尺寸用 x 写（脚本转 *）、而且**没有比例**（它没有 ratio 参数）', () {
      final o = MediaVendors.imageOptions('dashscope');
      expect(o.sizes, isNotEmpty);
      for (final s in o.sizes) {
        expect(s, matches(RegExp(r'^\d+x\d+$')),
            reason: '万相的尺寸在 Dart 侧必须用 x 写，由脚本转成 *：$s');
        expect(s.contains('*'), isFalse);
      }
      expect(o.sizes, contains('1024x1024'));
      expect(o.ratios, isEmpty, reason: '万相没有 ratio 参数，给了就是发一个上游不认的字段');
    });

    test('MiniMax 图像：sizes 空、ratios 非空（它吃 aspect_ratio，不吃 size）', () {
      final o = MediaVendors.imageOptions('minimax');
      expect(o.sizes, isEmpty);
      expect(o.ratios, isNotEmpty);
      expect(o.refs, isFalse, reason: 'MiniMax 图像没有参考图这一项');
    });

    test('⚠️ 硅基流动视频：seconds 是 null（这家没有时长参数）', () {
      final v = MediaVendors.videoOptions('siliconflow');
      expect(v, isNotNull);
      expect(v!.seconds, isNull);
      expect(MediaVendors.secondsChoices('siliconflow'), isEmpty,
          reason: '没有时长参数就不该生成时长 chip');
      expect(v.ratios, isNotEmpty, reason: '它按比例换算 image_size，比例必须有');
      expect(v.resolutions, isEmpty);
    });

    test('⚠️ 豆包视频：resolutions 空（这份请求不发分辨率）', () {
      final v = MediaVendors.videoOptions('doubao');
      expect(v, isNotNull);
      expect(v!.resolutions, isEmpty);
      expect(v.ratios, contains('21:9'), reason: 'Seedance 支持 21:9');
      expect(v.seconds!.min, 4);
      expect(v.seconds!.max, 30, reason: '2.0 是 4–15、2.5 是 4–30，取宽的');
      expect(v.firstFrame, isTrue);
    });

    test('Agnes 与别家的关键差别：档位 vs 像素、视频只认 720P', () {
      final agnes = MediaVendors.imageOptions('agnes');
      expect(agnes.sizes, <String>['1K', '2K', '3K', '4K']);
      expect(agnes.ratios, isNotEmpty);
      expect(agnes.refs, isTrue);
      final v = MediaVendors.videoOptions('agnes');
      expect(v!.resolutions, <String>['720P']);
      expect(v.seconds, isNotNull);
      expect(v.seconds!.def, 5);
      // 生图：OpenAI 兼容那几家是像素值，且没有 ratio 参数
      for (final id in <String>['openai', 'zhipu', 'doubao', 'siliconflow']) {
        final o = MediaVendors.imageOptions(id);
        expect(o.sizes, isNotEmpty, reason: '$id 应该有像素尺寸');
        expect(o.ratios, isEmpty, reason: '$id 没有 ratio 参数');
        expect(o.refs, isTrue);
      }
      // 万相视频没有首帧图（只有文生）
      expect(MediaVendors.videoOptions('dashscope')!.firstFrame, isFalse);
    });

    test('supportsVideo：OpenAI 与未知厂家为 false（本 App 里没接视频）', () {
      expect(MediaVendors.supportsVideo('openai'), isFalse);
      expect(MediaVendors.videoOptions('openai'), isNull);
      expect(MediaVendors.supportsVideo('unknown'), isFalse);
      for (final id in <String>[
        'agnes', 'doubao', 'minimax', 'dashscope', 'siliconflow',
      ]) {
        expect(MediaVendors.supportsVideo(id), isTrue, reason: '$id 应该有视频形状');
      }
    });

    test('未知厂家（用户自己填的 id）不抛异常，走 unknown 的档位', () {
      for (final weird in <String>['', 'myvendor', 'My Vendor', '  ', 'ollama:foo']) {
        final o = MediaVendors.imageOptions(weird);
        expect(o.sizes, MediaVendors.imageOptions('unknown').sizes,
            reason: '「$weird」应落到 unknown 的档位');
        expect(MediaVendors.videoOptions(weird), isNull);
        expect(MediaVendors.supportsImage(weird), isTrue);
        expect(MediaVendors.supportsVideo(weird), isFalse);
      }
      // 大小写混写也要认出来（脚本侧同样会 toLowerCase）
      expect(MediaVendors.imageOptions('Agnes').sizes,
          MediaVendors.imageOptions('agnes').sizes);
      expect(MediaVendors.imageOptions('MiniMax').ratios,
          MediaVendors.imageOptions('minimax').ratios);
    });

    test('时长 chip 是**生成**的：两端与默认值一定在，且不超量', () {
      for (final id in MediaVendors.ids) {
        final v = MediaVendors.videoOptions(id);
        final chips = MediaVendors.secondsChoices(id);
        if (v == null || v.seconds == null) {
          expect(chips, isEmpty);
          continue;
        }
        expect(chips, isNotEmpty);
        expect(chips, contains('${v.seconds!.min}'));
        expect(chips, contains('${v.seconds!.max}'));
        expect(chips, contains('${v.seconds!.def}'));
        expect(chips.length, lessThanOrEqualTo(9), reason: '$id 的时长 chip 太多了');
        // 升序、不重复（否则用户看到两个一样的 chip）
        final nums = chips.map(int.parse).toList();
        expect(nums, orderedEquals(nums.toList()..sort()));
        expect(nums.toSet().length, nums.length);
      }
    });

    test('每条 note 都登记过、且在 tr() 锚点里（否则切外语会露出中文）', () {
      final notes = <String>{};
      for (final id in MediaVendors.ids) {
        notes.add(MediaVendors.imageOptions(id).note);
        final v = MediaVendors.videoOptions(id);
        if (v != null) notes.add(v.note);
      }
      notes.removeWhere((n) => n.trim().isEmpty);
      // 13 条 note 里 openai / unknown 没有视频那条（这两家在本 App 里没接视频）
      expect(notes.length, 12);
      for (final n in notes) {
        expect(MediaVendors.noteKeys, contains(n), reason: 'note 没登记进 noteKeys：$n');
      }
      // 锚点：i18n 扫描器只认 `tr('字面量')`，写在数据表里的字符串它看不见。
      final src = _mediaModelsSource();
      if (src == null) {
        markTestSkipped('找不到 lib/data/media_models.dart（工作目录不是包根），跳过锚点核对');
        return;
      }
      final text = src.readAsStringSync();
      for (final n in MediaVendors.noteKeys) {
        expect(text.contains("tr('$n')"), isTrue,
            reason: "这条 note 缺 tr('…') 锚点，切外语时会露出中文：$n");
      }
    });

    // ⚠️ 这一条是 2026-10-11 补的**真缺口**（不是新功能）：
    //    settings 里 6 家图像预设的 `note` 是数据表里的字面量，界面原来用
    //    `Text(presetNote)` **原文显示** —— 切英/日/韩会直接露中文，而且
    //    `check-tables` 也发现不了（扫描器只认 `tr('字面量')`，看不见数据表里的串）。
    //    现在改成 `context.tr(presetNote)` + 锚点；这条测试钉住"以后再加预设也必须登记+锚点"。
    test('图像预设的 note 也都登记过、且有 tr() 锚点（否则切外语会露出中文）', () {
      final notes = MediaModels.externalPresets
          .map((p) => p.note)
          .where((n) => n.trim().isNotEmpty)
          .toList();
      expect(notes, isNotEmpty, reason: '预设说明全空的话这条测试就没意义了');
      for (final n in notes) {
        expect(MediaModels.presetNoteKeys, contains(n),
            reason: '预设 note 没登记进 presetNoteKeys：$n');
      }
      expect(MediaModels.presetNoteKeys.toSet().length,
          MediaModels.presetNoteKeys.length,
          reason: '登记表里有重复项');
      final src = _mediaModelsSource();
      if (src == null) {
        markTestSkipped('找不到 lib/data/media_models.dart（工作目录不是包根），跳过锚点核对');
        return;
      }
      final text = src.readAsStringSync();
      for (final n in MediaModels.presetNoteKeys) {
        expect(text.contains("tr('$n')"), isTrue,
            reason: "这条预设 note 缺 tr('…') 锚点，切外语时会露出中文：$n");
        // 三处一致：登记表里有、锚点里有、数据表里真的在用（防"锚点留着、文案改了"）
        expect(text.contains("'$n'"), isTrue,
            reason: '锚点/登记表里有这条，但数据表里已经不用了（陈旧条目）：$n');
      }
      expect(MediaModels.presetNoteKeys.length, notes.length,
          reason: '登记表条数应与实际用到的 note 条数一致（多了=陈旧，少了=漏登记）');
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // MiniMax 视频档位必须照官方 v2 文档（2026-10-12 逐条核对）
  //
  // 官方原文（platform.minimax.cn/docs/api-reference/video-generation-v2-create）：
  //   * `MiniMax-H3`    ：分辨率 `768P` / `2K`，时长 **4~15** 秒
  //   * `MiniMax-H3-Max`：分辨率 `480P` / `768P`，时长 **5~15** 秒（不支持 4 秒）
  //   * `duration` / `resolution` 都是**枚举**，不是任意值（v1 的 720P 在这里非法）
  //   * 文生视频（t2va）时 `ratio` **必填且不能是 `adaptive`**
  //
  // 也就是说 **480P 配 H3 会被上游直接拒**，而界面的兜底档位恰恰是
  // `resolutions.first` —— 所以第一项必须是两个模型都支持的 `768P`。
  // ══════════════════════════════════════════════════════════════════════════
  group('MiniMax 视频档位（照官方 v2 文档，2026-10-12 核对）', () {
    final v = MediaVendors.videoOptions('minimax')!;

    test('分辨率枚举就是 480P / 768P / 2K，而且**第一项必须是 768P**', () {
      expect(v.resolutions, <String>['768P', '480P', '2K'],
          reason: '第一项是 480P 的话，默认模型 H3（不支持 480P）一上来就发非法档位');
      for (final r in v.resolutions) {
        expect(<String>['480P', '768P', '2K'], contains(r),
            reason: '$r 不在官方枚举里（v1 的 720P 在 MiniMax 是非法的）');
      }
    });

    test('时长范围是 4~15 秒（以前写的 6~10 是 v1 Hailuo 的旧口径）', () {
      final r = v.seconds!;
      expect(r.min, 4, reason: '官方 H3 支持 4 秒，不该被挡掉');
      expect(r.max, 15, reason: '官方支持到 15 秒，不该被挡掉');
      expect(r.def, inInclusiveRange(r.min, r.max));
    });

    test('比例里不许出现 adaptive（文生视频时它必填且不能是 adaptive）', () {
      expect(v.ratios, isNotEmpty, reason: '文生视频不给比例会被上游拒');
      expect(v.ratios, isNot(contains('adaptive')),
          reason: '文生视频发 adaptive 会被上游拒');
    });

    test('提示文案必须写清"哪档配哪个模型"，否则用户只会反复撞 400', () {
      final note = v.note;
      expect(note, contains('768P'));
      expect(note, contains('H3-Max'));
      expect(note, contains('4–15'), reason: '旧文案的 6–10 秒还在');
    });
  });
}

/// 找源码里的 `lib/data/media_models.dart`（`flutter test` 的工作目录是包根）。
File? _mediaModelsSource() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    final f = File('${dir.path}/lib/data/media_models.dart');
    if (f.existsSync()) return f;
    final up = dir.parent;
    if (up.path == dir.path) break;
    dir = up;
  }
  return null;
}
